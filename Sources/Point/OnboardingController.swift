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
                contentRect: NSRect(x: 0, y: 0, width: 666, height: 490),
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
    @ObservedObject var model: OnboardingModel
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.68, green: 0.61, blue: 0.95)
            : Color(red: 0.42, green: 0.34, blue: 0.78)
    }

    private var stage: Int {
        switch model.page {
        case .welcome: 0
        case .ready: 2
        default: 1
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                HStack {
                    Text("Welcome to Point").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 28).frame(height: 50)
                content
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 666, height: 490)
        .tint(accent)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().frame(width: 34, height: 34)
                Text("Point").font(.system(size: 17, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.top, 55).padding(.bottom, 28)
            Text("Get started").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(Array([("Welcome", "sparkles"), ("Screen Access", "display"), ("Try Point", "cursorarrow")].enumerated()), id: \.offset) { index, item in
                HStack(spacing: 9) {
                    Image(systemName: stage > index ? "checkmark.circle.fill" : item.1)
                        .foregroundStyle(stage > index ? Color.green : .secondary).frame(width: 17)
                    Text(item.0)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12, weight: stage == index ? .medium : .regular))
                .padding(.horizontal, 10).padding(.vertical, 9)
                .background(stage == index ? accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(.bottom, 4)
                .accessibilityAddTraits(stage == index ? .isSelected : [])
            }
            Spacer()
            Label("Only on your Mac", systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 20)
        }
        .padding(.horizontal, 12).frame(width: 166)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Divider() }
    }

    private var content: some View {
        VStack(spacing: 12) {
            switch model.page {
            case .welcome:
                captureIllustration
                heading("Make your point.")
                detail("Capture a region. Add an arrow or a note.\nCopy it, and keep the conversation moving.")
                Spacer(minLength: 0)
                note("A quick setup, then you’re ready.")
            case .permission:
                symbol("display")
                heading("Allow screen access")
                detail("Point needs permission to take screenshots.\nmacOS calls this Screen Recording.")
                permissionStatus(approved: false)
                Spacer(minLength: 0)
                note("If macOS asks, choose Quit & Reopen. Setup will continue automatically.")
            case .settings:
                symbol("gearshape")
                heading("Turn on Point")
                VStack(alignment: .leading, spacing: 10) {
                    instruction(1, "Open screen recording settings under Privacy & Security.")
                    instruction(2, "Turn on \(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Point") in the list.")
                    instruction(3, "Choose Quit & Reopen if macOS asks. Setup resumes when Point reopens.")
                }
                Button("Check Again", action: model.checkAgain)
                Spacer(minLength: 0)
                Button("Already enabled? Quit & Reopen", action: model.reopen)
                    .buttonStyle(.link).font(.system(size: 11))
                note("Point checks screen access when you return.")
            case .restart:
                symbol("arrow.clockwise")
                heading("Reopen Point to finish")
                detail("Permission is approved. Point needs to reopen before it can take screenshots.")
                permissionStatus(approved: true)
                Spacer(minLength: 0)
                note("Your progress is saved. We’ll meet you right back here.")
            case .ready:
                HStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                }
                .foregroundStyle(.secondary).padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Find Point’s arrow icon in your menu bar")
                heading("You’re ready to Point.")
                detail(model.shortcut == nil ? "Point lives in your menu bar.\nChoose Capture Region to take a screenshot." : "Point lives in your menu bar.\nStart a screenshot with:")
                if let shortcut = model.shortcut {
                    Text(shortcut).font(.system(size: 25, weight: .medium, design: .rounded))
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        .accessibilityLabel("Capture shortcut: \(shortcut)")
                }
                Label("Screen access is working", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(.green)
                Spacer(minLength: 0)
                note("Select a region, annotate, then press Return to copy.")
            }
            if model.isChecking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Checking screen access…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }
        }
        .multilineTextAlignment(.center).padding(.top, 8).padding(.bottom, 22)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                switch model.page {
                case .welcome:
                    Button("Set Up Later") { model.onLater?() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    primary("Continue", action: model.continueSetup)
                case .permission:
                    Button("Back") { model.page = .welcome; model.progress.advance(to: .welcome) }
                    Spacer()
                    primary("Allow Screen Access…", action: model.requestAccess)
                case .settings:
                    Button("Set Up Later") { model.onLater?() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    primary("Open System Settings…", action: model.openSettings)
                case .restart:
                    Button("Later") { model.onLater?() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    primary("Quit & Reopen", action: model.reopen)
                case .ready:
                    Button("Done", action: model.finish)
                    Spacer()
                    primary("Try a Screenshot") {
                        guard model.permission.hasCaptureAccess else { model.checkAgain(); model.page = .permission; return }
                        model.onTryCapture?()
                    }
                }
            }
            .controlSize(.regular).padding(.horizontal, 22).frame(height: 64)
            .disabled(model.isChecking)
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 25, weight: .semibold)).tracking(-0.7).padding(.top, 3)
    }

    private func detail(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 30, weight: .light)).foregroundStyle(accent)
            .frame(width: 64, height: 64)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }

    private func permissionStatus(approved: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 20)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording").font(.system(size: 12, weight: .medium))
                    Text(approved ? "Approved in macOS" : "Required to take screenshots")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(approved ? "Allowed" : "Not allowed").font(.system(size: 11))
                    .foregroundStyle(approved ? Color.green : .secondary)
            }.padding(13)
            Divider()
            Text("Point takes screenshots. It doesn’t capture audio.")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
        .padding(.top, 3)
    }

    private var captureIllustration: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0..<3) { _ in Circle().fill(.quaternary).frame(width: 5, height: 5) }
                    Text("Design review").font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 10)
                    Spacer()
                }.padding(10)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 140, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 95, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 140, height: 5)
                }.padding(18)
                Spacer()
            }
            .frame(width: 232, height: 126)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(accent, lineWidth: 1).padding(12))
            .shadow(color: .black.opacity(0.07), radius: 9, y: 5).rotationEffect(.degrees(-4))
            Image(systemName: "arrow.up.right").font(.system(size: 49, weight: .bold))
                .foregroundStyle(accent).offset(x: 45, y: -5)
            Text("A little more space here").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .foregroundStyle(.white).background(accent, in: RoundedRectangle(cornerRadius: 5))
                .rotationEffect(.degrees(3)).offset(x: 65, y: 48)
        }
        .frame(height: 151).frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A selected screenshot with an arrow and caption")
    }
}
