import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppCoordinator {
    private let captureService = ScreenCaptureService()
    private let permissionService = PermissionService()
    private let shortcutService = ShortcutService()
    private let trackpadShortcutService = TrackpadShortcutService()
    private let preferencesController = PreferencesController()
    private var overlayController: DisplayOverlayController?
    private var annotationController: AnnotationCanvasController?
    private var copiedConfirmationController: CopiedConfirmationController?
    private var captureTask: Task<Void, Never>?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var captureItem = NSMenuItem(
        title: "Capture Region",
        action: #selector(beginCaptureFromMenu),
        keyEquivalent: ""
    )
    private lazy var shortcutInfoItem = NSMenuItem(title: "Shortcut: \(ShortcutChoice.preferred.title)", action: nil, keyEquivalent: "")

    func start() {
        showNormalStatusIcon()

        let menu = NSMenu()
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(shortcutInfoItem)
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
            showError(
                title: "Shortcut unavailable",
                message: "\(ShortcutChoice.preferred.title) is already registered by another app. You can still capture from the Point menu."
            )
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
    }

    func prepareForTermination() {
        permissionService.scheduleRelaunchAfterTerminationIfNeeded()
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

        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }

            guard permissionService.ensureCapturePermission() else { return }

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
                showError(title: "Couldn’t prepare capture", message: error.localizedDescription)
            }
        }
        controller.onCancel = { [weak self] in
            self?.overlayController?.dismiss()
            self?.overlayController = nil
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
                showCopiedConfirmation(near: frame)
            } catch {
                showError(title: "Couldn’t copy capture", message: error.localizedDescription)
            }
        }
        controller.onSave = { [weak self] renderedImage in
            self?.savePNG(renderedImage)
        }
        controller.onCancel = { [weak self] in
            self?.annotationController?.dismiss()
            self?.annotationController = nil
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

    private func savePNG(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Point Capture.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                throw ClipboardError.pngEncodingFailed
            }
            try data.write(to: url, options: .atomic)
        } catch {
            showError(title: "Couldn’t save capture", message: error.localizedDescription)
        }
    }

    private func showCopiedConfirmation(near captureFrame: CGRect) {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")

        copiedConfirmationController?.dismiss()
        let confirmation = CopiedConfirmationController(near: captureFrame)
        confirmation.onDismiss = { [weak self, weak confirmation] in
            guard self?.copiedConfirmationController === confirmation else { return }
            self?.copiedConfirmationController = nil
        }
        copiedConfirmationController = confirmation
        confirmation.present()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showNormalStatusIcon()
        }
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
final class CopiedConfirmationController {
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private var dismissWorkItem: DispatchWorkItem?

    init(near captureFrame: CGRect) {
        let confirmationView = LiquidGlassStatusView()
        confirmationView.show(text: "Copied to clipboard", symbol: "checkmark.circle.fill")
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
        panel.level = .screenSaver
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: workItem)
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
