import AppKit
import UniformTypeIdentifiers

@MainActor
final class AnnotationCanvasController: NSObject {
    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onSettings: (() -> Void)?

    private let sourceImage: CGImage
    private let desktopWallpaperImage: CGImage?
    private var background = CaptureBackground.preferred()
    private var wallpaperImage: CGImage?
    private let canvasFrame: CGRect
    private let session = AnnotationSession()
    private var style = AnnotationStyle.preferred
    private var appearance = CaptureAppearance.preferred
    private var backgroundLoadTask: Task<Void, Never>?
    private var panel: AnnotationPanel?
    private var canvasView: AnnotationCanvasView?
    private var frameView: AnnotationFrameView?
    private var controlsPanel: NSPanel?
    private var controlsView: AnnotationControlsView?
    private var backdropAnimationTimer: Timer?
    private var backdropTransition: BackdropTransition?
    private var controlsDetachedForTransition = false

    private struct BackdropTransition {
        let startTime: TimeInterval
        let duration: TimeInterval
        let startPanelFrame: CGRect
        let endPanelFrame: CGRect
        let startOpacity: CGFloat
        let endOpacity: CGFloat
        let startRevealPadding: CGFloat
        let endRevealPadding: CGFloat
        let isEnabling: Bool
        let canvasScreenOrigin: CGPoint
    }

    init(sourceImage: CGImage, wallpaperImage: CGImage?, canvasFrame: CGRect) {
        self.sourceImage = sourceImage
        self.desktopWallpaperImage = wallpaperImage
        self.wallpaperImage = CaptureBackground.preferred().image(desktop: wallpaperImage)
        self.canvasFrame = canvasFrame
        super.init()
    }

