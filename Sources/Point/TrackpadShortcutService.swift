import AppKit
import Darwin

struct ThreeFingerDoubleTapDetector {
    private(set) var firstTapTimestamp: TimeInterval?
    private let maximumInterval: TimeInterval

    init(maximumInterval: TimeInterval = 0.58) {
        self.maximumInterval = maximumInterval
    }

    mutating func registerTap(
        fingerCount: Int,
        duration: TimeInterval,
        hadMotion: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        guard fingerCount == 3, duration <= 0.34, !hadMotion else {
            firstTapTimestamp = nil
            return false
        }

        if let firstTapTimestamp {
            let interval = timestamp - firstTapTimestamp
            if interval >= 0.06, interval <= maximumInterval {
                self.firstTapTimestamp = nil
                return true
            }
            // A valid tap outside the double-tap window becomes the beginning
            // of a fresh pair instead of leaving the recognizer out of phase.
            self.firstTapTimestamp = timestamp
            return false
        }

        firstTapTimestamp = timestamp
        return false
    }

    mutating func reset() {
        firstTapTimestamp = nil
    }
}

struct ThreeFingerContactMotion {
    private static let movementThreshold: CGFloat = 0.035

    private(set) var hadMotion = false
    private var anchor: CGPoint?

    mutating func observe(fingerCount: Int, position: CGPoint?) {
        guard fingerCount == 3, !hadMotion else { return }
        guard let position else {
            // If a future macOS version changes the private contact layout,
            // fail closed instead of turning swipes into screenshot triggers.
            hadMotion = true
            return
        }
        guard let anchor else {
            self.anchor = position
            return
        }
        hadMotion = hypot(position.x - anchor.x, position.y - anchor.y) >= Self.movementThreshold
    }

    mutating func reset() {
        hadMotion = false
        anchor = nil
    }
}

private typealias MTDeviceRef = OpaquePointer
private typealias MTContactFrameCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32
private typealias MTDeviceCreateListFunction = @convention(c) () -> Unmanaged<CFArray>?
private typealias MTRegisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef, MTContactFrameCallback) -> Void
private typealias MTUnregisterContactFrameCallbackFunction = @convention(c) (MTDeviceRef, MTContactFrameCallback) -> Void
private typealias MTDeviceStartFunction = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStopFunction = @convention(c) (MTDeviceRef) -> Void

nonisolated(unsafe) private weak var activeTrackpadShortcutService: TrackpadShortcutService?

private let pointContactFrameCallback: MTContactFrameCallback = { _, contacts, contactCount, _, _ in
    let count = max(0, Int(contactCount))
    var position: CGPoint?
    if count > 0, let contacts {
        let x = contacts.load(fromByteOffset: 32, as: Float.self)
        let y = contacts.load(fromByteOffset: 36, as: Float.self)
        if x.isFinite, y.isFinite, (-0.5...1.5).contains(x), (-0.5...1.5).contains(y) {
            position = CGPoint(x: CGFloat(x), y: CGFloat(y))
        }
    }
    DispatchQueue.main.async {
        activeTrackpadShortcutService?.receiveContactFrame(count: count, position: position)
    }
    return 0
}

private final class MultitouchContactSource {
    private let libraryHandle: UnsafeMutableRawPointer
    private let deviceList: CFArray
    private let devices: [MTDeviceRef]
    private let unregisterCallback: MTUnregisterContactFrameCallbackFunction
    private let stopDevice: MTDeviceStopFunction
    private var isStopped = false

