import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppCoordinator {
    private let captureService = ScreenCaptureService()
    private let permissionService = PermissionService()
    private lazy var onboardingProgress = OnboardingProgress(hasCaptureAccess: permissionService.hasCaptureAccess)
    private lazy var onboarding = OnboardingController(progress: onboardingProgress, permission: permissionService)
    private var isOnboardingCapture = false
    private let shortcutService = ShortcutService()
    private let trackpadShortcutService = TrackpadShortcutService()
    private let preferencesController = PreferencesController()
    private var overlayController: DisplayOverlayController?
    private var annotationController: AnnotationCanvasController?
    private var previewController: CapturePreviewController?
    private var confirmationController: CaptureConfirmationController?
    private var captureTask: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var captureItem = NSMenuItem(
        title: "Capture Region",
        action: #selector(beginCaptureFromMenu),
        keyEquivalent: ""
    )
    private lazy var shortcutInfoItem = NSMenuItem(title: "Shortcut: \(ShortcutChoice.preferred.title)", action: nil, keyEquivalent: "")
    private lazy var setupItem = NSMenuItem(title: "Finish Setup…", action: #selector(showSetup), keyEquivalent: "")

    func start() {
        showNormalStatusIcon()

        let menu = NSMenu()
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(shortcutInfoItem)
        setupItem.target = self
        setupItem.isHidden = onboardingProgress.isComplete
        menu.addItem(setupItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let permissionItem = NSMenuItem(
            title: "Screen Recording Settings…",
            action: #selector(openScreenRecordingSettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Point", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu

        do {
            try shortcutService.register(choice: .preferred) { [weak self] in
                self?.beginCapture()
            }
        } catch {
            captureItem.title = "Capture Region (shortcut unavailable)"
            if onboardingProgress.isComplete {
                showError(
                    title: "Shortcut unavailable",
                    message: "\(ShortcutChoice.preferred.title) is already registered by another app. You can still capture from the Point menu."
                )
            } else {
                onboarding.model.message = "\(ShortcutChoice.preferred.title) is in use by another app. You can capture from the Point menu or choose another shortcut in Settings."
            }
        }
        trackpadShortcutService.setEnabled(TrackpadShortcutPreference.isEnabled) { [weak self] in
            self?.beginCapture()
        }
        preferencesController.onShortcutChange = { [weak self] choice in
            guard let self else { return false }
            do {
                try shortcutService.change(to: choice)
                shortcutInfoItem.title = "Shortcut: \(choice.title)"
                captureItem.title = "Capture Region"
                return true
            } catch {
                showError(title: "Shortcut unavailable", message: "\(choice.title) is already registered. Point kept the previous working shortcut.")
                return false
            }
        }
        preferencesController.onTrackpadShortcutChange = { [weak self] enabled in
            guard let self else { return }
            trackpadShortcutService.setEnabled(enabled) { [weak self] in
                self?.beginCapture()
            }
        }
        preferencesController.onStyleChange = { [weak self] style in
            self?.annotationController?.updateStyle(style)
        }
        preferencesController.onBorderColorChange = { [weak self] color in
            self?.annotationController?.updateBorderColor(color)
        }
        onboarding.model.onFinish = { [weak self] in
            self?.onboarding.hide()
            self?.setupItem.isHidden = true
        }
        onboarding.model.onTryCapture = { [weak self] in
            self?.beginCapture()
        }
        if !onboardingProgress.isComplete {
            showSetup()
        }
    }

    @objc private func showSetup() {
        onboarding.show(shortcut: shortcutService.registeredChoice?.title)
    }

    @objc private func beginCaptureFromMenu() {
        beginCapture()
    }

    @objc private func showSettings() {
        preferencesController.show()
    }

    private func beginCapture() {
        if let annotationController {
            annotationController.focus()
            return
        }
        if let overlayController {
            overlayController.focus()
            return
        }
        guard captureTask == nil else { return }
        guard previewController?.isSaving != true, previewController?.isDragging != true else { return }
        if !onboardingProgress.isComplete {
            guard onboarding.model.page == .ready else {
                showSetup()
                return
            }
            // The shortcut and menu command also start the optional practice capture.
            onboarding.hide()
            isOnboardingCapture = true
        }
        guard permissionService.hasCaptureAccess else {
            isOnboardingCapture = false
            setupItem.isHidden = false
            onboarding.showPermissionRecovery(shortcut: shortcutService.registeredChoice?.title)
            return
        }
        previewController?.dismiss()
        previewController = nil
        confirmationController?.dismiss()
        confirmationController = nil

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost

        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }

            do {
                let snapshots = try await captureService.captureConnectedDisplays()
                guard !Task.isCancelled else { return }
                captureItem.title = "Capture Region"
                presentSelectionOverlays(for: snapshots)
            } catch {
                handleCaptureError(error)
            }
        }
    }

    private func handleCaptureError(_ error: Error) {
        if CaptureAuthorizationFailure.isAuthorizationDenial(error) {
            // ScreenCaptureKit can present an additional system authorization sheet.
            // A modal Point alert here would cover that sheet and prevent the user
            // from responding, so leave the system UI in front and make retry explicit.
            captureItem.title = "Capture Region (choose Allow, then retry)"
            statusItem.button?.title = ""
            statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.shield", accessibilityDescription: "Capture permission required")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.showNormalStatusIcon()
            }
            isOnboardingCapture = false
            setupItem.isHidden = false
            // Update behind the macOS authorization sheet without activating a
            // Point modal. The user can explicitly resume from the menu bar.
            onboardingProgress.advance(to: .screenAccess)
            onboarding.model.page = .settings
            onboarding.model.message = "Respond to the macOS permission prompt, then choose Finish Setup from the Point menu."
            return
        }
        if isOnboardingCapture {
            isOnboardingCapture = false
            showSetup()
            onboarding.model.message = "Couldn’t take a screenshot: \(error.localizedDescription)"
            return
        }
        showError(title: "Capture failed", message: error.localizedDescription)
    }

    private func presentSelectionOverlays(for snapshots: [DisplaySnapshot]) {
        let controller = DisplayOverlayController(snapshots: snapshots)
        controller.onSelection = { [weak self] snapshot, selectionInPoints in
            guard let self else { return }
            overlayController?.dismiss()
            overlayController = nil

            do {
                let croppedImage = try captureService.crop(snapshot: snapshot, selectionInPoints: selectionInPoints)
                let canvasFrame = CGRect(
                    x: snapshot.screenFrame.minX + selectionInPoints.minX,
                    y: snapshot.screenFrame.minY + selectionInPoints.minY,
                    width: selectionInPoints.width,
                    height: selectionInPoints.height
                )
                presentAnnotationCanvas(
                    image: croppedImage,
                    wallpaperImage: snapshot.wallpaperImage,
                    frame: canvasFrame
                )
            } catch {
                handleCaptureError(error)
            }
        }
        controller.onCancel = { [weak self] in
            self?.overlayController?.dismiss()
            self?.overlayController = nil
            self?.restorePreviousApplication()
            self?.resumeSetupAfterCancelledCapture()
        }
        overlayController = controller
        controller.present()
    }

    private func presentAnnotationCanvas(image: CGImage, wallpaperImage: CGImage?, frame: CGRect) {
        let controller = AnnotationCanvasController(
            sourceImage: image,
            wallpaperImage: wallpaperImage,
            canvasFrame: frame
        )
        controller.onCopy = { [weak self] renderedImage in
            guard let self else { return }
            do {
                try ClipboardWriter.writePNG(renderedImage)
                annotationController?.dismiss()
                annotationController = nil
                showSuccessStatus(text: "Copied to clipboard")
                showPreview(image: renderedImage, near: frame)
                restorePreviousApplication()
                finishSetupAfterCapture()
            } catch {
                showError(title: "Couldn’t copy capture", message: error.localizedDescription)
            }
        }
        controller.onSave = { [weak self] renderedImage in
            self?.savePNG(renderedImage, near: frame)
        }
        controller.onCancel = { [weak self] in
            self?.annotationController?.dismiss()
            self?.annotationController = nil
            self?.restorePreviousApplication()
            self?.resumeSetupAfterCancelledCapture()
        }
        controller.onError = { [weak self] error in
            self?.showError(title: "Couldn’t render capture", message: error.localizedDescription)
        }
        controller.onSettings = { [weak self] in
            self?.preferencesController.show(level: .screenSaver)
        }
        annotationController = controller
        controller.present()
    }

    private func finishSetupAfterCapture() {
        guard isOnboardingCapture else { return }
        isOnboardingCapture = false
        onboardingProgress.advance(to: .complete)
        setupItem.isHidden = true
    }

    private func resumeSetupAfterCancelledCapture() {
        guard isOnboardingCapture else { return }
        isOnboardingCapture = false
        showSetup()
    }

    private func restorePreviousApplication() {
        let application = previousApplication
        previousApplication = nil
        guard let application, !application.isTerminated else { return }
        application.activate(options: [])
    }

    private func showPreview(image: CGImage, near frame: CGRect) {
        previewController?.dismiss()
        let controller = CapturePreviewController(image: image, near: frame)
        controller.onSave = { [weak self, weak controller] image in
            guard let self, let controller else { return nil }
            return savePNG(image, near: frame, presenter: controller.presentSaveDialog)
        }
        controller.onDismiss = { [weak self, weak controller] in
            guard self?.previewController === controller else { return }
            self?.previewController = nil
        }
        controller.onError = { [weak self] error in
            self?.showError(title: "Couldn’t drag capture", message: error.localizedDescription)
        }
        previewController = controller
        controller.present()
    }

    @discardableResult
    private func savePNG(_ image: CGImage, near captureFrame: CGRect, presenter: ((NSSavePanel) -> NSApplication.ModalResponse)? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.calendar = Calendar(identifier: .gregorian)
        timestamp.timeZone = .current
        timestamp.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Point-\(timestamp.string(from: Date())).png"
        panel.canCreateDirectories = true
        let response = presenter?(panel) ?? annotationController?.presentSaveDialog(panel) ?? panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        do {
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                throw ClipboardError.pngEncodingFailed
            }
            try data.write(to: url, options: .atomic)
            if presenter == nil {
                showConfirmation(text: "Screenshot saved", near: captureFrame, duration: 2)
                finishSetupAfterCapture()
            }
            return url
        } catch {
            showError(title: "Couldn’t save capture", message: error.localizedDescription)
            return nil
        }
    }

    private func showSuccessStatus(text: String) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: text)
        button.toolTip = text
        button.setAccessibilityLabel(text)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showNormalStatusIcon()
        }
    }

    private func showConfirmation(text: String, near captureFrame: CGRect, duration: TimeInterval = 1.15) {
        showSuccessStatus(text: text)
        confirmationController?.dismiss()
        let confirmation = CaptureConfirmationController(text: text, near: captureFrame, duration: duration)
        confirmation.onDismiss = { [weak self, weak confirmation] in
            guard self?.confirmationController === confirmation else { return }
            self?.confirmationController = nil
        }
        confirmationController = confirmation
        confirmation.present()
    }

    private func showNormalStatusIcon() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Point")
        button.toolTip = "Point"
        button.setAccessibilityLabel("Point")
    }

    @objc private func openScreenRecordingSettings() {
        permissionService.openSystemSettings()
    }

    private func showError(title: String, message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class CaptureConfirmationController {
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private let duration: TimeInterval
    private var dismissWorkItem: DispatchWorkItem?

    init(text: String, near captureFrame: CGRect, duration: TimeInterval) {
        self.duration = duration
        let confirmationView = LiquidGlassStatusView()
        confirmationView.show(text: text, symbol: "checkmark.circle.fill")
        let panelSize = confirmationView.frame.size
        let targetScreen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: captureFrame.midX, y: captureFrame.midY)) }
            ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? captureFrame
        let origin = CGPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: visibleFrame.minY + 52
        )

        panel = NSPanel(
            contentRect: CGRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.contentView = confirmationView
    }

    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel.orderOut(nil)
        onDismiss?()
    }

    private func fadeOut() {
        dismissWorkItem = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                self?.onDismiss?()
            }
        }
    }
}

enum CaptureAuthorizationFailure {
    static func isAuthorizationDenial(_ error: Error) -> Bool {
        let value = (error as NSError)
        let text = "\(value.domain) \(value.localizedDescription) \(value.localizedFailureReason ?? "")".lowercased()
        return text.contains("tcc")
            || text.contains("declined") && text.contains("capture")
            || text.contains("permission") && text.contains("capture")
            || text.contains("not authorized")
    }
}