    func present() {
        let activeWallpaper = appearance.usesDesktopBackdrop ? wallpaperImage : nil
        let framePadding = activeWallpaper == nil
            ? AnnotationFrameView.borderWidth
            : appearance.backdropMargin
        let panelFrame = canvasFrame.insetBy(
            dx: -framePadding,
            dy: -framePadding
        )
        let panel = AnnotationPanel(
            contentRect: panelFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let canvas = AnnotationCanvasView(sourceImage: sourceImage, session: session, style: style)
        let frameView = AnnotationFrameView(
            canvasSize: canvasFrame.size,
            wallpaperImage: activeWallpaper,
            padding: framePadding,
            accentColor: appearance.borderColor
        )
        canvas.frame = frameView.canvasRect
        canvas.onCopy = { [weak self] in self?.finish(copy: true) }
        canvas.onSave = { [weak self] in self?.finish(copy: false) }
        canvas.onCancel = { [weak self] in self?.onCancel?() }
        canvas.onToolChange = { [weak self] tool in self?.controlsView?.select(tool: tool) }
        frameView.addSubview(canvas)
        panel.contentView = frameView

        self.panel = panel
        canvasView = canvas
        self.frameView = frameView
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        presentControls(attachedTo: panel)
        if background == .system,
           let title = UserDefaults.standard.string(forKey: "systemWallpaperTitle"), title.hasSuffix(" (preview)"),
           let wallpaper = SystemWallpaper.available().first(where: { $0.title == String(title.dropLast(10)) && $0.canSelect }) {
            selectSystemWallpaper(wallpaper)
        }
    }

    func dismiss() {
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        backdropAnimationTimer?.invalidate()
        backdropAnimationTimer = nil
        backdropTransition = nil
        canvasView?.endCaptionEditing()
        if let controlsPanel {
            panel?.removeChildWindow(controlsPanel)
            controlsPanel.orderOut(nil)
        }
        controlsPanel = nil
        controlsView = nil
        panel?.orderOut(nil)
        panel = nil
        canvasView = nil
        frameView = nil
    }

    func focus() {
        guard let panel else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        controlsPanel?.orderFrontRegardless()
        panel.makeKey()
        if panel.firstResponder == nil, let canvasView {
            panel.makeFirstResponder(canvasView)
        }
    }

    func updateStyle(_ updatedStyle: AnnotationStyle) {
        style = updatedStyle
        canvasView?.updateStyle(updatedStyle)
        controlsView?.updateArrowSize(updatedStyle.lineWidth)
        controlsView?.updateTextSize(updatedStyle.fontSize)
    }

    func updateBorderColor(_ color: NSColor) {
        appearance.borderColor = color
        frameView?.accentColor = color
    }

    private func presentControls(attachedTo panel: NSPanel) {
        let controls = AnnotationControlsView(
            tool: session.tool,
            arrowSize: style.lineWidth,
            textSize: style.fontSize,
            enabled: appearance.usesDesktopBackdrop,
            margin: appearance.backdropMargin,
            backdropAvailable: wallpaperImage != nil,
            background: background,
            desktopAvailable: desktopWallpaperImage != nil
        )
        controls.onSystemWallpaperChange = { [weak self] wallpaper in self?.selectSystemWallpaper(wallpaper) }
        controls.onBackgroundChange = { [weak self] background in self?.selectBackground(background) }
        controls.onToolChange = { [weak self] tool in self?.canvasView?.chooseTool(tool) }
        controls.onUndo = { [weak self] in self?.canvasView?.undo() }
        controls.onRedo = { [weak self] in self?.canvasView?.redo() }
        controls.onSave = { [weak self] in self?.finish(copy: false) }
        controls.onCopy = { [weak self] in self?.finish(copy: true) }
        controls.onSettings = { [weak self] in self?.onSettings?() }
        controls.onArrowSizeChange = { [weak self] size in self?.setArrowSize(size) }
        controls.onTextSizeChange = { [weak self] size in self?.setTextSize(size) }
        controls.onEnabledChange = { [weak self] enabled in
            self?.setBackdropEnabled(enabled)
        }
        controls.onMarginChange = { [weak self] margin in
            self?.setBackdropMargin(margin)
        }

        let controlsPanel = NSPanel(
            contentRect: CGRect(origin: .zero, size: controls.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlsPanel.level = .screenSaver
        controlsPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        controlsPanel.isOpaque = false
        controlsPanel.backgroundColor = .clear
        controlsPanel.hasShadow = true
        controlsPanel.contentView = controls
        panel.addChildWindow(controlsPanel, ordered: .above)
        self.controlsPanel = controlsPanel
        controlsView = controls
        controls.updateBackgroundPreview(wallpaperImage)
        positionControls()
        controlsPanel.orderFrontRegardless()
    }

    private func selectSystemWallpaper(_ wallpaper: SystemWallpaper) {
        canvasView?.endCaptionEditing()
        backgroundLoadTask?.cancel()
        controlsView?.setBackgroundLoading(true)
        backgroundLoadTask = Task { [weak self] in
            do {
                let image = try await wallpaper.resolvedImage()
                try Task.checkCancellation()
                guard let self, panel != nil else { return }
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CaptureError.cropFailed }
                let destination = CaptureBackground.systemImageURL
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                UserDefaults.standard.set(wallpaper.title, forKey: "systemWallpaperTitle")
                background = .system
                wallpaperImage = image
                background.remember()
                appearance.usesDesktopBackdrop = true
                UserDefaults.standard.set(true, forKey: "usesDesktopBackdrop")
                controlsView?.updateBackground(.system, available: true, enabled: true)
                updateBackdropLayout(animated: false)
                controlsView?.setBackgroundLoading(false)
                backgroundLoadTask = nil
                focus()
            } catch {
                guard !Task.isCancelled, let self else { return }
                controlsView?.setBackgroundLoading(false)
                backgroundLoadTask = nil
                onError?(error)
            }
        }
    }

    private func selectBackground(_ selected: CaptureBackground) {
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        controlsView?.setBackgroundLoading(false)
        canvasView?.endCaptionEditing()
        var image: CGImage?
        if selected == .custom {
            let picker = NSOpenPanel()
            picker.title = "Choose screenshot background"
            picker.allowedContentTypes = [.image]
            picker.allowsMultipleSelection = false
            picker.canChooseDirectories = false
            picker.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            guard picker.runModal() == .OK, let url = picker.url else {
                controlsView?.updateBackground(background, available: wallpaperImage != nil, enabled: appearance.usesDesktopBackdrop)
                return
            }
            do {
                image = try CaptureBackground.importImage(at: url)
            } catch {
                controlsView?.updateBackground(background, available: wallpaperImage != nil, enabled: appearance.usesDesktopBackdrop)
                onError?(error)
                return
            }
        } else {
            image = selected.image(desktop: desktopWallpaperImage)
        }
        guard let image else { return }
        background = selected
        wallpaperImage = image
        selected.remember()
        appearance.usesDesktopBackdrop = true
        UserDefaults.standard.set(true, forKey: "usesDesktopBackdrop")
        controlsView?.updateBackground(selected, available: true, enabled: true)
        updateBackdropLayout(animated: false)
        focus()
    }

    private func setBackdropEnabled(_ enabled: Bool) {
        guard wallpaperImage != nil else { return }
        appearance.usesDesktopBackdrop = enabled
        UserDefaults.standard.set(enabled, forKey: "usesDesktopBackdrop")
        updateBackdropLayout(animated: true)
    }

    private func setArrowSize(_ size: CGFloat) {
        let size = min(12, max(2, size))
        style.lineWidth = size
        UserDefaults.standard.set(size, forKey: "annotationLineWidth")
        canvasView?.setArrowSize(size)
    }

    private func setTextSize(_ size: CGFloat) {
        let size = min(48, max(10, size))
        style.fontSize = size
        UserDefaults.standard.set(size, forKey: "annotationFontSize")
        canvasView?.setTextSize(size)
    }

    private func setBackdropMargin(_ margin: CGFloat) {
        appearance.backdropMargin = min(80, max(32, margin))
        UserDefaults.standard.set(appearance.backdropMargin, forKey: "backdropMargin")
        if appearance.usesDesktopBackdrop { updateBackdropLayout(animated: false) }
    }

    private func updateBackdropLayout(animated: Bool) {
        controlsView?.updateBackgroundPreview(wallpaperImage)
        guard let panel, let frameView, let canvasView else { return }
        let canvasOrigin = CGPoint(
            x: panel.frame.minX + frameView.canvasRect.minX,
            y: panel.frame.minY + frameView.canvasRect.minY
        )
        let activeWallpaper = appearance.usesDesktopBackdrop ? wallpaperImage : nil
        let padding = activeWallpaper == nil ? AnnotationFrameView.borderWidth : appearance.backdropMargin
        let panelFrame = CGRect(
            x: canvasOrigin.x - padding,
            y: canvasOrigin.y - padding,
            width: canvasFrame.width + padding * 2,
            height: canvasFrame.height + padding * 2
        )

        guard animated else {
            backdropAnimationTimer?.invalidate()
            backdropAnimationTimer = nil
            backdropTransition = nil
            panel.setFrame(panelFrame, display: true)
            frameView.wallpaperReferencePadding = appearance.backdropMargin
            frameView.update(wallpaperImage: activeWallpaper, padding: padding)
            frameView.wallpaperOpacity = activeWallpaper == nil ? 0 : 1
            frameView.wallpaperRevealPadding = activeWallpaper == nil ? 0 : padding
            canvasView.frame = frameView.canvasRect
            panel.invalidateCursorRects(for: frameView)
            reattachControlsIfNeeded()
            positionControls()
            return
        }

        let isEnabling = activeWallpaper != nil
        backdropAnimationTimer?.invalidate()
        detachControlsForTransition()
        animateControls(toMatch: panelFrame, isEnabling: isEnabling)
        frameView.wallpaperReferencePadding = appearance.backdropMargin
        frameView.update(wallpaperImage: wallpaperImage, padding: frameView.padding)
        if isEnabling, frameView.wallpaperOpacity <= 0 { frameView.wallpaperOpacity = 0 }
        backdropTransition = BackdropTransition(
            startTime: ProcessInfo.processInfo.systemUptime,
            duration: isEnabling ? 0.30 : 0.36,
            startPanelFrame: panel.frame,
            endPanelFrame: panelFrame,
            startOpacity: frameView.wallpaperOpacity,
            endOpacity: isEnabling ? 1 : 0,
            startRevealPadding: frameView.wallpaperRevealPadding,
            endRevealPadding: isEnabling ? appearance.backdropMargin : 0,
            isEnabling: isEnabling,
            canvasScreenOrigin: canvasOrigin
        )
        let refreshRate = max(60, panel.screen?.maximumFramesPerSecond ?? 60)
        let timer = Timer(
            timeInterval: 1 / Double(refreshRate),
            target: self,
            selector: #selector(backdropTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        backdropAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func backdropTimerFired(_ timer: Timer) {
        advanceBackdropTransition(timer: timer)
    }

    private func advanceBackdropTransition(timer: Timer) {
        guard let transition = backdropTransition,
              let panel, let frameView, let canvasView else {
            timer.invalidate()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - transition.startTime
        let linearProgress = min(1, max(0, elapsed / transition.duration))
        let geometryProgress = BackdropMotionCurve.geometry(
            at: linearProgress,
            isEnabling: transition.isEnabling
        )
        let opacityProgress = BackdropMotionCurve.opacity(
            at: linearProgress,
            isEnabling: transition.isEnabling
        )
        let panelFrame = interpolate(transition.startPanelFrame, transition.endPanelFrame, geometryProgress)
        let opacity = interpolate(transition.startOpacity, transition.endOpacity, opacityProgress)
        let revealPadding = interpolate(
            transition.startRevealPadding,
            transition.endRevealPadding,
            geometryProgress
        )

        panel.setFrame(panelFrame, display: true)
        let actualPanelFrame = panel.frame
        let anchoredCanvasOrigin = CGPoint(
            x: transition.canvasScreenOrigin.x - actualPanelFrame.minX,
            y: transition.canvasScreenOrigin.y - actualPanelFrame.minY
        )
        frameView.update(wallpaperImage: wallpaperImage, canvasOrigin: anchoredCanvasOrigin)
        frameView.wallpaperOpacity = opacity
        frameView.wallpaperRevealPadding = revealPadding
        canvasView.frame = frameView.canvasRect

        guard linearProgress >= 1 else { return }
        timer.invalidate()
        backdropAnimationTimer = nil
        backdropTransition = nil
        if !transition.isEnabling {
            frameView.update(wallpaperImage: nil, canvasOrigin: frameView.canvasRect.origin)
        }
        panel.invalidateCursorRects(for: frameView)
        reattachControlsIfNeeded()
        positionControls()
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    private func interpolate(_ start: CGRect, _ end: CGRect, _ progress: CGFloat) -> CGRect {
        CGRect(
            x: interpolate(start.origin.x, end.origin.x, progress),
            y: interpolate(start.origin.y, end.origin.y, progress),
            width: interpolate(start.width, end.width, progress),
            height: interpolate(start.height, end.height, progress)
        )
    }

    private func positionControls() {
        guard let panel, let controlsPanel else { return }
        let origin = controlsOrigin(for: panel.frame, controlsSize: controlsPanel.frame.size)
        controlsPanel.setFrameOrigin(backingAligned(origin, for: controlsPanel))
    }

    private func detachControlsForTransition() {
        guard !controlsDetachedForTransition, let panel, let controlsPanel else { return }
        panel.removeChildWindow(controlsPanel)
        controlsDetachedForTransition = true
        controlsPanel.orderFrontRegardless()
    }

    private func animateControls(toMatch panelFrame: CGRect, isEnabling: Bool) {
        guard let controlsPanel else { return }
        let rawOrigin = controlsOrigin(for: panelFrame, controlsSize: controlsPanel.frame.size)
        let targetOrigin = backingAligned(rawOrigin, for: controlsPanel)
        let targetFrame = CGRect(origin: targetOrigin, size: controlsPanel.frame.size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = isEnabling ? 0.30 : 0.36
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.12, 0.28, 1)
            controlsPanel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func reattachControlsIfNeeded() {
        guard controlsDetachedForTransition, let panel, let controlsPanel else { return }
        panel.addChildWindow(controlsPanel, ordered: .above)
        controlsDetachedForTransition = false
    }

    private func backingAligned(_ point: CGPoint, for window: NSWindow) -> CGPoint {
        let scale = max(1, window.backingScaleFactor)
        return CGPoint(
            x: (point.x * scale).rounded() / scale,
            y: (point.y * scale).rounded() / scale
        )
    }

    private func controlsOrigin(for panelFrame: CGRect, controlsSize size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(panelFrame) }) ?? panel?.screen
        let visibleFrame = screen?.visibleFrame ?? panelFrame.insetBy(dx: -100, dy: -100)
        let spaceBelow = panelFrame.minY - visibleFrame.minY
        let y = spaceBelow >= size.height + 10
            ? panelFrame.minY - size.height - 10
            : panelFrame.maxY + 10
        let centeredX = panelFrame.midX - size.width / 2
        let x = min(max(centeredX, visibleFrame.minX + 8), visibleFrame.maxX - size.width - 8)
        return CGPoint(x: x, y: y)
    }

    private func finish(copy: Bool) {
        guard backgroundLoadTask == nil else { return }
        guard let canvasView else { return }
        canvasView.endCaptionEditing()
        do {
            let annotatedImage = try AnnotationRenderer.render(
                source: sourceImage,
                canvasSize: canvasView.bounds.size,
                annotations: session.annotations,
                style: style
            )
            let image: CGImage
            if appearance.usesDesktopBackdrop, let wallpaperImage {
                image = try BackdropRenderer.compose(
                    screenshot: annotatedImage,
                    wallpaper: wallpaperImage,
                    canvasSize: canvasView.bounds.size,
                    margin: appearance.backdropMargin,
                    borderColor: appearance.borderColor
                )
            } else {
                image = annotatedImage
            }
            if copy { onCopy?(image) } else { onSave?(image) }
        } catch {
            onError?(error)
        }
    }
}

final class AnnotationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum BackdropMotionCurve {
    static func geometry(at progress: TimeInterval, isEnabling: Bool) -> CGFloat {
        snappySettle(progress)
    }

    static func opacity(at progress: TimeInterval, isEnabling: Bool) -> CGFloat {
        if isEnabling {
            return easeOutCubic(normalize(progress, from: 0, to: 0.48))
        }
        return easeInOutSine(normalize(progress, from: 0.08, to: 0.92))
    }

    private static func normalize(_ value: TimeInterval, from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        min(1, max(0, (value - start) / (end - start)))
    }

    private static func easeOutCubic(_ value: TimeInterval) -> CGFloat {
        CGFloat(1 - pow(1 - value, 3))
    }

    private static func easeOutQuart(_ value: TimeInterval) -> CGFloat {
        CGFloat(1 - pow(1 - value, 4))
    }

    private static func easeInOutSine(_ value: TimeInterval) -> CGFloat {
        CGFloat(-(cos(.pi * value) - 1) / 2)
    }

    private static func snappySettle(_ value: TimeInterval) -> CGFloat {
        let overshoot: TimeInterval = 1.034
        let rebound: TimeInterval = 0.994
        if value <= 0.62 {
            let travel = normalize(value, from: 0, to: 0.62)
            return CGFloat(overshoot) * easeOutQuart(travel)
        }
        if value <= 0.84 {
            let recoil = normalize(value, from: 0.62, to: 0.84)
            return CGFloat(overshoot + (rebound - overshoot) * Double(easeInOutSine(recoil)))
        }
        let settle = normalize(value, from: 0.84, to: 1)
        return CGFloat(rebound + (1 - rebound) * Double(easeInOutSine(settle)))
    }
}

final class AnnotationControlsView: NSView {
    private static let toolbarHeight: CGFloat = 56

    var onToolChange: ((AnnotationTool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSettings: (() -> Void)?
    var onArrowSizeChange: ((CGFloat) -> Void)?
    var onTextSizeChange: ((CGFloat) -> Void)?
    var onEnabledChange: ((Bool) -> Void)?
    var onMarginChange: ((CGFloat) -> Void)?
    var onSystemWallpaperChange: ((SystemWallpaper) -> Void)?
    var onBackgroundChange: ((CaptureBackground) -> Void)?
    private let backgroundPicker = BackgroundPickerButton(frame: .zero)
    private var selectedBackground: CaptureBackground = .desktop
    private let tools: LiquidGlassToolPicker
    private let toggle = NSSwitch()
    private let adjustmentsButton = NSButton()
    private var adjustmentsPopover: NSPopover?
    private var adjustmentsLocalMonitor: Any?
    private var adjustmentsGlobalMonitor: Any?
    private var selectedTool: AnnotationTool
    private var arrowSize: CGFloat
    private var textSize: CGFloat
    private var backdropMargin: CGFloat
    private var backdropAvailable: Bool

    init(tool: AnnotationTool, arrowSize: CGFloat, textSize: CGFloat, enabled: Bool, margin: CGFloat, backdropAvailable: Bool, background: CaptureBackground = .desktop, desktopAvailable: Bool = true) {
        tools = LiquidGlassToolPicker(selectedTool: tool)
        selectedTool = tool
        self.arrowSize = arrowSize
        self.textSize = textSize
        backdropMargin = margin
        self.backdropAvailable = backdropAvailable
        super.init(frame: CGRect(x: 0, y: 0, width: 560, height: Self.toolbarHeight))
        let contentHost = makeGlassContentHost()

        tools.onChange = { [weak self] tool in
            self?.selectedTool = tool
            self?.closeAdjustments()
            self?.updateAdjustmentsButton()
            self?.onToolChange?(tool)
        }

        let undoButton = symbolButton("arrow.uturn.backward", label: "Undo", action: #selector(undoPressed), glass: false)
        let redoButton = symbolButton("arrow.uturn.forward", label: "Redo", action: #selector(redoPressed), glass: false)

        selectedBackground = background
        backgroundPicker.title = "Background"
        backgroundPicker.isBordered = false
        backgroundPicker.toolTip = "Choose screenshot background"
        NSLayoutConstraint.activate([
            backgroundPicker.widthAnchor.constraint(equalToConstant: 142),
            backgroundPicker.heightAnchor.constraint(equalToConstant: 34),
        ])
        backgroundPicker.target = self
        backgroundPicker.action = #selector(backgroundGalleryPressed)
        backgroundPicker.setAccessibilityLabel("Choose screenshot background")

        toggle.state = enabled && backdropAvailable ? .on : .off
        toggle.isEnabled = backdropAvailable
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        toggle.setAccessibilityLabel("Show screenshot background")

        adjustmentsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Adjustments")
        adjustmentsButton.target = self
        adjustmentsButton.action = #selector(adjustmentsPressed)
        adjustmentsButton.isBordered = false
        adjustmentsButton.controlSize = .small
        adjustmentsButton.toolTip = "Adjustments"
        adjustmentsButton.setAccessibilityLabel("Annotation and backdrop adjustments")

        let saveButton = symbolButton("square.and.arrow.down", label: "Save", action: #selector(savePressed), glass: false)
        let settingsButton = symbolButton("gearshape", label: "Settings", action: #selector(settingsPressed), glass: false)
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyPressed))
        if #available(macOS 26.0, *) {
            copyButton.bezelStyle = .glass
        } else {
            copyButton.bezelStyle = .push
        }
        copyButton.bezelColor = .controlAccentColor
        copyButton.contentTintColor = .white
        copyButton.controlSize = .regular
        copyButton.font = .systemFont(ofSize: 12, weight: .semibold)
        copyButton.keyEquivalent = "\r"
        copyButton.setAccessibilityLabel("Copy screenshot")

        let stack = NSStackView(views: [tools, divider(), undoButton, redoButton, divider(), backgroundPicker, toggle, adjustmentsButton, divider(), settingsButton, saveButton, copyButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tools.widthAnchor.constraint(equalToConstant: 108),
        ])
        let fittedWidth = ceil(stack.fittingSize.width) + 36
        setFrameSize(CGSize(width: fittedWidth, height: Self.toolbarHeight))
        contentHost.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
        ])
        updateAdjustmentsButton()

        if !backdropAvailable {
            toggle.toolTip = "Choose a background to enable the backdrop."
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    func select(tool: AnnotationTool) {
        tools.select(tool)
        selectedTool = tool
        closeAdjustments()
        updateAdjustmentsButton()
    }

    func updateArrowSize(_ size: CGFloat) {
        arrowSize = min(12, max(2, size))
    }

    func updateTextSize(_ size: CGFloat) {
        textSize = min(48, max(10, size))
    }

    func updateBackgroundPreview(_ image: CGImage?) {
        backgroundPicker.preview = image.map { NSImage(cgImage: $0, size: .zero) }
    }

    func setBackgroundLoading(_ loading: Bool) {
        backgroundPicker.isLoading = loading
        backgroundPicker.toolTip = loading ? "Loading full-resolution wallpaper…" : "Choose screenshot background"
    }

    func updateBackground(_ background: CaptureBackground, available: Bool, enabled: Bool) {
        selectedBackground = background
        let name = background == .system ? (UserDefaults.standard.string(forKey: "systemWallpaperTitle") ?? background.title) : background.title
        backgroundPicker.setAccessibilityValue(name)
        backdropAvailable = available
        toggle.isEnabled = available
        toggle.state = enabled && available ? .on : .off
        updateAdjustmentsButton()
    }

    @objc private func backgroundGalleryPressed() {
        if adjustmentsPopover?.isShown == true {
            closeAdjustments()
            return
        }
        let gallery = BackgroundGalleryView(selected: selectedBackground)
        gallery.onSelect = { [weak self] background in
            self?.closeAdjustments()
            self?.onBackgroundChange?(background)
        }
        gallery.onWallpaper = { [weak self] wallpaper in
            self?.closeAdjustments()
            self?.onSystemWallpaperChange?(wallpaper)
        }
        gallery.onClose = { [weak self] in self?.closeAdjustments() }
        let controller = NSViewController()
        controller.view = gallery
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentSize = gallery.frame.size
        popover.contentViewController = controller
        adjustmentsPopover = popover
        backgroundPicker.isGalleryOpen = true
        popover.show(relativeTo: backgroundPicker.bounds, of: backgroundPicker, preferredEdge: .minY)
        installAdjustmentsDismissMonitors()
    }

    @objc private func undoPressed() { onUndo?() }
    @objc private func redoPressed() { onRedo?() }
    @objc private func savePressed() { onSave?() }
    @objc private func copyPressed() { onCopy?() }
    @objc private func settingsPressed() { onSettings?() }

    @objc private func toggleChanged() {
        let enabled = toggle.state == .on
        closeAdjustments()
        updateAdjustmentsButton()
        onEnabledChange?(enabled)
    }

    @objc private func adjustmentsPressed() {
        if adjustmentsPopover?.isShown == true {
            closeAdjustments()
            return
        }
        let view = AnnotationAdjustmentsView(
            tool: selectedTool,
            arrowSize: arrowSize,
            textSize: textSize,
            backdropEnabled: toggle.state == .on && toggle.isEnabled,
            backdropMargin: backdropMargin
        )
        view.onArrowSizeChange = { [weak self] size in
            self?.arrowSize = size
            self?.onArrowSizeChange?(size)
        }
        view.onTextSizeChange = { [weak self] size in
            self?.textSize = size
            self?.onTextSizeChange?(size)
        }
        view.onMarginChange = { [weak self] margin in
            self?.backdropMargin = margin
            self?.onMarginChange?(margin)
        }
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        // A transient popover treats the activation click from our
        // non-activating toolbar panel as an outside interaction and closes
        // before an NSSlider can begin tracking. Point owns dismissal instead.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentSize = view.frame.size
        popover.contentViewController = controller
        adjustmentsPopover = popover
        popover.show(relativeTo: adjustmentsButton.bounds, of: adjustmentsButton, preferredEdge: .minY)
        installAdjustmentsDismissMonitors()
    }

    private func closeAdjustments() {
        backgroundPicker.isGalleryOpen = false
        removeAdjustmentsDismissMonitors()
        adjustmentsPopover?.performClose(nil)
        adjustmentsPopover = nil
    }

    private func installAdjustmentsDismissMonitors() {
        removeAdjustmentsDismissMonitors()
        adjustmentsLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                closeAdjustments()
                return nil
            }
            let popoverWindow = adjustmentsPopover?.contentViewController?.view.window
            if event.window !== popoverWindow,
               event.window !== adjustmentsButton.window {
                closeAdjustments()
            }
            return event
        }
        adjustmentsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closeAdjustments()
        }
    }

    private func removeAdjustmentsDismissMonitors() {
        if let adjustmentsLocalMonitor {
            NSEvent.removeMonitor(adjustmentsLocalMonitor)
            self.adjustmentsLocalMonitor = nil
        }
        if let adjustmentsGlobalMonitor {
            NSEvent.removeMonitor(adjustmentsGlobalMonitor)
            self.adjustmentsGlobalMonitor = nil
        }
    }

    deinit {
        removeAdjustmentsDismissMonitors()
    }

    private func updateAdjustmentsButton() {
        adjustmentsButton.isEnabled = true
    }

    private func symbolButton(_ symbol: String, label: String, action: Selector, glass: Bool) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = glass
        if glass {
            if #available(macOS 26.0, *) {
                button.bezelStyle = .glass
            } else {
                button.bezelStyle = .accessoryBarAction
            }
        }
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func makeGlassContentHost() -> NSView {
        let contentHost = NSView(frame: bounds)
        contentHost.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = Self.toolbarHeight / 2
            glass.style = .regular
            glass.tintColor = NSColor.white.withAlphaComponent(0.08)
            glass.contentView = contentHost
            addSubview(glass)
        } else {
            let glass = NSVisualEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.appearance = NSAppearance(named: .aqua)
            glass.wantsLayer = true
            glass.layer?.cornerRadius = Self.toolbarHeight / 2
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.layer?.borderWidth = 1
            glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.58).cgColor
            glass.addSubview(contentHost)
            addSubview(glass)
        }
        return contentHost
    }

    private func divider() -> NSBox {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return divider
    }

}

final class AnnotationAdjustmentsView: NSView {
    var onArrowSizeChange: ((CGFloat) -> Void)?
    var onTextSizeChange: ((CGFloat) -> Void)?
    var onMarginChange: ((CGFloat) -> Void)?

