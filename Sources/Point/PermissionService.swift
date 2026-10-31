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
    private var needsRelaunch = false

    init() {
        UserDefaults.standard.removeObject(forKey: "screenCapturePermissionRelaunchPending")
    }

    func ensureCapturePermission() -> Bool {
        let hasAccess = CGPreflightScreenCaptureAccess()
        if hasAccess {
            needsRelaunch = false
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
                needsRelaunch = true
                showRelaunchAlert()
                return false
            }
            if !hasRequestedBefore {
                return false
            }
        }

        if needsRelaunch {
            showRelaunchAlert()
            return false
        }
        showRecoveryAlert()
        return false
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while /bin/kill -0 \"$2\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$1\"",
            "point-permission-relaunch",
            bundlePath,
            String(ProcessInfo.processInfo.processIdentifier),
        ]
        do {
            try helper.run()
            NSApplication.shared.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t relaunch Point"
            alert.informativeText = "Quit and reopen Point manually to finish enabling Screen Recording."
            alert.runModal()
        }
    }

    private func showRecoveryAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording is off"
        alert.informativeText = "Enable Point in System Settings › Privacy & Security › Screen & System Audio Recording. After changing permission, quit and reopen Point. If it is already enabled but captures still fail after a local rebuild, see README’s Screen Recording recovery instructions."
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
            relaunch()
        } else {
            needsRelaunch = false
        }
    }
}
