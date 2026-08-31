import AppKit
import CoreGraphics

enum ScreenCapturePermissionRequestPolicy {
    static func shouldRequest(hasAccess: Bool, hasRequestedBefore: Bool) -> Bool {
        // Point's UserDefaults survive `tccutil reset`, while the corresponding
        // TCC record does not. The live system state must therefore win over the
        // remembered request state whenever access is absent.
        !hasAccess
    }
}

@MainActor
final class PermissionService {
    private let hasRequestedKey = "hasRequestedScreenCapturePermission"
    private let relaunchPendingKey = "screenCapturePermissionRelaunchPending"

    func ensureCapturePermission() -> Bool {
        let hasAccess = CGPreflightScreenCaptureAccess()
        if hasAccess {
            UserDefaults.standard.removeObject(forKey: relaunchPendingKey)
            return true
        }

        let hasRequestedBefore = UserDefaults.standard.bool(forKey: hasRequestedKey)

        // The capture command itself supplies the context for macOS's permission
        // prompt. Do not stack a Point-owned modal in front of the system UI.
        if ScreenCapturePermissionRequestPolicy.shouldRequest(
            hasAccess: hasAccess,
            hasRequestedBefore: hasRequestedBefore
        ) {
            UserDefaults.standard.set(true, forKey: hasRequestedKey)
            NSApplication.shared.activate(ignoringOtherApps: true)

            let granted = CGRequestScreenCaptureAccess()
            if granted, CGPreflightScreenCaptureAccess() {
                return true
            }
            if granted {
                UserDefaults.standard.set(true, forKey: relaunchPendingKey)
                showRelaunchAlert()
                return false
            }
            if !hasRequestedBefore {
                return false
            }
        }

        if UserDefaults.standard.bool(forKey: relaunchPendingKey) {
            showRelaunchAlert()
            return false
        }
        showRecoveryAlert()
        return false
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        if NSWorkspace.shared.open(url) {
            // When macOS terminates the app after the permission switch changes,
            // AppDelegate uses this marker to launch the same build again.
            UserDefaults.standard.set(true, forKey: relaunchPendingKey)
        }
    }

    func scheduleRelaunchAfterTerminationIfNeeded() {
        guard UserDefaults.standard.bool(forKey: relaunchPendingKey) else { return }

        // Consume this before launching the helper so an unsuccessful permission
        // change can never trap the user in a quit/relaunch loop.
        UserDefaults.standard.removeObject(forKey: relaunchPendingKey)

        let bundlePath = Bundle.main.bundleURL.path
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"$1\"",
            "point-permission-relaunch",
            bundlePath,
        ]
        try? helper.run()
    }

    private func showRecoveryAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording is off"
        alert.informativeText = "Enable Point in System Settings › Privacy & Security › Screen & System Audio Recording. If macOS quits Point, it will reopen automatically."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    private func showRelaunchAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Relaunch Point to finish setup"
        alert.informativeText = "macOS granted capture access. Point can quit and reopen itself now."
        alert.addButton(withTitle: "Quit & Reopen")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApplication.shared.terminate(nil)
        } else {
            UserDefaults.standard.removeObject(forKey: relaunchPendingKey)
        }
    }
}