    private var arrowSlider: NSSlider?
    private var arrowValueLabel: NSTextField?
    private var textSlider: NSSlider?
    private var textValueLabel: NSTextField?
    private var marginSlider: NSSlider?
    private var marginValueLabel: NSTextField?

    init(tool: AnnotationTool, arrowSize: CGFloat, textSize: CGFloat, backdropEnabled: Bool, backdropMargin: CGFloat) {
        let rowCount = 1 + (tool == .arrow ? 1 : 0) + (backdropEnabled ? 1 : 0)
        super.init(frame: CGRect(x: 0, y: 0, width: 300, height: CGFloat(rowCount * 44 + 24)))
        let contentHost = makeGlassContentHost()
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false

        if tool == .arrow {
            let row = adjustmentRow(title: "Arrow size", value: arrowSize, range: 2...12, action: #selector(arrowSizeChanged))
            arrowSlider = row.slider
            arrowValueLabel = row.valueLabel
            rows.addArrangedSubview(row.view)
        }
        let textRow = adjustmentRow(title: "Text size", value: textSize, range: 10...48, action: #selector(textSizeChanged))
        textSlider = textRow.slider
        textValueLabel = textRow.valueLabel
        rows.addArrangedSubview(textRow.view)
        if backdropEnabled {
            let row = adjustmentRow(title: "Backdrop margin", value: backdropMargin, range: 32...80, action: #selector(marginChanged))
            marginSlider = row.slider
            marginValueLabel = row.valueLabel
            rows.addArrangedSubview(row.view)
        }
        contentHost.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -16),
            rows.centerYAnchor.constraint(equalTo: contentHost.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func arrowSizeChanged() {
        guard let arrowSlider else { return }
        let value = CGFloat(arrowSlider.doubleValue.rounded())
        arrowSlider.doubleValue = Double(value)
        arrowValueLabel?.stringValue = "\(Int(value)) pt"
        onArrowSizeChange?(value)
    }

    @objc private func textSizeChanged() {
        guard let textSlider else { return }
        let value = CGFloat(textSlider.doubleValue.rounded())
        textSlider.doubleValue = Double(value)
        textValueLabel?.stringValue = "\(Int(value)) pt"
        onTextSizeChange?(value)
    }

    @objc private func marginChanged() {
        guard let marginSlider else { return }
        let value = CGFloat(marginSlider.doubleValue.rounded())
        marginSlider.doubleValue = Double(value)
        marginValueLabel?.stringValue = "\(Int(value)) pt"
        onMarginChange?(value)
    }

    private func adjustmentRow(title: String, value: CGFloat, range: ClosedRange<Double>, action: Selector) -> (view: NSView, slider: NSSlider, valueLabel: NSTextField) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        let slider = NSSlider(value: Double(value), minValue: range.lowerBound, maxValue: range.upperBound, target: self, action: action)
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        let valueLabel = NSTextField(labelWithString: "\(Int(value.rounded())) pt")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        let row = NSStackView(views: [titleLabel, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 268),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 105),
            valueLabel.widthAnchor.constraint(equalToConstant: 38),
        ])
        return (row, slider, valueLabel)
    }

    private func makeGlassContentHost() -> NSView {
        let contentHost = NSView(frame: bounds)
        contentHost.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = 18
            glass.style = .regular
            glass.tintColor = NSColor.white.withAlphaComponent(0.08)
            glass.contentView = contentHost
            addSubview(glass)
        } else {
            let glass = NSVisualEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.addSubview(contentHost)
            addSubview(glass)
        }
        return contentHost
    }
}

final class LiquidGlassToolPicker: NSView {
    var onChange: ((AnnotationTool) -> Void)?

