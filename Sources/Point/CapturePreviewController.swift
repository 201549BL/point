import AppKit

struct CapturePreviewLayout {
    let cardSize: NSSize
    let screenFrame: NSRect
    static let peekWidth: CGFloat = 44
    static let inset: CGFloat = 16

    init(imageSize: NSSize, screenFrame: NSRect) {
        let scale = min(200 / imageSize.width, 144 / imageSize.height)
        cardSize = NSSize(width: max(140, imageSize.width * scale), height: max(96, imageSize.height * scale))
        self.screenFrame = screenFrame
    }

    func panelFrame(expanded: Bool) -> NSRect {
        NSRect(x: screenFrame.minX, y: screenFrame.minY + 16,
               width: expanded ? cardSize.width + Self.inset * 2 : Self.peekWidth,
               height: cardSize.height + Self.inset * 2)
    }

    func cardOrigin(expanded: Bool) -> NSPoint {
        NSPoint(x: expanded ? Self.inset : Self.peekWidth - cardSize.width - 8, y: Self.inset)
    }
}

struct CapturePreviewLifetime {
    enum PauseReason: Hashable { case hover, save, drag }
    private(set) var savedURL: URL?
    private(set) var remaining: TimeInterval = 6
    private var runningSince: TimeInterval?
    private var pauses: Set<PauseReason> = []

    var actionTitle: String { savedURL == nil ? "Save…" : "Show in Finder" }
    var isSaving: Bool { pauses.contains(.save) }
    var isDragging: Bool { pauses.contains(.drag) }

    mutating func setPaused(_ paused: Bool, for reason: PauseReason, now: TimeInterval) {
        if let runningSince {
            remaining = max(0, remaining - (now - runningSince))
        }
        if paused { pauses.insert(reason) } else { pauses.remove(reason) }
        runningSince = pauses.isEmpty ? now : nil
    }

    mutating func didSave(to url: URL, now: TimeInterval) {
        savedURL = url
        remaining = 6
        runningSince = pauses.isEmpty ? now : nil
    }

    func timeUntilDismissal(now: TimeInterval) -> TimeInterval? {
        guard let runningSince else { return nil }
        return max(0, remaining - (now - runningSince))
    }
}

@MainActor
final class CapturePreviewDragExport {
    private let image: CGImage
    private let directory: URL
    private var exported: (url: URL, data: Data)?

    init(image: CGImage, directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Point/PreviewDrags", isDirectory: true)) {
        self.image = image
        self.directory = directory
    }

    func pasteboardItem() throws -> NSPasteboardItem {
        if exported == nil {
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw ClipboardError.pngEncodingFailed
            }
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let staleBefore = Date().addingTimeInterval(-24 * 60 * 60)
            if let children = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]) {
                for child in children where UUID(uuidString: child.lastPathComponent) != nil {
                    if let values = try? child.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
                       values.isDirectory == true, let created = values.creationDate, created < staleBefore {
                        try? manager.removeItem(at: child)
                    }
                }
            }
            let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = folder.appendingPathComponent("Point Screenshot \(formatter.string(from: Date())).png")
            try data.write(to: url, options: .atomic)
            exported = (url, data)
        }
        let item = NSPasteboardItem()
        if let exported {
            item.setString(exported.url.absoluteString, forType: .fileURL)
            item.setData(exported.data, forType: .png)
        }
        return item
    }
}

@MainActor
final class CapturePreviewController: NSObject {
    var onSave: ((CGImage) -> URL?)?
    var onError: ((Error) -> Void)?
    var onDismiss: (() -> Void)?

    private let image: CGImage
    private let panel: NSPanel
    private let preview: CapturePreviewView
    private let container: CapturePreviewContainer
    private let layout: CapturePreviewLayout
    private var expanded = false
    private var lifetime = CapturePreviewLifetime()
    private var dismissWorkItem: DispatchWorkItem?
    private var dismissed = false

    var isSaving: Bool { lifetime.isSaving }
    var isDragging: Bool { lifetime.isDragging }