    init?() {
        let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let libraryHandle = dlopen(frameworkPath, RTLD_NOW | RTLD_LOCAL),
              let createList: MTDeviceCreateListFunction = Self.load("MTDeviceCreateList", from: libraryHandle),
              let registerCallback: MTRegisterContactFrameCallbackFunction = Self.load("MTRegisterContactFrameCallback", from: libraryHandle),
              let unregisterCallback: MTUnregisterContactFrameCallbackFunction = Self.load("MTUnregisterContactFrameCallback", from: libraryHandle),
              let startDevice: MTDeviceStartFunction = Self.load("MTDeviceStart", from: libraryHandle),
              let stopDevice: MTDeviceStopFunction = Self.load("MTDeviceStop", from: libraryHandle),
              let deviceList = createList()?.takeRetainedValue() else {
            return nil
        }

        var devices: [MTDeviceRef] = []
        for index in 0..<CFArrayGetCount(deviceList) {
            guard let value = CFArrayGetValueAtIndex(deviceList, index) else { continue }
            devices.append(MTDeviceRef(value))
        }
        guard !devices.isEmpty else {
            dlclose(libraryHandle)
            return nil
        }

        self.libraryHandle = libraryHandle
        self.deviceList = deviceList
        self.devices = devices
        self.unregisterCallback = unregisterCallback
        self.stopDevice = stopDevice

        for device in devices {
            registerCallback(device, pointContactFrameCallback)
            startDevice(device, 0)
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for device in devices {
            unregisterCallback(device, pointContactFrameCallback)
            stopDevice(device)
        }
    }

    deinit {
        stop()
        _ = deviceList
        dlclose(libraryHandle)
    }

    private static func load<T>(_ name: String, from handle: UnsafeMutableRawPointer) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

@MainActor
final class TrackpadShortcutService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var contactSource: MultitouchContactSource?
    private var action: (() -> Void)?
    private var detector = ThreeFingerDoubleTapDetector(
        maximumInterval: min(1.2, max(0.5, NSEvent.doubleClickInterval + 0.08))
    )
    private var contactStartTimestamp: TimeInterval?
    private var maximumFingerCount = 0
    private var currentFingerCount = 0
    private var contactMotion = ThreeFingerContactMotion()

    func setEnabled(_ enabled: Bool, action: @escaping () -> Void) {
        stop()
        guard enabled else { return }
        self.action = action
        activeTrackpadShortcutService = self
        contactSource = MultitouchContactSource()

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            DispatchQueue.main.async { self?.processMouseDown(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.processMouseDown(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        contactSource?.stop()
        contactSource = nil
        if activeTrackpadShortcutService === self { activeTrackpadShortcutService = nil }
        action = nil
        resetContact()
        detector.reset()
    }

    fileprivate func receiveContactFrame(count fingerCount: Int, position: CGPoint?) {
        contactMotion.observe(fingerCount: fingerCount, position: position)
        guard fingerCount != currentFingerCount else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        if currentFingerCount == 0, fingerCount > 0 {
            contactStartTimestamp = timestamp
            maximumFingerCount = fingerCount
        } else if currentFingerCount > 0, fingerCount == 0 {
            finishContact(at: timestamp)
            return
        }
        currentFingerCount = fingerCount
        maximumFingerCount = max(maximumFingerCount, fingerCount)
    }

    private func processMouseDown(_ event: NSEvent) {
        if currentFingerCount == 3,
           !contactMotion.hadMotion,
           event.clickCount >= 2 {
            detector.reset()
            action?()
        }
    }

    private func finishContact(at timestamp: TimeInterval) {
        guard let contactStartTimestamp else {
            resetContact()
            return
        }
        let recognized = detector.registerTap(
            fingerCount: maximumFingerCount,
            duration: timestamp - contactStartTimestamp,
            hadMotion: contactMotion.hadMotion,
            timestamp: timestamp
        )
        resetContact()
        if recognized {
            action?()
        }
    }

    private func resetContact() {
        contactStartTimestamp = nil
        maximumFingerCount = 0
        currentFingerCount = 0
        contactMotion.reset()
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        contactSource?.stop()
    }
}

enum TrackpadShortcutPreference {
    static let defaultsKey = "threeFingerDoubleTapCapture"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}
