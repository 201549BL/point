import AppKit
import SwiftUI

@MainActor
final class OnboardingModel: ObservableObject {
    enum Page {
        case welcome, permission, settings, restart, ready
    }

    @Published var page: Page = .welcome
    @Published var isChecking = false
    @Published var message: String?
    @Published var shortcut: String?
    let progress: OnboardingProgress
    let permission: PermissionService
    var onTryCapture: (() -> Void)?
    var onFinish: (() -> Void)?
    var onLater: (() -> Void)?
    private var verification: Task<Void, Never>?
    private var verificationFailed = false
    private let verifyCapture: () async throws -> Void

    init(
        progress: OnboardingProgress,
        permission: PermissionService,
        verifyCapture: @escaping () async throws -> Void = {
            _ = try await ScreenCaptureService().captureConnectedDisplays()
        }
    ) {
        self.progress = progress
        self.permission = permission
        self.verifyCapture = verifyCapture
        page = progress.step == .welcome ? .welcome : .permission
    }

    func continueSetup() {
        progress.advance(to: .screenAccess)
        page = .permission
        refreshAccess()
    }

    func requestAccess() {
        message = nil
        progress.advance(to: .screenAccess)
        switch permission.requestCaptureAccess() {
        case .allowed:
            refreshAccess(force: true)
        case .restartRequired:
            page = .restart
        case .notGranted:
            page = .settings
        }
    }

    func openSettings() {
        message = nil
        progress.advance(to: .screenAccess)
        page = .settings
        permission.openSystemSettings()
    }

    @discardableResult
    func refreshAccess(force: Bool = false) -> Task<Void, Never>? {
        guard page != .welcome, !isChecking else { return nil }
        guard permission.hasCaptureAccess else {
            verificationFailed = false
            if page == .ready {
                page = .permission
                progress.advance(to: .screenAccess)
            }
            return nil
        }
        guard page != .ready, force || !verificationFailed else { return nil }
        isChecking = true
        message = nil
        verification = Task { [weak self] in
            guard let self else { return }
            defer { isChecking = false }
            do {
                // Verify the same capture path the user will use. Images stay in
                // memory and are discarded; nothing is copied or saved.
                try await verifyCapture()
                guard !Task.isCancelled else { return }
                verificationFailed = false
                progress.advance(to: .ready)
                page = .ready
            } catch {
                guard !Task.isCancelled else { return }
                verificationFailed = true
                page = .settings
                message = CaptureAuthorizationFailure.isAuthorizationDenial(error)
                    ? "macOS hasn’t enabled capture yet. Respond to any macOS prompt, then check again. If Point is already enabled in Settings, quit and reopen it."
                    : "Couldn’t verify screen access: \(error.localizedDescription) Try checking again."
            }
        }
        return verification
    }

    func checkAgain() {
        if permission.hasCaptureAccess {
            refreshAccess(force: true)
        } else {
            message = "Screen access is still unavailable. Enable Point in System Settings. If it’s already on, quit and reopen Point."
        }
    }

    func reopen() {
        progress.advance(to: .screenAccess)
        do {
            try permission.relaunch()
        } catch {
            message = "Couldn’t reopen Point automatically. Quit and reopen it manually to continue setup."
        }
    }

    func finish() {
        guard page == .ready, permission.hasCaptureAccess else {
            page = .permission
            progress.advance(to: .screenAccess)
            return
        }
        progress.advance(to: .complete)
        onFinish?()
    }

}

@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    let model: OnboardingModel
    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init(progress: OnboardingProgress, permission: PermissionService) {
        model = OnboardingModel(progress: progress, permission: permission)
        super.init()
        model.onLater = { [weak self] in self?.hide() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                self.model.refreshAccess()
            }
        }
    }

    func show(shortcut: String?) {
        model.shortcut = shortcut
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: OnboardingView.windowSize),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Welcome to Point"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.refreshAccess()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true, NSApp.isActive else { return }
                self.model.refreshAccess()
            }
        }
    }

    func showPermissionRecovery(shortcut: String?, message: String? = nil) {
        model.progress.advance(to: .screenAccess)
        model.page = .settings
        show(shortcut: shortcut)
        model.message = message
    }

    func hide() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    deinit {
        refreshTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}

private struct OnboardingView: View {
    static let windowSize = CGSize(width: 640, height: 560)

    @ObservedObject var model: OnboardingModel
    @AppStorage(MenuBarItemPreference.defaultsKey) private var showsMenuBarItem = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focusedPage: OnboardingModel.Page?

    private let accent = Color(red: 0.22, green: 0.39, blue: 0.88)
    private var isDark: Bool { colorScheme == .dark }
    private var foreground: Color {
        isDark ? Color(red: 0.93, green: 0.95, blue: 1) : Color(red: 0.10, green: 0.14, blue: 0.24)
    }
    private var muted: Color {
        isDark ? Color(red: 0.68, green: 0.72, blue: 0.80) : Color(red: 0.32, green: 0.37, blue: 0.47)
    }
    private var iconTint: Color { isDark ? Color(red: 0.59, green: 0.71, blue: 1) : accent }
    private var panelColor: Color { isDark ? .white.opacity(0.055) : .white.opacity(0.8) }
    private var borderColor: Color { foreground.opacity(isDark ? 0.12 : 0.09) }

    private var stage: Int {
        switch model.page {
        case .welcome: 1
        case .ready: 3
        default: 2
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ViewThatFits(in: .vertical) {
                    pageContent.fixedSize(horizontal: false, vertical: true)
                    ScrollView { pageContent }
                }
                .frame(maxWidth: 460)
                .id(model.page)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 7)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.page)

