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
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true

            let selectionView = SelectionView(snapshot: snapshot)
            selectionView.onSelection = { [weak self] rect in
                self?.onSelection?(snapshot, rect)
            }
            selectionView.onCancel = { [weak self] in
                self?.onCancel?()
            }
            selectionView.onDragStart = { [weak self] in
                self?.panels.forEach { ($0.contentView as? SelectionView)?.beginSelection() }
            }
            selectionView.onDragReset = { [weak self] in
                self?.panels.forEach { ($0.contentView as? SelectionView)?.resetSelection() }
            }
            panel.contentView = selectionView
            return panel
        }

        for panel in panels { panel.orderFrontRegardless() }
        panels.first?.makeKey()
        for panel in panels { (panel.contentView as? SelectionView)?.beginEntrance() }
    }

    func dismiss() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }

    func focus() {
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
    var onDragStart: (() -> Void)?
    var onDragReset: (() -> Void)?

    private let snapshot: DisplaySnapshot
    private let frozenImage: NSImage
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var selection: CGRect?

    private let washImage: CGImage?
    private let darkMode: Bool
    private let animatesEntrance: Bool
    private var entranceAnimation: SelectionEntranceAnimation?
    private var entranceProgress: CGFloat
    private var isSelecting = false
    private let accentColor = NSColor.white

    init(snapshot: DisplaySnapshot, animatesEntrance: Bool = true) {
        self.snapshot = snapshot
        frozenImage = NSImage(cgImage: snapshot.image, size: snapshot.screenFrame.size)
        self.animatesEntrance = animatesEntrance
        entranceProgress = animatesEntrance && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
        darkMode = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        washImage = SunsetWash.image(size: snapshot.screenFrame.size, scale: snapshot.pointPixelScale, darkMode: darkMode)
        super.init(frame: CGRect(origin: .zero, size: snapshot.screenFrame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if window == nil {
            entranceAnimation?.stop()
            entranceAnimation = nil
        }
    }

    func beginEntrance() {
        entranceAnimation?.stop()
        entranceAnimation = nil
        isSelecting = false
        entranceProgress = 1
        guard window != nil, animatesEntrance,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        entranceProgress = 0
        let animation = SelectionEntranceAnimation(duration: 0.18, animationCurve: .linear)
        animation.animationBlockingMode = .nonblocking
        animation.frameRate = 60
        animation.onProgress = { [weak self] progress in
            self?.entranceProgress = progress
            self?.needsDisplay = true
        }
        entranceAnimation = animation
        animation.start()
    }

    func beginSelection() {
        entranceAnimation?.stop()
        entranceAnimation = nil
        entranceProgress = 1
        isSelecting = true
        needsDisplay = true
    }

    func resetSelection() {
        isSelecting = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private func drawCaptureHint() {
        let text = "Drag to capture   ·   Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - (size.width + 28) / 2, y: 19, width: size.width + 28, height: 34)
        NSColor(srgbRed: 0.10, green: 0.14, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        text.draw(at: CGPoint(x: pill.minX + 14, y: pill.midY - size.height / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        selection = nil
        if let onDragStart { onDragStart() } else { beginSelection() }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        dragCurrent = current
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
            if let onDragReset { onDragReset() } else { resetSelection() }
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
        frozenImage.draw(in: bounds)

        NSGraphicsContext.saveGraphicsState()
        if let selection, let context = NSGraphicsContext.current?.cgContext {
            context.addRect(bounds)
            context.addRect(selection)
            context.clip(using: .evenOdd)
        }
        if entranceProgress >= 1, let washImage {
            NSImage(cgImage: washImage, size: bounds.size).draw(in: bounds)
        } else if let context = NSGraphicsContext.current?.cgContext {
            let p = entranceProgress * entranceProgress * (3 - 2 * entranceProgress)
            SunsetWash.draw(in: context, size: bounds.size, opacity: p, darkMode: darkMode)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let selection else {
            if !isSelecting { drawCaptureHint() }
            return
        }

        let outline = NSBezierPath(rect: selection.insetBy(dx: 1, dy: 1))
        NSColor(srgbRed: 0.04, green: 0.08, blue: 0.14, alpha: 1).setStroke()
        outline.lineWidth = 3
        outline.stroke()
        NSColor.white.setStroke()
        outline.lineWidth = 1.5
        outline.stroke()

        let sizeText = "\(Int((selection.width * snapshot.pointPixelScale).rounded())) × \(Int((selection.height * snapshot.pointPixelScale).rounded())) px"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = sizeText.size(withAttributes: attributes)
        let pillSize = CGSize(width: textSize.width + 16, height: textSize.height + 10)
        let pillRect = SelectionLabelLayout.frame(
            selection: selection,
            cursor: dragCurrent ?? CGPoint(x: selection.maxX, y: selection.minY),
            size: pillSize,
            bounds: bounds
        )

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

enum SelectionLabelLayout {
    static func frame(selection: CGRect, cursor: CGPoint, size: CGSize, bounds: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
            CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY),
        ]
        func distance(_ point: CGPoint) -> CGFloat {
            let dx = point.x - cursor.x, dy = point.y - cursor.y
            return dx * dx + dy * dy
        }
        let corner = corners.min { distance($0) < distance($1) }!
        let gap: CGFloat = 12
        let safe = bounds.insetBy(dx: 8, dy: 8)
        var x = corner.x >= selection.midX ? corner.x + gap : corner.x - size.width - gap
        var y = corner.y >= selection.midY ? corner.y + gap : corner.y - size.height - gap
        if x + size.width > safe.maxX { x = corner.x - size.width - gap }
        if x < safe.minX { x = corner.x + gap }
        if y + size.height > safe.maxY { y = corner.y - size.height - gap }
        if y < safe.minY { y = corner.y + gap }
        x = max(safe.minX, min(x, safe.maxX - size.width))
        y = max(safe.minY, min(y, safe.maxY - size.height))
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

private final class SelectionEntranceAnimation: NSAnimation {
    var onProgress: ((CGFloat) -> Void)?

    override var currentProgress: NSAnimation.Progress {
        didSet { onProgress?(CGFloat(currentValue)) }
    }
}