    private let values: [AnnotationTool] = [.arrow, .blur, .redaction]
    private var buttons: [NSButton] = []
    private var glassBackgrounds: [NSView] = []
    private var selectedTool: AnnotationTool

    init(selectedTool: AnnotationTool) {
        self.selectedTool = selectedTool
        super.init(frame: CGRect(x: 0, y: 0, width: 108, height: 36))
        translatesAutoresizingMaskIntoConstraints = false

        let symbols = ["arrow.up.right", "square.grid.3x3.fill", "rectangle.fill"]
        let labels = ["Arrow (A)", "Blur (B)", "Redact (R)"]
        let itemViews: [NSView] = zip(symbols, labels).enumerated().map { index, value in
            makeItem(symbol: value.0, label: value.1, index: index)
        }
        let stack = NSStackView(views: itemViews)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ tool: AnnotationTool) {
        selectedTool = tool
        updateSelection()
    }

    @objc private func pressed(_ sender: NSButton) {
        guard values.indices.contains(sender.tag) else { return }
        selectedTool = values[sender.tag]
        updateSelection()
        onChange?(selectedTool)
    }

    private func makeItem(symbol: String, label: String, index: Int) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: #selector(pressed(_:)))
        button.tag = index
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        button.autoresizingMask = [.width, .height]
        buttons.append(button)

        let background = NSView(frame: CGRect(x: 0, y: 0, width: 34, height: 34))
        background.wantsLayer = true
        background.layer?.cornerRadius = 17
        background.layer?.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false
        background.widthAnchor.constraint(equalToConstant: 34).isActive = true
        background.heightAnchor.constraint(equalToConstant: 34).isActive = true
        background.addSubview(button)
        glassBackgrounds.append(background)
        return background
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            let selected = values[index] == selectedTool
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
            button.setAccessibilityValue(selected ? "Selected" : "Not selected")
            let background = glassBackgrounds[index]
            background.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
            background.layer?.borderWidth = selected ? 1 : 0
            background.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        }
    }
}