    init(image: CGImage, near captureFrame: CGRect) {
        self.image = image
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: captureFrame.midX, y: captureFrame.midY)) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? captureFrame
        layout = CapturePreviewLayout(imageSize: NSSize(width: image.width, height: image.height), screenFrame: visibleFrame)
        panel = NSPanel(
            contentRect: layout.panelFrame(expanded: false),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        preview = CapturePreviewView(image: image, size: layout.cardSize)
        container = CapturePreviewContainer(frame: NSRect(origin: .zero, size: layout.panelFrame(expanded: false).size))
        super.init()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(preview)
        preview.setFrameOrigin(NSPoint(x: -layout.cardSize.width - 20, y: CapturePreviewLayout.inset))
        preview.frameCenterRotation = -6
        panel.title = "Copied screenshot"
        panel.setAccessibilityLabel("Copied to clipboard")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        container.onHover = { [weak self] hovering in self?.setHovering(hovering) }
        preview.onAction = { [weak self] in self?.performAction() }
        preview.onDismiss = { [weak self] in self?.dismiss() }
        preview.onDragState = { [weak self] dragging in
            guard let self else { return }
            self.lifetime.setPaused(dragging, for: .drag, now: ProcessInfo.processInfo.systemUptime)
            if !dragging { self.refreshHover() }
            self.scheduleDismissal()
        }
        preview.onError = { [weak self] error in self?.onError?(error) }
        panel.contentView = container
    }

    func present() {
        guard !dismissed else { return }
        panel.orderFrontRegardless()
        animatePreview(expanded: false)
        refreshHover()
    }

    func dismiss() {
        guard !dismissed, !isDragging else { return }
        dismissed = true
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel.orderOut(nil)
        onDismiss?()
    }

    func presentSaveDialog(_ savePanel: NSSavePanel) -> NSApplication.ModalResponse {
        NSApplication.shared.activate(ignoringOtherApps: true)
        return savePanel.runModal()
    }

    @objc private func performAction() {
        guard !dismissed else { return }
        if let url = lifetime.savedURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        lifetime.setPaused(true, for: .save, now: ProcessInfo.processInfo.systemUptime)
        scheduleDismissal()
        preview.setActionEnabled(false)
        defer {
            preview.setActionEnabled(true)
            lifetime.setPaused(false, for: .save, now: ProcessInfo.processInfo.systemUptime)
            refreshHover()
            scheduleDismissal()
        }
        if let url = onSave?(image) {
            lifetime.didSave(to: url, now: ProcessInfo.processInfo.systemUptime)
            preview.setActionTitle(lifetime.actionTitle)
        }
    }

    private func refreshHover() {
        setHovering(panel.frame.contains(NSEvent.mouseLocation))
    }

    private func setHovering(_ hovering: Bool) {
        guard !dismissed else { return }
        let shouldExpand = hovering || isSaving || isDragging
        if shouldExpand != expanded {
            expanded = shouldExpand
            animatePreview(expanded: shouldExpand)
        }
        preview.setHovering(shouldExpand)
        lifetime.setPaused(hovering, for: .hover, now: ProcessInfo.processInfo.systemUptime)
        scheduleDismissal()
    }

    private func animatePreview(expanded: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(layout.panelFrame(expanded: expanded), display: true)
            preview.animator().setFrameOrigin(layout.cardOrigin(expanded: expanded))
            preview.animator().frameCenterRotation = expanded ? 0 : -6
        }
    }

    private func scheduleDismissal() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard !dismissed, let delay = lifetime.timeUntilDismissal(now: ProcessInfo.processInfo.systemUptime) else { return }
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

@MainActor
private final class CapturePreviewView: NSView, NSDraggingSource {
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    var onDragState: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private let dragExport: CapturePreviewDragExport
    private let dragImage: NSImage
    private var mouseDownPoint: NSPoint?
    private let overlay = NSView()
    private let actionButton = NSButton(title: "Save…", target: nil, action: nil)
    private let closeButton = NSButton()

    init(image: CGImage, size: NSSize) {
        dragExport = CapturePreviewDragExport(image: image)
        dragImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor

        let thumbnail = NSImageView(frame: bounds)
        thumbnail.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.setAccessibilityElement(false)
        addSubview(thumbnail)

        overlay.frame = bounds
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.30).cgColor
        overlay.isHidden = true
        addSubview(overlay)

        actionButton.target = self
        actionButton.action = #selector(activateAction)
        actionButton.isBordered = false
        actionButton.font = .systemFont(ofSize: 12, weight: .medium)
        actionButton.contentTintColor = NSColor(white: 0.12, alpha: 1)
        actionButton.wantsLayer = true
        actionButton.layer?.backgroundColor = NSColor.white.cgColor
        actionButton.layer?.cornerRadius = 14
        overlay.addSubview(actionButton)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss preview")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(activateDismiss)
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        closeButton.layer?.cornerRadius = 11
        closeButton.frame = NSRect(x: size.width - 30, y: size.height - 30, width: 22, height: 22)
        overlay.addSubview(closeButton)
        setActionTitle("Save…")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Copied screenshot")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHovering(_ hovering: Bool) {
        overlay.isHidden = !hovering
    }

    func setActionEnabled(_ enabled: Bool) {
        actionButton.isEnabled = enabled
    }

    func setActionTitle(_ title: String) {
        actionButton.title = title
        actionButton.sizeToFit()
        let width = max(76, actionButton.frame.width + 24)
        actionButton.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - 28) / 2, width: width, height: 28)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: title) { [weak self] in
                guard let self, self.actionButton.isEnabled else { return false }
                self.onAction?()
                return true
            },
            NSAccessibilityCustomAction(name: "Dismiss preview") { [weak self] in
                self?.onDismiss?()
                return true
            }
        ])
    }

    @objc private func activateAction() { onAction?() }
    @objc private func activateDismiss() { onDismiss?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === actionButton || hit.isDescendant(of: actionButton) { return hit }
        if hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
        mouseDownPoint = nil
        do {
            let item = NSDraggingItem(pasteboardWriter: try dragExport.pasteboardItem())
            let scale = min(bounds.width / dragImage.size.width, bounds.height / dragImage.size.height)
            let size = NSSize(width: dragImage.size.width * scale, height: dragImage.size.height * scale)
            item.setDraggingFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                         width: size.width, height: size.height), contents: dragImage)
            onDragState?(true)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        } catch {
            onError?(error)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragState?(false)
    }
}

@MainActor
private final class CapturePreviewContainer: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
