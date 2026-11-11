import AppKit

/// Shows the real editor and animates backdrop toggles using the capture's motion.
@MainActor
final class SettingsPreviewView: NSView {
    enum Kind: String {
        case appearance, annotations
    }

    private enum Content {
        case capture, selectionOverlay
    }

    let kind: Kind
    var isAnimating: Bool { animationTimer != nil }
    var isTransitioning: Bool { overlayTransition != nil }

    private let sceneSize = CGSize(width: 500, height: 300)
    private let captureRect = CGRect(x: 100, y: 90, width: 300, height: 120)
    private let scene = NSView()
    private var animationTimer: Timer?
    private var previewVisible = false
    private var captureFrame: AnnotationFrameView?
    private var canvas: AnnotationCanvasView?
    private var selectionOverlay: SelectionView?
    private var backdropTransition: CaptureBackdropTransition?
    private var overlayTransition: OverlayTransition?
    private var overlayOpacity: CGFloat = 0
    private var backgroundKey: BackgroundKey?
    private var backgroundImage: CGImage?
    private var sceneImage: CGImage?
    private var currentAppearance: CaptureAppearance?
    private var content = Content.capture
    private var selectionOverlayPalette: SunsetWashPalette?

    private struct OverlayTransition {
        let startTime: TimeInterval
        let startOpacity: CGFloat
        let endOpacity: CGFloat

        func sample(at time: TimeInterval) -> (opacity: CGFloat, isComplete: Bool) {
            let progress = CGFloat(min(1, max(0, (time - startTime) / 0.18)))
            let eased = progress * progress * (3 - 2 * progress)
            return (startOpacity + (endOpacity - startOpacity) * eased, progress >= 1)
        }
    }