final class AnnotationFrameView: NSView {
    static let borderWidth: CGFloat = 12

    private(set) var canvasRect: CGRect
    private var wallpaperImage: CGImage?
    private(set) var padding: CGFloat
    var accentColor: NSColor {
        didSet { needsDisplay = true }
    }
    var wallpaperReferencePadding: CGFloat
    @objc dynamic var wallpaperOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var wallpaperRevealPadding: CGFloat {
        didSet {
            wallpaperRevealPadding = max(0, wallpaperRevealPadding)
            needsDisplay = true
        }
    }

    init(canvasSize: CGSize, wallpaperImage: CGImage?, padding: CGFloat, accentColor: NSColor) {
        self.wallpaperImage = wallpaperImage
        self.padding = padding
        self.accentColor = accentColor
        wallpaperReferencePadding = padding
        wallpaperRevealPadding = wallpaperImage == nil ? 0 : padding
        canvasRect = CGRect(
            origin: CGPoint(x: padding, y: padding),
            size: canvasSize
        )
        super.init(frame: CGRect(
            origin: .zero,
            size: CGSize(
                width: canvasSize.width + padding * 2,
                height: canvasSize.height + padding * 2
            )
        ))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Captured screenshot frame")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "wallpaperOpacity" { return CABasicAnimation() }
        return super.defaultAnimation(forKey: key)
    }

    func update(wallpaperImage: CGImage?, padding: CGFloat) {
        self.wallpaperImage = wallpaperImage
        self.padding = padding
        canvasRect = CGRect(
            origin: CGPoint(x: padding, y: padding),
            size: canvasRect.size
        )
        needsDisplay = true
    }

    func update(wallpaperImage: CGImage?, canvasOrigin: CGPoint) {
        self.wallpaperImage = wallpaperImage
        padding = min(canvasOrigin.x, canvasOrigin.y)
        canvasRect.origin = canvasOrigin
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let width = padding
        addCursorRect(CGRect(x: 0, y: 0, width: bounds.width, height: width), cursor: .openHand)
        addCursorRect(CGRect(x: 0, y: bounds.height - width, width: bounds.width, height: width), cursor: .openHand)
        addCursorRect(CGRect(x: 0, y: width, width: width, height: bounds.height - width * 2), cursor: .openHand)
        addCursorRect(CGRect(x: bounds.width - width, y: width, width: width, height: bounds.height - width * 2), cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if let wallpaperImage {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(wallpaperOpacity)
            let revealRect = canvasRect
                .insetBy(dx: -wallpaperRevealPadding, dy: -wallpaperRevealPadding)
                .intersection(bounds)
                .insetBy(dx: 0.75, dy: 0.75)
            let revealRadius = min(24, 13 + wallpaperRevealPadding)
            NSBezierPath(
                roundedRect: revealRect,
                xRadius: revealRadius,
                yRadius: revealRadius
            ).addClip()
            let referenceRect = canvasRect.insetBy(
                dx: -wallpaperReferencePadding,
                dy: -wallpaperReferencePadding
            )
            drawAspectFill(image: wallpaperImage, in: referenceRect)
            NSColor.black.withAlphaComponent(0.12).setFill()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let outerRect = canvasRect.insetBy(dx: -Self.borderWidth, dy: -Self.borderWidth)
        let frameRing = NSBezierPath(roundedRect: outerRect, xRadius: 22, yRadius: 22)
        frameRing.append(NSBezierPath(roundedRect: canvasRect, xRadius: 13, yRadius: 13))
        frameRing.windingRule = .evenOdd

        NSGraphicsContext.saveGraphicsState()
        let wallpaperReveal = wallpaperImage == nil ? 0 : wallpaperOpacity
        GlassBorderPalette.fillColor(accent: accentColor, wallpaperReveal: wallpaperReveal).setFill()
        frameRing.fill()

        frameRing.addClip()
        let colors = GlassBorderPalette.gradientColors(
            accent: accentColor,
            wallpaperReveal: wallpaperReveal
        )
        let glass = NSGradient(colorsAndLocations:
            (colors[0], 0),
            (colors[1], 0.42),
            (colors[2], 0.7),
            (colors[3], 1)
        )
        glass?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        let outerHighlight = NSBezierPath(
            roundedRect: outerRect.insetBy(dx: 0.75, dy: 0.75),
            xRadius: 21,
            yRadius: 21
        )
        NSColor.white.withAlphaComponent(0.72).setStroke()
        outerHighlight.lineWidth = 1
        outerHighlight.stroke()

        NSGraphicsContext.saveGraphicsState()
        let innerEdge = NSBezierPath(
            roundedRect: canvasRect.insetBy(dx: -0.75, dy: -0.75),
            xRadius: 14,
            yRadius: 14
        )
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        shadow.set()
        GlassBorderPalette.innerEdgeColor(accent: accentColor).setStroke()
        innerEdge.lineWidth = 1.5
        innerEdge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawAspectFill(image: CGImage, in rect: CGRect) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: drawSize).draw(in: drawRect)
    }
}

@MainActor
final class AnnotationCanvasView: NSView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToolChange: ((AnnotationTool) -> Void)?

    private let sourceImage: CGImage
    private let session: AnnotationSession
    private var style: AnnotationStyle
    private var operation: DragOperation?
    private var preview: Annotation?
    private var pendingToolGesture: PendingToolGesture?
    private var pendingManipulation: PendingManipulation?
    private var captionEditor: CaptionTextView?
    private var editingAnnotationID: UUID?
    private var cancelArmedUntil: Date?
    private let hintView = LiquidGlassStatusView()

    private enum DragOperation {
        case createArrow(start: CGPoint)
        case createRectangle(tool: AnnotationTool, start: CGPoint)
        case move(id: UUID, previous: CGPoint)
        case resizeRectangle(id: UUID, anchor: CGPoint)
        case resizeArrow(id: UUID, tail: Bool)
        case resizeTextWidth(id: UUID, leftX: CGFloat)
        case resizeTextSize(id: UUID, startY: CGFloat, startSize: CGFloat)
    }

    private struct PendingToolGesture {
        let start: CGPoint
        let tool: AnnotationTool
        let clickCount: Int
    }

    private struct PendingManipulation {
        let start: CGPoint
        let operation: DragOperation
    }