            actions
                .frame(height: 72, alignment: .top)
                .disabled(model.isChecking)

            progressIndicator
                .frame(height: 16)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(foreground)
        .tint(accent)
        .padding(.horizontal, 42)
        .padding(.top, 39)
        .padding(.bottom, 16)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background {
            (isDark ? Color(red: 0.075, green: 0.086, blue: 0.12) : Color(red: 0.963, green: 0.971, blue: 0.99))
                .overlay {
                    RadialGradient(colors: [accent.opacity(isDark ? 0.20 : 0.085), .clear],
                                   center: .top, startRadius: 6, endRadius: 400)
                }
                .ignoresSafeArea(edges: .top)
        }
        .task(id: model.page) {
            await Task.yield()
            if !Task.isCancelled { focusedPage = model.page }
        }
    }

    private var pageContent: some View {
        VStack(spacing: 17) {
            switch model.page {
            case .welcome:
                welcome
            case .permission:
                VStack(spacing: 18) {
                    pageIcon("lock.shield")
                    heading("Allow screen access", supporting: "macOS asks for permission before your first capture.")
                    informationPanel {
                        informationRow("Screen Recording", detail: "Point uses this access only for screenshots.",
                                       icon: "display", trailing: "Required")
                    }
                }
            case .settings:
                VStack(spacing: 14) {
                    heading("Turn on screen access", supporting: "In System Settings, go to Privacy & Security.")
                    informationPanel {
                        informationRow("Open recording settings",
                                       detail: "Choose Screen Recording or Screen & System Audio Recording.", icon: "display")
                        Divider().overlay(borderColor)
                        informationRow("Turn on \(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Point")",
                                       detail: "If macOS asks, choose Quit & Reopen.", icon: "switch.2")
                    }
                    HStack(spacing: 16) {
                        secondaryButton("Check Again", action: model.checkAgain)
                        secondaryButton("Already enabled? Quit & Reopen", action: model.reopen)
                    }
                    .disabled(model.isChecking)
                    Text("Point checks your access when you return.")
                        .font(.system(size: 12))
                        .foregroundStyle(muted)
                }
            case .restart:
                VStack(spacing: 18) {
                    pageIcon("arrow.clockwise")
                    heading("Reopen Point to finish", supporting: "Your permission is approved. Point can take screenshots after it reopens.")
                    informationPanel {
                        informationRow("Screen Recording", detail: "Setup will resume automatically.",
                                       icon: "checkmark.circle", trailing: "Allowed")
                    }
                }
            case .ready:
                ready
            }

            if model.isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Checking screen access…")
                }
                .font(.system(size: 13))
                .foregroundStyle(muted)
            }
            if let message = model.message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private var welcome: some View {
        VStack(spacing: 23) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 112, height: 112)
                .shadow(color: accent.opacity(isDark ? 0.32 : 0.16), radius: 20, y: 7)
                .accessibilityHidden(true)
            heading("Capture and annotate", supporting: "Select a region, add an arrow or a note, and copy it.")
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            pageIcon("checkmark")
            heading("You’re ready to Point", supporting: "Select a region, mark it up, then press Return to copy.")
            if let shortcut = model.shortcut {
                informationPanel {
                    informationRow("Capture shortcut", detail: "Use it from any app.", icon: "keyboard", trailing: shortcut)
                }
            } else if showsMenuBarItem {
                informationPanel {
                    informationRow("Capture from the menu bar", detail: "Click the Point icon and choose Capture Region.",
                                   icon: "arrow.up.right")
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 7) {
            switch model.page {
            case .welcome:
                primaryButton("Get Started", action: model.continueSetup)
                secondaryButton("Set Up Later") { model.onLater?() }
            case .permission:
                primaryButton("Allow Screen Access…", action: model.requestAccess)
                secondaryButton("Back") {
                    model.message = nil
                    model.page = .welcome
                    model.progress.advance(to: .welcome)
                }
            case .settings:
                primaryButton("Open System Settings…", action: model.openSettings)
                secondaryButton("Set Up Later") { model.onLater?() }
            case .restart:
                primaryButton("Quit & Reopen", action: model.reopen)
                secondaryButton("Set Up Later") { model.onLater?() }
            case .ready:
                primaryButton("Try a Screenshot") {
                    guard model.permission.hasCaptureAccess else {
                        model.checkAgain()
                        model.page = .permission
                        return
                    }
                    model.onTryCapture?()
                }
                secondaryButton("Done", action: model.finish)
            }
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 5) {
            ForEach(1...3, id: \.self) { step in
                Capsule()
                    .fill(step == stage ? iconTint : foreground.opacity(0.24))
                    .frame(width: step == stage ? 16 : 5, height: 5)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(stage) of 3")
    }

    private func heading(_ title: String, supporting detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .tracking(-1.2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusedPage, equals: model.page)
            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pageIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(iconTint)
            .frame(width: 54, height: 54)
            .background(iconTint.opacity(0.11), in: RoundedRectangle(cornerRadius: 15))
            .accessibilityHidden(true)
    }

    private func informationPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: 410)
            .background(panelColor, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(borderColor) }
    }

    private func informationRow(_ title: String, detail: String, icon: String, trailing: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 34, height: 34)
                .background(iconTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(iconTint.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize()
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
            .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(muted)
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minWidth: 184, minHeight: 38)
            .background(accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .opacity(isEnabled ? 1 : 0.45)
    }
}