    private struct BackgroundKey: Equatable {
        let choice: CaptureBackground
        let url: URL?
        let modified: Date?
        let appearance: NSAppearance.Name
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("settings.preview.\(kind.rawValue)")
        addSubview(scene)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([])
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            previewVisible = false
            resetToCapture()
        } else {
            stopAnimation()
        }
    }

    func setPreviewVisible(_ visible: Bool) {
        if !visible {
            previewVisible = false
            resetToCapture()
            return
        }
        guard visible != previewVisible else { return }
        previewVisible = visible
        refresh()
    }

    func refresh() {
        let previousKey = backgroundKey
        let appearance = CaptureAppearance.preferred
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateBackground()
            if let captureFrame, let canvas, previousKey == backgroundKey {
                canvas.updateStyle(AnnotationStyle.preferred)
                captureFrame.accentColor = appearance.borderColor
                if currentAppearance?.backdropMargin != appearance.backdropMargin {
                    // The editor applies margin adjustments directly, including during a transition.
                    backdropTransition = nil
                    showEditor()
                } else if currentAppearance?.usesDesktopBackdrop != appearance.usesDesktopBackdrop {
                    if canAnimate {
                        if let transition = backdropTransition {
                            apply(transition: transition, sample: transition.sample(at: ProcessInfo.processInfo.systemUptime))
                        }
                        startBackdropTransition(to: appearance)
                    } else {
                        backdropTransition = nil
                        showEditor()
                    }
                }
            } else {
                backdropTransition = nil
                showEditor()
            }
            if content == .selectionOverlay || overlayTransition != nil { showOverlay() }
        }
        currentAppearance = appearance
        applyOverlayOpacity()
        updateAccessibility()
        updateTimerState()
    }

    func stopAnimation() {
        finishAnimation()
        overlayOpacity = content == .selectionOverlay ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateBackground()
            showEditor()
            if content == .selectionOverlay { showOverlay() } else { removeOverlay() }
        }
        applyOverlayOpacity()
    }

    func setSelectionOverlayVisible(_ visible: Bool, animated: Bool = true) {
        guard kind == .appearance else { return }
        if !visible { setSelectionOverlayPalette(nil) }
        guard !visible || (previewVisible && window?.isVisible == true && !isHiddenOrHasHiddenAncestor) else {
            resetToCapture()
            return
        }
        let target: Content = visible ? .selectionOverlay : .capture
        if content == target, animated, canAnimate { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let transition = overlayTransition {
            overlayOpacity = transition.sample(at: now).opacity
        }
        content = target
        if visible {
            effectiveAppearance.performAsCurrentDrawingAppearance { showOverlay() }
        }
        let endOpacity: CGFloat = visible ? 1 : 0
        if animated, canAnimate, overlayOpacity != endOpacity {
            overlayTransition = OverlayTransition(startTime: now, startOpacity: overlayOpacity, endOpacity: endOpacity)
        } else {
            overlayTransition = nil
            overlayOpacity = endOpacity
            if !visible { removeOverlay() }
        }
        applyOverlayOpacity()
        updateAccessibility()
        updateTimerState()
    }

    func setSelectionOverlayPalette(_ palette: SunsetWashPalette?) {
        guard kind == .appearance, selectionOverlayPalette != palette else { return }
        selectionOverlayPalette = palette
        if content == .selectionOverlay || overlayTransition != nil {
            effectiveAppearance.performAsCurrentDrawingAppearance { showOverlay() }
            applyOverlayOpacity()
        }
        updateAccessibility()
    }

    private func resetToCapture() {
        content = .capture
        selectionOverlayPalette = nil
        stopAnimation()
    }

    private var canAnimate: Bool {
        previewVisible && window?.isVisible == true && !isHiddenOrHasHiddenAncestor &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @objc private func accessibilityOptionsChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { stopAnimation() }
    }

    private func startTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.advanceAnimation()
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finishAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        backdropTransition = nil
        overlayTransition = nil
    }

    private func updateTimerState() {
        if backdropTransition != nil || overlayTransition != nil {
            startTimer()
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func advanceAnimation() {
        guard previewVisible, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else {
            resetToCapture()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let transition = backdropTransition {
            let sample = transition.sample(at: now)
            apply(transition: transition, sample: sample)
            if sample.isComplete {
                backdropTransition = nil
                if !transition.isEnabling {
                    captureFrame?.update(wallpaperImage: nil, canvasOrigin: captureFrame?.canvasRect.origin ?? .zero)
                }
            }
        }
        if let transition = overlayTransition {
            let sample = transition.sample(at: now)
            overlayOpacity = sample.opacity
            if sample.isComplete {
                overlayTransition = nil
                if content == .capture { removeOverlay() }
            }
            applyOverlayOpacity()
        }
        updateTimerState()
    }

    private func showEditor() {
        guard let source = croppedImage(selection: captureRect) else { clearScene(); return }
        captureFrame?.removeFromSuperview()
        captureFrame = nil
        canvas = nil
        let appearance = CaptureAppearance.preferred
        currentAppearance = appearance
        let wallpaper = appearance.usesDesktopBackdrop ? backgroundImage : nil
        let padding = wallpaper == nil ? AnnotationFrameView.borderWidth : appearance.backdropMargin
        let frame = AnnotationFrameView(canvasSize: captureRect.size, wallpaperImage: wallpaper,
                                        padding: padding, accentColor: appearance.borderColor)
        frame.frame.origin = CGPoint(x: captureRect.minX - padding, y: captureRect.minY - padding)
        frame.wallpaperReferencePadding = appearance.backdropMargin
        frame.wallpaperOpacity = wallpaper == nil ? 0 : 1
        frame.wallpaperRevealPadding = wallpaper == nil ? 0 : padding
        let session = AnnotationSession()
        let arrow = ArrowAnnotation(id: UUID(), tail: CGPoint(x: 62, y: 27),
                                    head: CGPoint(x: 228, y: 83), caption: "Text", bend: -0.18)
        if kind == .annotations { session.append(.arrow(arrow)) }
        session.select(nil)
        let canvas = AnnotationCanvasView(sourceImage: source, session: session, style: .preferred)
        canvas.frame = frame.canvasRect
        frame.addSubview(canvas)
        scene.addSubview(frame, positioned: .below, relativeTo: selectionOverlay)
        self.canvas = canvas
        captureFrame = frame
        updateAccessibility()
        needsLayout = true
        needsDisplay = true
    }

    private func showOverlay() {
        removeOverlay()
        guard let sceneImage else { return }
        let snapshot = DisplaySnapshot(displayID: 0, screenFrame: CGRect(origin: .zero, size: sceneSize),
                                       image: sceneImage, wallpaperImage: backgroundImage)
        let selection = SelectionView(snapshot: snapshot, previewSelection: captureRect,
                                      previewPalette: selectionOverlayPalette)
        scene.addSubview(selection)
        selectionOverlay = selection
        updateAccessibility()
        needsLayout = true
        needsDisplay = true
    }

    private func removeOverlay() {
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
    }

    private func applyOverlayOpacity() {
        captureFrame?.alphaValue = 1
        captureFrame?.isHidden = overlayOpacity >= 1
        selectionOverlay?.alphaValue = overlayOpacity
    }

    private func startBackdropTransition(to appearance: CaptureAppearance) {
        guard let captureFrame else { return }
        let enabled = appearance.usesDesktopBackdrop && backgroundImage != nil
        let padding = enabled ? appearance.backdropMargin : AnnotationFrameView.borderWidth
        captureFrame.wallpaperReferencePadding = appearance.backdropMargin
        captureFrame.update(wallpaperImage: backgroundImage, canvasOrigin: captureFrame.canvasRect.origin)
        backdropTransition = CaptureBackdropTransition(
            startTime: ProcessInfo.processInfo.systemUptime,
            startPanelFrame: captureFrame.frame,
            endPanelFrame: captureRect.insetBy(dx: -padding, dy: -padding),
            startOpacity: captureFrame.wallpaperOpacity,
            endOpacity: enabled ? 1 : 0,
            startRevealPadding: captureFrame.wallpaperRevealPadding,
            endRevealPadding: enabled ? appearance.backdropMargin : 0,
            isEnabling: enabled,
            canvasScreenOrigin: captureRect.origin
        )
        currentAppearance = appearance
    }

    private func apply(transition: CaptureBackdropTransition, sample: CaptureBackdropTransition.Sample) {
        guard let captureFrame, let canvas else { return }
        captureFrame.frame = sample.panelFrame
        captureFrame.bounds = CGRect(origin: .zero, size: sample.panelFrame.size)
        captureFrame.update(wallpaperImage: backgroundImage, canvasOrigin: transition.canvasOrigin(in: sample.panelFrame))
        captureFrame.wallpaperOpacity = sample.opacity
        captureFrame.wallpaperRevealPadding = sample.revealPadding
        canvas.frame = captureFrame.canvasRect
    }

    private func clearScene() {
        scene.subviews.forEach { $0.removeFromSuperview() }
        captureFrame = nil
        canvas = nil
        selectionOverlay = nil
    }

    private func updateAccessibility() {
        let appearance = CaptureAppearance.preferred
        let style = AnnotationStyle.preferred
        if kind == .annotations {
            setAccessibilityLabel("Annotation preview. \(Int(style.lineWidth.rounded())) point arrow, \(Int(style.fontSize.rounded())) point text.")
        } else if content == .selectionOverlay {
            let strength = Int((SunsetWashStrength.preferred() * 100).rounded())
            let palette = selectionOverlayPalette ?? SunsetWashPalette.preferred()
            setAccessibilityLabel("Selection overlay preview. \(palette.title), \(strength)% strength.")
        } else {
            setAccessibilityLabel(appearance.usesDesktopBackdrop && backgroundImage != nil
                ? "Capture preview. Background on, \(Int(appearance.backdropMargin.rounded())) point margin."
                : "Capture preview. Background off.")
        }
    }

    private func updateBackground() {
        let choice = CaptureBackground.preferred()
        let desktopURL = (window?.screen ?? NSScreen.main).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        let url: URL?
        switch choice {
        case .desktop: url = desktopURL
        case .custom: url = CaptureBackground.customImageURL
        case .system: url = CaptureBackground.systemImageURL
        default: url = nil
        }
        let modified = url.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let key = BackgroundKey(choice: choice, url: url, modified: modified, appearance: effectiveAppearance.name)
        guard key != backgroundKey else { return }
        backgroundKey = key
        switch choice {
        case .desktop, .custom, .system:
            backgroundImage = url.flatMap { CaptureBackground.loadImage(at: $0, maxPixelSize: 1600) }
        default:
            backgroundImage = choice.image(desktop: nil)
        }
        sceneImage = (backgroundImage ?? CaptureBackground.aurora.image(desktop: nil)).flatMap(makeScene)
    }

    private func makeScene(from image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(sceneSize.width * 2), height: Int(sceneSize.height * 2),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = max(CGFloat(context.width) / CGFloat(image.width), CGFloat(context.height) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(context.width) - size.width) / 2,
                                      y: (CGFloat(context.height) - size.height) / 2,
                                      width: size.width, height: size.height))
        return context.makeImage()
    }

    private func croppedImage(selection: CGRect) -> CGImage? {
        guard let sceneImage else { return nil }
        let snapshot = DisplaySnapshot(displayID: 0, screenFrame: CGRect(origin: .zero, size: sceneSize),
                                       image: sceneImage, wallpaperImage: backgroundImage)
        return try? ScreenCaptureService().crop(snapshot: snapshot, selectionInPoints: selection)
    }

    override func layout() {
        super.layout()
        let available = bounds.insetBy(dx: 6, dy: 6)
        guard available.width > 0, available.height > 0 else { return }
        let scale = min(1, min(available.width / sceneSize.width, available.height / sceneSize.height))
        let size = CGSize(width: sceneSize.width * scale, height: sceneSize.height * scale)
        scene.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                             width: size.width, height: size.height)
        scene.bounds = CGRect(origin: .zero, size: sceneSize)
    }
}