    init(sourceImage: CGImage, session: AnnotationSession, style: AnnotationStyle) {
        self.sourceImage = sourceImage
        self.session = session
        self.style = style
        super.init(frame: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screenshot annotation canvas")
        addSubview(hintView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        hintView.setFrameOrigin(CGPoint(
            x: round((bounds.width - hintView.frame.width) / 2),
            y: 10
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        disarmCancel()
        // Clicking away from a caption finishes that edit but must not consume the
        // gesture: the same mouse-down may begin the next arrow/blur/redaction.
        if captionEditor != nil {
            commitCaptionEditing()
        }
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount >= 2 {
            if let hit = hitTestAnnotation(at: point),
               let annotation = session.annotation(id: hit.id) {
                switch annotation {
                case .arrow, .text:
                    session.select(hit.id)
                    beginTextEditing(annotationID: hit.id)
                case .blur, .redaction:
                    createStandaloneText(at: point)
                }
            } else {
                createStandaloneText(at: point)
            }
            return
        }

        if let selectedID = session.selectedID,
           let handle = resizeHandle(at: point, for: selectedID) {
            pendingManipulation = PendingManipulation(start: point, operation: handle)
            return
        }

        if let hit = hitTestAnnotation(at: point) {
            session.select(hit.id)
            needsDisplay = true
            pendingManipulation = PendingManipulation(
                start: point,
                operation: .move(id: hit.id, previous: point)
            )
            return
        }

        // Empty-canvas drags create with the current tool. Existing annotations
        // always win hit-testing so they remain directly manipulable.
        pendingToolGesture = PendingToolGesture(start: point, tool: session.tool, clickCount: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))

        if let pending = pendingManipulation, operation == nil {
            guard hypot(point.x - pending.start.x, point.y - pending.start.y) >= 3 else { return }
            session.checkpoint()
            operation = pending.operation
            pendingManipulation = nil
        }

        if let pending = pendingToolGesture, operation == nil {
            guard hypot(point.x - pending.start.x, point.y - pending.start.y) >= 3 else { return }
            session.select(nil)
            switch pending.tool {
            case .arrow:
                operation = .createArrow(start: pending.start)
            case .blur, .redaction:
                operation = .createRectangle(tool: pending.tool, start: pending.start)
            }
        }

        switch operation {
        case let .createArrow(start):
            preview = .arrow(ArrowAnnotation(id: UUID(), tail: start, head: point, caption: ""))
        case let .createRectangle(tool, start):
            let rect = rectangle(from: start, to: point)
            let value = RectangleAnnotation(id: UUID(), rect: rect)
            preview = tool == .blur ? .blur(value) : .redaction(value)
        case let .move(id, previous):
            guard var annotation = session.annotation(id: id) else { break }
            annotation.translate(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y), constrainedTo: bounds)
            session.update(annotation)
            operation = .move(id: id, previous: point)
        case let .resizeRectangle(id, anchor):
            guard let annotation = session.annotation(id: id) else { break }
            let rect = rectangle(from: anchor, to: point)
            switch annotation {
            case let .blur(value): session.update(.blur(RectangleAnnotation(id: value.id, rect: rect)))
            case let .redaction(value): session.update(.redaction(RectangleAnnotation(id: value.id, rect: rect)))
            default: break
            }
        case let .resizeArrow(id, tail):
            guard case var .arrow(value) = session.annotation(id: id) else { break }
            if tail { value.tail = point } else { value.head = point }
            session.update(.arrow(value))
        case let .resizeTextWidth(id, leftX):
            guard let annotation = session.annotation(id: id) else { break }
            let maximumWidth = Geometry.maximumUsefulTextWidth(
                text: textContent(for: annotation),
                fontSize: effectiveFontSize(for: annotation),
                canvas: bounds
            )
            let width = max(Geometry.minimumTextBoxWidth, min(maximumWidth, point.x - leftX))
            switch annotation {
            case var .arrow(value): value.captionWidth = width; session.update(.arrow(value))
            case var .text(value): value.width = width; session.update(.text(value))
            case .blur, .redaction: break
            }
        case let .resizeTextSize(id, startY, startSize):
            guard let annotation = session.annotation(id: id) else { break }
            let size = max(10, min(48, startSize + (point.y - startY) * 0.28))
            switch annotation {
            case var .arrow(value): value.captionFontSize = size; session.update(.arrow(value))
            case var .text(value): value.fontSize = size; session.update(.text(value))
            case .blur, .redaction: break
            }
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            operation = nil
            preview = nil
            pendingToolGesture = nil
            pendingManipulation = nil
            needsDisplay = true
        }

        if pendingManipulation != nil {
            // A stationary press selected the hit annotation; no history entry or
            // tool change is necessary.
            return
        }

        if operation == nil, let pending = pendingToolGesture {
            if let hit = hitTestAnnotation(at: pending.start) {
                session.select(hit.id)
                if pending.clickCount >= 2,
                   let annotation = session.annotation(id: hit.id) {
                    switch annotation {
                    case .arrow, .text: beginTextEditing(annotationID: hit.id)
                    case .blur, .redaction: createStandaloneText(at: pending.start)
                    }
                }
            } else {
                if pending.clickCount >= 2 {
                    createStandaloneText(at: pending.start)
                } else {
                    session.select(nil)
                }
            }
            return
        }

        switch operation {
        case .createArrow:
            guard case let .arrow(arrow) = preview,
                  hypot(arrow.head.x - arrow.tail.x, arrow.head.y - arrow.tail.y) >= 5 else { return }
            session.append(.arrow(arrow))
        case .createRectangle:
            guard let preview, preview.bounds.width >= 4, preview.bounds.height >= 4 else { return }
            session.append(preview)
        default:
            break
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode != 53 { disarmCancel() }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                modifiers.contains(.shift) ? session.redo() : session.undo()
                needsDisplay = true
            case "s": onSave?()
            case "\r": onCopy?()
            default: super.keyDown(with: event)
            }
            return
        }

        switch event.keyCode {
        case 36, 76: onCopy?()
        case 51, 117:
            session.deleteSelection()
            needsDisplay = true
        case 53:
            if isCancelArmed {
                onCancel?()
                return
            }
            if operation != nil || pendingToolGesture != nil || pendingManipulation != nil {
                operation = nil
                preview = nil
                pendingToolGesture = nil
                pendingManipulation = nil
            }
            if session.selectedID != nil {
                session.select(nil)
            }
            needsDisplay = true
            armCancel()
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": setTool(.arrow)
            case "b": setTool(.blur)
            case "r": setTool(.redaction)
            default: super.keyDown(with: event)
            }
        }
    }

    func endCaptionEditing() {
        commitCaptionEditing()
    }

    func chooseTool(_ tool: AnnotationTool) {
        commitCaptionEditing()
        setTool(tool)
        window?.makeFirstResponder(self)
    }

