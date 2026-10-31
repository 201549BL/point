import AppKit
import CoreGraphics

@MainActor
final class PermissionService {
    enum RequestResult {
        case allowed
        case restartRequired
        case notGranted
    }

    private let defaults: UserDefaults
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let relaunchOverride: (() throws -> Void)?

    init(
        defaults: UserDefaults = .standard,
        preflight: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
        request: @escaping () -> Bool = CGRequestScreenCaptureAccess,
        relaunch: (() throws -> Void)? = nil
    ) {
        self.defaults = defaults
        self.preflight = preflight
        self.request = request
        relaunchOverride = relaunch
        defaults.removeObject(forKey: "screenCapturePermissionRelaunchPending")
    }

    var hasCaptureAccess: Bool { preflight() }

    func requestCaptureAccess() -> RequestResult {
        // The live state wins even when UserDefaults survive a TCC reset.
        if hasCaptureAccess { return .allowed }
        let granted = request()
        if hasCaptureAccess { return .allowed }
        return granted ? .restartRequired : .notGranted
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // Only an explicit user action may launch this helper. No quit observer or
    // persistent marker is allowed to reopen Point during installation.
    func relaunch() throws {
        defaults.synchronize()
        if let relaunchOverride {
            try relaunchOverride()
            return
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$2\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$1\"",
            "point-permission-relaunch",
            Bundle.main.bundleURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        try helper.run()
        NSApplication.shared.terminate(nil)
    }
}
