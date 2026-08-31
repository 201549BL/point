import AppKit

@MainActor
final class DisplayOverlayController {
    var onSelection: ((DisplaySnapshot, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let snapshots: [DisplaySnapshot]
    private var panels: [SelectionPanel] = []

    init(snapshots: [DisplaySnapshot]) {
        self.snapshots = snapshots
    }

    func present() {
        panels = snapshots.map { snapshot in
            let panel = SelectionPanel(
                contentRect: snapshot.screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true

            let selectionView = SelectionView(snapshot: snapshot)
            selectionView.onSelection = { [weak self] rect in
                self?.onSelection?(snapshot, rect)
            }
            selectionView.onCancel = { [weak self] in
                self?.onCancel?()
            }
            panel.contentView = selectionView
            return panel
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        for panel in panels { panel.orderFrontRegardless() }
        panels.first?.makeKey()
    }

    func dismiss() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    func focus() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for panel in panels { panel.orderFrontRegardless() }
        panels.first?.makeKey()
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let snapshot: DisplaySnapshot
    private var dragStart: CGPoint?
    private var selection: CGRect?

    private let overlayColor = NSColor(
        srgbRed: 0.018,
        green: 0.043,
        blue: 0.105,
        alpha: 0.56
    )
    private let accentColor = NSColor(
        srgbRed: 0.18,
        green: 0.67,
        blue: 1,
        alpha: 1
    )

    init(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(dragStart.x, current.x),
            y: min(dragStart.y, current.y),
            width: abs(current.x - dragStart.x),
            height: abs(current.y - dragStart.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onSelection?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: snapshot.image, size: bounds.size).draw(in: bounds)

        overlayColor.setFill()
        guard let selection else {
            bounds.fill()
            return
        }

        // Preserve the midnight treatment outside the drag while showing the
        // selected pixels exactly as they will appear in the screenshot.
        let dimmedArea = NSBezierPath(rect: bounds)
        dimmedArea.appendRect(selection)
        dimmedArea.windingRule = .evenOdd
        dimmedArea.fill()

        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = accentColor.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        glow.set()

        accentColor.setStroke()
        let outline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        outline.lineWidth = 2
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let sizeText = "\(Int((selection.width * snapshot.pointPixelScale).rounded())) × \(Int((selection.height * snapshot.pointPixelScale).rounded())) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = sizeText.size(withAttributes: attributes)
        let pillSize = CGSize(width: textSize.width + 16, height: textSize.height + 10)
        let pillX = min(
            max(selection.midX - pillSize.width / 2, 8),
            bounds.width - pillSize.width - 8
        )
        let belowSelectionY = selection.minY - pillSize.height - 10
        let pillY = belowSelectionY >= 8
            ? belowSelectionY
            : min(selection.maxY + 10, bounds.height - pillSize.height - 8)
        let pillRect = CGRect(origin: CGPoint(x: pillX, y: pillY), size: pillSize)

        NSGraphicsContext.saveGraphicsState()
        let pillShadow = NSShadow()
        pillShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        pillShadow.shadowBlurRadius = 8
        pillShadow.shadowOffset = CGSize(width: 0, height: -2)
        pillShadow.set()

        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 7, yRadius: 7)
        NSColor(srgbRed: 0.025, green: 0.12, blue: 0.24, alpha: 0.94).setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()

        accentColor.withAlphaComponent(0.72).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        sizeText.draw(
            at: CGPoint(x: pillRect.minX + 8, y: pillRect.minY + 5),
            withAttributes: attributes
        )
    }
}