    func undo() {
        commitCaptionEditing()
        session.undo()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func redo() {
        commitCaptionEditing()
        session.redo()
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func setArrowSize(_ size: CGFloat) {
        style.lineWidth = min(12, max(2, size))
        needsDisplay = true
    }

    func setTextSize(_ size: CGFloat) {
        let size = min(48, max(10, size))
        style.fontSize = size
        if let selectedID = session.selectedID,
           let annotation = session.annotation(id: selectedID) {
            switch annotation {
            case var .arrow(value):
                value.captionFontSize = size
                session.update(.arrow(value))
            case var .text(value):
                value.fontSize = size
                session.update(.text(value))
            case .blur, .redaction:
                break
            }
        }
        if let captionEditor, let editingAnnotationID {
            captionEditor.font = NSFont.systemFont(ofSize: size, weight: .semibold)
            captionEditor.frame = editingFrame(for: editingAnnotationID, text: captionEditor.string)
                .insetBy(dx: 1, dy: 1)
        }
        needsDisplay = true
    }

    func updateStyle(_ updatedStyle: AnnotationStyle) {
        style = updatedStyle
        if let captionEditor {
            captionEditor.layer?.borderColor = updatedStyle.color.cgColor
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: sourceImage, size: bounds.size).draw(in: bounds)
        let visibleAnnotations = session.annotations + (preview.map { [$0] } ?? [])
        AnnotationRenderer.draw(annotations: visibleAnnotations, source: sourceImage, canvasSize: bounds.size, style: style)
        drawSelection()
    }

    private func setTool(_ tool: AnnotationTool) {
        session.tool = tool
        session.select(nil)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onToolChange?(tool)
    }

    func beginTextEditing(annotationID: UUID) {
        guard let annotation = session.annotation(id: annotationID) else { return }
        endCaptionEditing()
        editingAnnotationID = annotationID
        let text: String
        let frame: CGRect
        switch annotation {
        case let .arrow(arrow):
            text = arrow.caption
            frame = Geometry.captionRect(for: arrow, text: text, style: style, canvas: bounds)
        case let .text(value):
            text = value.text
            frame = Geometry.standaloneTextRect(for: value, style: style, canvas: bounds)
        case .blur, .redaction:
            return
        }
        let editor = CaptionTextView(frame: frame.insetBy(dx: 1, dy: 1))
        editor.string = text
        editor.font = NSFont.systemFont(ofSize: effectiveFontSize(for: annotation), weight: .semibold)
        editor.textColor = .white
        editor.backgroundColor = NSColor.black.withAlphaComponent(0.84)
        editor.drawsBackground = true
        editor.wantsLayer = true
        editor.layer?.cornerRadius = 6
        editor.layer?.borderWidth = 2.5
        editor.layer?.borderColor = style.color.cgColor
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.textContainerInset = CGSize(width: 7, height: 4)
        editor.configureForAnnotationEditing()
        editor.setAccessibilityLabel("Annotation text")
        editor.onCommit = { [weak self] in self?.commitCaptionEditing() }
        editor.onCopy = { [weak self] in
            self?.commitCaptionEditing()
            self?.onCopy?()
        }
        editor.onCancel = { [weak self] in self?.commitCaptionEditing() }
        editor.onChange = { [weak self, weak editor] text in
            guard let self, let editor else { return }
            editor.frame = self.editingFrame(for: annotationID, text: text).insetBy(dx: 1, dy: 1)
        }
        addSubview(editor)
        captionEditor = editor
        refreshHint()
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    private func commitCaptionEditing() {
        guard let editor = captionEditor, let editingAnnotationID,
              let annotation = session.annotation(id: editingAnnotationID) else { return }
        let newText = editor.string.trimmingCharacters(in: .newlines)
        switch annotation {
        case var .arrow(arrow):
            if newText != arrow.caption {
                session.checkpoint()
                arrow.caption = newText
                session.update(.arrow(arrow))
            }
        case var .text(value):
            if newText.isEmpty {
                if value.text.isEmpty { session.cancelNewAnnotation(id: value.id) }
                else { session.remove(id: value.id) }
            } else if newText != value.text {
                session.checkpoint()
                value.text = newText
                session.update(.text(value))
            }
        case .blur, .redaction:
            break
        }
        editor.removeFromSuperview()
        captionEditor = nil
        self.editingAnnotationID = nil
        refreshHint()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func hitTestAnnotation(at point: CGPoint) -> (id: UUID, caption: Bool)? {
        // Match the visual stack: arrow geometry is on top, but only captures a
        // narrow hit corridor. The remaining area belongs to blur/redaction.
        for annotation in session.annotations.reversed() {
            switch annotation {
            case let .arrow(arrow):
                let captionRect = Geometry.captionRect(for: arrow, text: arrow.caption, style: style, canvas: bounds)
                if !arrow.caption.isEmpty, captionRect.insetBy(dx: -4, dy: -4).contains(point) { return (arrow.id, true) }
                if Geometry.distance(from: point, toSegmentFrom: arrow.tail, to: arrow.head) <= max(8, style.lineWidth + 4) { return (arrow.id, false) }
            case let .text(value):
                if Geometry.standaloneTextRect(for: value, style: style, canvas: bounds).insetBy(dx: -4, dy: -4).contains(point) { return (value.id, true) }
            case .blur, .redaction:
                continue
            }
        }
        for annotation in session.annotations.reversed() {
            switch annotation {
            case let .blur(value), let .redaction(value):
                if value.rect.standardized.insetBy(dx: -5, dy: -5).contains(point) { return (value.id, false) }
            case .arrow, .text:
                continue
            }
        }
        return nil
    }

    private func resizeHandle(at point: CGPoint, for id: UUID) -> DragOperation? {
        guard let annotation = session.annotation(id: id) else { return nil }
        if let textRect = textRect(for: annotation) {
            let widthHandle = CGPoint(x: textRect.maxX, y: textRect.midY)
            let sizeHandle = CGPoint(x: textRect.maxX, y: textRect.maxY)
            if hypot(point.x - sizeHandle.x, point.y - sizeHandle.y) <= 10 {
                return .resizeTextSize(id: id, startY: point.y, startSize: effectiveFontSize(for: annotation))
            }
            if hypot(point.x - widthHandle.x, point.y - widthHandle.y) <= 10 {
                return .resizeTextWidth(id: id, leftX: textRect.minX)
            }
        }
        switch annotation {
        case let .arrow(arrow):
            if hypot(point.x - arrow.tail.x, point.y - arrow.tail.y) <= 9 { return .resizeArrow(id: id, tail: true) }
            if hypot(point.x - arrow.head.x, point.y - arrow.head.y) <= 9 { return .resizeArrow(id: id, tail: false) }
        case let .blur(value), let .redaction(value):
            let rect = value.rect.standardized
            let corners = [
                (CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
                (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)),
                (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)),
                (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)),
            ]
            if let match = corners.first(where: { hypot(point.x - $0.0.x, point.y - $0.0.y) <= 9 }) {
                return .resizeRectangle(id: id, anchor: match.1)
            }
        case .text:
            break
        }
        return nil
    }

    private func drawSelection() {
        guard let selectedID = session.selectedID, let annotation = session.annotation(id: selectedID) else { return }
        let rawSelectionBounds: CGRect
        if case let .text(value) = annotation {
            rawSelectionBounds = Geometry.standaloneTextRect(for: value, style: style, canvas: bounds)
        } else {
            rawSelectionBounds = annotation.bounds
        }
        let selectionBounds = rawSelectionBounds.insetBy(dx: -4, dy: -4)

        if case .text = annotation {
            // The text box already has a visible border; handles alone communicate
            // selection without nesting another rectangle around it.
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = .zero
            shadow.set()
            let outline = NSBezierPath(roundedRect: selectionBounds, xRadius: 5, yRadius: 5)
            outline.setLineDash([7, 5], count: 2, phase: 0)
            style.color.setStroke()
            outline.lineWidth = 3
            outline.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        let points: [CGPoint]
        switch annotation {
        case let .arrow(arrow): points = [arrow.tail, arrow.head]
        case let .blur(value), let .redaction(value):
            let rect = value.rect.standardized
            points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
        case .text: points = []
        }
        for point in points {
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)).fill()
            style.color.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)).fill()
        }
        if let textRect = textRect(for: annotation) {
            drawTextResizeHandle(at: CGPoint(x: textRect.maxX, y: textRect.midY), diamond: false)
            drawTextResizeHandle(at: CGPoint(x: textRect.maxX, y: textRect.maxY), diamond: true)
        }
    }

    private func refreshHint() {
        if isCancelArmed {
            hintView.show(text: "Press Esc again to discard this screenshot", symbol: "escape")
        } else if captionEditor != nil {
            hintView.show(text: "↩ Finish caption  •  ⌥↩ New line  •  ⌘↩ Copy", symbol: "keyboard")
        } else {
            hintView.hide()
        }
        needsLayout = true
    }

    private var isCancelArmed: Bool {
        guard let cancelArmedUntil else { return false }
        return cancelArmedUntil > Date()
    }

    private func armCancel() {
        let deadline = Date().addingTimeInterval(2.5)
        cancelArmedUntil = deadline
        refreshHint()
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.cancelArmedUntil == deadline else { return }
            self.cancelArmedUntil = nil
            self.refreshHint()
            self.needsDisplay = true
        }
    }

    private func disarmCancel() {
        guard cancelArmedUntil != nil else { return }
        cancelArmedUntil = nil
        refreshHint()
        needsDisplay = true
    }

    private func rectangle(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }

    private func createStandaloneText(at point: CGPoint) {
        let value = TextAnnotation(id: UUID(), anchor: point, text: "")
        session.append(.text(value))
        beginTextEditing(annotationID: value.id)
    }

    private func effectiveFontSize(for annotation: Annotation) -> CGFloat {
        switch annotation {
        case let .arrow(value): value.captionFontSize ?? style.fontSize
        case let .text(value): value.fontSize ?? style.fontSize
        case .blur, .redaction: style.fontSize
        }
    }

    private func textContent(for annotation: Annotation) -> String {
        switch annotation {
        case let .arrow(value): value.caption
        case let .text(value): value.text
        case .blur, .redaction: ""
        }
    }

    private func textRect(for annotation: Annotation) -> CGRect? {
        switch annotation {
        case let .arrow(value):
            guard !value.caption.isEmpty else { return nil }
            return Geometry.captionRect(for: value, text: value.caption, style: style, canvas: bounds)
        case let .text(value):
            guard !value.text.isEmpty else { return nil }
            return Geometry.standaloneTextRect(for: value, style: style, canvas: bounds)
        case .blur, .redaction: return nil
        }
    }

    private func editingFrame(for id: UUID, text: String) -> CGRect {
        guard let annotation = session.annotation(id: id) else { return .zero }
        switch annotation {
        case var .arrow(value):
            value.caption = text
            return Geometry.captionRect(for: value, text: text, style: style, canvas: bounds)
        case var .text(value):
            value.text = text
            return Geometry.standaloneTextRect(for: value, style: style, canvas: bounds)
        case .blur, .redaction: return .zero
        }
    }

    private func drawTextResizeHandle(at point: CGPoint, diamond: Bool) {
        let rect = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
        let path = NSBezierPath(rect: rect)
        if diamond {
            var transform = AffineTransform.identity
            transform.translate(x: point.x, y: point.y)
            transform.rotate(byDegrees: 45)
            transform.translate(x: -point.x, y: -point.y)
            path.transform(using: transform)
        }
        NSColor.black.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 4
        path.stroke()
        style.color.setFill()
        path.fill()
        NSColor.white.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}

final class LiquidGlassStatusView: NSView {
    private static let height: CGFloat = 38
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 40, height: Self.height))
        isHidden = true
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        let contentHost = NSView(frame: bounds)
        contentHost.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.cornerRadius = Self.height / 2
            glass.style = .regular
            glass.tintColor = NSColor.white.withAlphaComponent(0.08)
            glass.contentView = contentHost
            addSubview(glass)
        } else {
            let glass = NSVisualEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.appearance = NSAppearance(named: .aqua)
            glass.wantsLayer = true
            glass.layer?.cornerRadius = Self.height / 2
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            glass.layer?.borderWidth = 1
            glass.layer?.borderColor = NSColor.white.withAlphaComponent(0.58).cgColor
            glass.addSubview(contentHost)
            addSubview(glass)
        }

        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        contentHost.addSubview(icon)
        contentHost.addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 17
        let labelSize = label.intrinsicContentSize
        let contentWidth = iconSize + 8 + labelSize.width
        let startX = round((bounds.width - contentWidth) / 2)
        icon.frame = CGRect(x: startX, y: round((bounds.height - iconSize) / 2), width: iconSize, height: iconSize)
        label.frame = CGRect(x: icon.frame.maxX + 8, y: round((bounds.height - labelSize.height) / 2), width: labelSize.width, height: labelSize.height)
    }

    func show(text: String, symbol: String) {
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        let width = ceil(label.intrinsicContentSize.width) + 17 + 8 + 28
        setFrameSize(CGSize(width: width, height: Self.height))
        setAccessibilityLabel(text)
        isHidden = false
        needsLayout = true
    }

    func hide() {
        isHidden = true
    }
}

final class CaptionTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChange: ((String) -> Void)?
    private var textStorageObserver: NSObjectProtocol?

    func configureForAnnotationEditing() {
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        // Geometry reserves 16 points horizontally. The editor's 7-point text
        // insets plus its 1-point frame inset already consume all 16, so the
        // default 5-point line-fragment padding would make live text wrap early.
        textContainer?.lineFragmentPadding = 0
        if let textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
        if let textStorage {
            textStorageObserver = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification,
                object: textStorage,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.onChange?(self.string)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 {
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            if modifiers.contains(.command) {
                onCopy?()
            } else if modifiers.contains(.option) {
                insertNewline(nil)
            } else {
                onCommit?()
            }
        } else {
            super.keyDown(with: event)
        }
    }

    deinit {
        if let textStorageObserver {
            NotificationCenter.default.removeObserver(textStorageObserver)
        }
    }
}


