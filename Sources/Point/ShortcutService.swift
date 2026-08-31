import Carbon

enum ShortcutRegistrationError: Error {
    case registrationFailed(OSStatus)
}

enum ShortcutChoice: Int, CaseIterable {
    case controlShift2
    case controlShift3
    case optionShift2
    case commandShift2

    var title: String {
        switch self {
        case .controlShift2: "⌃⇧2"
        case .controlShift3: "⌃⇧3"
        case .optionShift2: "⌥⇧2"
        case .commandShift2: "⌘⇧2"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .controlShift3: UInt32(kVK_ANSI_3)
        default: UInt32(kVK_ANSI_2)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .controlShift2, .controlShift3: UInt32(controlKey | shiftKey)
        case .optionShift2: UInt32(optionKey | shiftKey)
        case .commandShift2: UInt32(cmdKey | shiftKey)
        }
    }

    static var preferred: ShortcutChoice {
        ShortcutChoice(rawValue: UserDefaults.standard.integer(forKey: "shortcutChoice")) ?? .controlShift2
    }
}

@MainActor
final class ShortcutService {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private(set) var registeredChoice: ShortcutChoice?

    func register(choice: ShortcutChoice = .preferred, action: @escaping () -> Void) throws {
        self.action = action
        ShortcutService.current = self

        if handler == nil { try installHandler() }
        try registerHotKey(choice)
    }

    func change(to choice: ShortcutChoice) throws {
        let previous = registeredChoice
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        do {
            try registerHotKey(choice)
        } catch {
            if let previous { try? registerHotKey(previous) }
            throw error
        }
    }

    private func installHandler() throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == ShortcutService.signature else { return noErr }
            DispatchQueue.main.async { ShortcutService.current?.action?() }
            return noErr
        }, 1, &eventType, nil, &handler)
        guard status == noErr else { throw ShortcutRegistrationError.registrationFailed(status) }
    }

    private func registerHotKey(_ choice: ShortcutChoice) throws {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            choice.keyCode,
            choice.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registerStatus == noErr else { throw ShortcutRegistrationError.registrationFailed(registerStatus) }
        registeredChoice = choice
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static weak var current: ShortcutService?
    private static let signature: OSType = 0x506F696E // "Poin"
}