/// A thumbnail gallery matching Showcase's desktop-background browser.
@MainActor
final class BackgroundGalleryView: NSView {
    var onSelect: ((CaptureBackground) -> Void)?
    var onWallpaper: ((SystemWallpaper) -> Void)?
    var onClose: (() -> Void)?
    private let selected: CaptureBackground
    private let document = BackgroundGalleryDocument()
    private var actions: [() -> Void] = []
    private var nextY: CGFloat = 8
    private let status = NSTextField(labelWithString: "Loading macOS wallpapers…")

    init(selected: CaptureBackground) {
        self.selected = selected
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 520))
        let frost = NSVisualEffectView(frame: bounds)
        frost.autoresizingMask = [.width, .height]
        frost.material = .popover
        frost.blendingMode = .behindWindow
        frost.state = .active
        addSubview(frost)
        let tint = BackgroundGalleryTintView(frame: bounds)
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
        let title = NSTextField(labelWithString: "Backgrounds")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = CGRect(x: 24, y: 468, width: 400, height: 28)
        addSubview(title)
        let subtitle = NSTextField(labelWithString: "Choose a background. Your selection is remembered.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.frame = CGRect(x: 24, y: 444, width: 470, height: 20)
        addSubview(subtitle)
        let done = NSButton(title: "Done", target: self, action: #selector(closePressed))
        done.bezelStyle = .rounded
        done.frame = CGRect(x: 504, y: 467, width: 72, height: 28)
        addSubview(done)
        let scroll = NSScrollView(frame: CGRect(x: 22, y: 50, width: 556, height: 380))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        document.frame = CGRect(x: 0, y: 0, width: 552, height: 380)
        scroll.documentView = document
        addSubview(scroll)
        let choose = NSButton(title: "Choose image…", target: self, action: #selector(choosePressed))
        choose.bezelStyle = .rounded
        choose.frame = CGRect(x: 20, y: 12, width: 140, height: 28)
        addSubview(choose)
        let settings = NSButton(title: "Wallpaper Settings…", target: self, action: #selector(settingsPressed))
        settings.bezelStyle = .rounded
        settings.frame = CGRect(x: 406, y: 12, width: 172, height: 28)
        addSubview(settings)

        addHeading("Point backgrounds")
        let options: [CaptureBackground] = [.desktop, .aurora, .ocean, .sunset, .custom]
        for (index, option) in options.enumerated() {
            let button = addTile(title: option.title, column: index % 3,
                y: nextY + CGFloat(index / 3) * 142, selected: selected == option) { [weak self] in
                    self?.onSelect?(option)
                }
            let desktop = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            Task { [weak button] in
                let image = await Task.detached(priority: .userInitiated) {
                    option.image(desktop: desktop.flatMap { CaptureBackground.loadImage(at: $0) })
                }.value
                button?.preview = image.map { NSImage(cgImage: $0, size: .zero) }
            }
        }
        nextY += 284
        addHeading("macOS wallpapers")
        status.frame = CGRect(x: 4, y: nextY, width: 530, height: 24)
        status.textColor = .secondaryLabelColor
        document.addSubview(status)
        document.setFrameSize(CGSize(width: 552, height: nextY + 40))
        Task { [weak self] in
            let wallpapers = await Task.detached(priority: .userInitiated) { SystemWallpaper.available() }.value
            guard let self else { return }
            status.removeFromSuperview()
            for (index, wallpaper) in wallpapers.enumerated() {
                let isSelected = selected == .system && UserDefaults.standard.string(forKey: "systemWallpaperTitle") == wallpaper.title
                let button = addTile(title: wallpaper.title, column: index % 3,
                    y: nextY + CGFloat(index / 3) * 142, selected: isSelected) { [weak self] in
                        self?.onWallpaper?(wallpaper)
                    }
                button.isEnabled = wallpaper.canSelect
                if !wallpaper.canSelect {
                    button.title = wallpaper.title + " · Download in Settings"
                    button.toolTip = "Download \(wallpaper.title) in Wallpaper Settings to use the full-resolution image."
                }
                Task { [weak button] in
                    let image = await Task.detached(priority: .utility) {
                        if wallpaper.url.pathExtension == "mov" { return try? wallpaper.image() }
                        return CaptureBackground.loadImage(at: wallpaper.url, maxPixelSize: 360)
                    }.value
                    button?.preview = image.map { NSImage(cgImage: $0, size: .zero) }
                }
            }
            if wallpapers.isEmpty {
                status.stringValue = "No wallpapers found. Choose an image from your files."
                document.addSubview(status)
            }
            document.setFrameSize(CGSize(width: 552, height: nextY + max(40, CGFloat((wallpapers.count + 2) / 3) * 142)))
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addHeading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.frame = CGRect(x: 4, y: nextY, width: 530, height: 22)
        document.addSubview(label)
        nextY += 30
    }

    private func addTile(title: String, column: Int, y: CGFloat, selected: Bool, action: @escaping () -> Void) -> BackgroundThumbnailButton {
        let button = BackgroundThumbnailButton(frame: CGRect(x: 4 + CGFloat(column) * 182, y: y, width: 172, height: 132))
        button.title = title
        button.isSelectedBackground = selected
        button.toolTip = title
        button.setAccessibilityLabel("Use \(title) background")
        button.tag = actions.count
        actions.append(action)
        button.target = self
        button.action = #selector(tilePressed(_:))
        document.addSubview(button)
        return button
    }

    @objc private func tilePressed(_ sender: NSButton) { actions[sender.tag]() }
    @objc private func choosePressed() { onSelect?(.custom) }
    @objc private func closePressed() { onClose?() }
    @objc private func settingsPressed() {
        onClose?()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }
}

private final class BackgroundGalleryDocument: NSView {
    override var isFlipped: Bool { true }
}

final class BackgroundThumbnailButton: NSButton {
    var preview: NSImage? { didSet { needsDisplay = true } }
    var isSelectedBackground = false
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = CGRect(x: 2, y: 2, width: bounds.width - 4, height: 104)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.quaternaryLabelColor.setFill()
        rect.fill()
        if let preview, preview.size.width > 0, preview.size.height > 0 {
            let scale = max(rect.width / preview.size.width, rect.height / preview.size.height)
            let size = CGSize(width: preview.size.width * scale, height: preview.size.height * scale)
            preview.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.7 : 1, respectFlipped: true, hints: nil)
        } else {
            NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.draw(in: CGRect(x: rect.midX - 14, y: rect.midY - 12, width: 28, height: 24))
        }
        NSGraphicsContext.restoreGraphicsState()
        (isSelectedBackground ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        shape.lineWidth = isSelectedBackground ? 3 : 1
        shape.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: CGRect(x: 3, y: 113, width: bounds.width - 6, height: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelectedBackground ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }
}


private final class BackgroundGalleryTintView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.18).setFill()
        bounds.fill()
    }
}


/// A quiet toolbar control with a live swatch, rather than a standard form button.
final class BackgroundPickerButton: NSButton {
    var preview: NSImage? { didSet { needsDisplay = true } }
    var isGalleryOpen = false { didSet { needsDisplay = true } }
    var isLoading = false {
        didSet {
            isLoading ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
            needsDisplay = true
        }
    }
    private var isHovered = false
    private let spinner = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: 142, height: 34) }
    override func layout() {
        super.layout()
        spinner.frame = CGRect(x: bounds.width - 24, y: bounds.midY - 7, width: 14, height: 14)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        if isGalleryOpen || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(isHovered ? 0.08 : 0.035).setFill()
        }
        shape.fill()
        let swatch = CGRect(x: 5, y: bounds.midY - 12, width: 30, height: 24)
        let clip = NSBezierPath(roundedRect: swatch, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.quaternaryLabelColor.setFill()
        swatch.fill()
        if let preview, preview.size.width > 0, preview.size.height > 0 {
            let scale = max(swatch.width / preview.size.width, swatch.height / preview.size.height)
            let size = CGSize(width: preview.size.width * scale, height: preview.size.height * scale)
            preview.draw(in: CGRect(x: swatch.midX - size.width / 2, y: swatch.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.draw(in: swatch.insetBy(dx: 6, dy: 4))
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        clip.lineWidth = 0.75
        clip.stroke()
        ("Background" as NSString).draw(at: CGPoint(x: 42, y: bounds.midY - 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        if !isLoading {
            let chevron = NSBezierPath()
            let x = bounds.width - 15
            let y = bounds.midY
            chevron.move(to: CGPoint(x: x - 3, y: y + (isGalleryOpen ? -1.5 : 1.5)))
            chevron.line(to: CGPoint(x: x, y: y + (isGalleryOpen ? 1.5 : -1.5)))
            chevron.line(to: CGPoint(x: x + 3, y: y + (isGalleryOpen ? -1.5 : 1.5)))
            chevron.lineWidth = 1.3
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.secondaryLabelColor.setStroke()
            chevron.stroke()
        }
    }
}
