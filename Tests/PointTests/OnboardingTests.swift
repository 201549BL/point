import AppKit
import XCTest
@testable import Point

final class OnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "PointOnboardingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testFirstInstallStartsAtWelcomeAndExistingAuthorizedInstallSkipsTour() {
        XCTAssertEqual(OnboardingProgress(defaults: defaults, hasCaptureAccess: false).step, .welcome)
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(OnboardingProgress(defaults: defaults, hasCaptureAccess: true).isComplete)
    }

    func testRestartPreservesIncompleteSetupEvenAfterAccessIsGranted() {
        let progress = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
        progress.advance(to: .screenAccess)
        let relaunched = OnboardingProgress(defaults: defaults, hasCaptureAccess: true)
        XCTAssertEqual(relaunched.step, .screenAccess)
        XCTAssertFalse(relaunched.isComplete)
    }

    func testRevokedPermissionInvalidatesSavedReadyAndCompleteStates() {
        let progress = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
        for step in [OnboardingProgress.Step.ready, .complete] {
            progress.advance(to: step)
            let relaunched = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
            XCTAssertEqual(relaunched.step, .screenAccess)
        }
    }

    @MainActor
    func testPermissionPromptOnlyFollowsExplicitRequestAndCanBeRetriedAfterDenial() {
        var hasAccess = false
        var requests = 0
        let permission = PermissionService(defaults: defaults, preflight: { hasAccess }, request: {
            requests += 1
            return false
        })
        let model = OnboardingModel(
            progress: OnboardingProgress(defaults: defaults, hasCaptureAccess: false),
            permission: permission
        )
        model.continueSetup()
        model.refreshAccess()
        XCTAssertEqual(requests, 0)
        model.requestAccess()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.page, .settings)
        model.requestAccess()
        XCTAssertEqual(requests, 2)
        XCTAssertFalse(model.progress.isComplete)
        hasAccess = true
        XCTAssertEqual(permission.requestCaptureAccess(), .allowed)
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testApprovalThatNeedsRestartSavesResumableProgressWithoutCompletingSetup() {
        let permission = PermissionService(defaults: defaults, preflight: { false }, request: { true })
        let model = OnboardingModel(
            progress: OnboardingProgress(defaults: defaults, hasCaptureAccess: false), permission: permission
        )
        model.requestAccess()
        XCTAssertEqual(model.page, .restart)
        XCTAssertEqual(model.progress.step, .screenAccess)
        XCTAssertNil(defaults.object(forKey: "screenCapturePermissionRelaunchPending"))
        let restarted = OnboardingModel(
            progress: OnboardingProgress(defaults: defaults, hasCaptureAccess: false), permission: permission
        )
        XCTAssertEqual(restarted.page, .permission)
        XCTAssertFalse(restarted.progress.isComplete)
    }

    @MainActor
    func testRestartRechecksActualCaptureBeforeShowingReady() async {
        let progress = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
        progress.advance(to: .screenAccess)
        let permission = PermissionService(defaults: defaults, preflight: { true }, request: { XCTFail(); return false })
        var captures = 0
        let model = OnboardingModel(progress: progress, permission: permission, verifyCapture: { captures += 1 })
        XCTAssertEqual(model.page, .permission)
        await model.refreshAccess()?.value
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(model.page, .ready)
        XCTAssertFalse(progress.isComplete)
        model.finish()
        XCTAssertTrue(progress.isComplete)
        XCTAssertTrue(OnboardingProgress(defaults: defaults, hasCaptureAccess: true).isComplete)
    }

    @MainActor
    func testSettingsHandoffWaitsForExplicitPointRestartAndResumesAfterward() async {
        var restarts = 0
        let permission = PermissionService(defaults: defaults, preflight: { false }, request: { false }, relaunch: {
            XCTAssertEqual(self.defaults.string(forKey: "onboardingStepV1"), "screenAccess")
            restarts += 1
        })
        let model = OnboardingModel(
            progress: OnboardingProgress(defaults: defaults, hasCaptureAccess: false), permission: permission
        )
        model.continueSetup()
        model.requestAccess()
        XCTAssertEqual(model.page, .settings)
        model.refreshAccess()
        XCTAssertEqual(restarts, 0)
        model.reopen()
        XCTAssertEqual(restarts, 1)
        XCTAssertFalse(model.progress.isComplete)

        let reopened = OnboardingModel(
            progress: OnboardingProgress(defaults: defaults, hasCaptureAccess: true),
            permission: PermissionService(defaults: defaults, preflight: { true }, request: { XCTFail(); return false }),
            verifyCapture: {}
        )
        await reopened.refreshAccess()?.value
        XCTAssertEqual(reopened.page, .ready)
        XCTAssertFalse(reopened.progress.isComplete)
        XCTAssertEqual(restarts, 1)
    }

    @MainActor
    func testFailedVerificationDoesNotLoopPromptsAndAllowsExplicitRetry() async {
        let progress = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
        progress.advance(to: .screenAccess)
        let permission = PermissionService(defaults: defaults, preflight: { true }, request: { false })
        var captures = 0
        let model = OnboardingModel(progress: progress, permission: permission, verifyCapture: {
            captures += 1
            throw NSError(domain: "com.apple.ScreenCaptureKit", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "The user declined capture permission",
            ])
        })
        await model.refreshAccess()?.value
        XCTAssertEqual(model.page, .settings)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(progress.isComplete)
        XCTAssertNil(model.refreshAccess())
        XCTAssertEqual(captures, 1)
        await model.refreshAccess(force: true)?.value
        XCTAssertEqual(captures, 2)
        XCTAssertFalse(model.isChecking)
    }

    @MainActor
    func testRevocationWhileReadyPreventsCompletion() async {
        var hasAccess = true
        let progress = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
        progress.advance(to: .screenAccess)
        let permission = PermissionService(defaults: defaults, preflight: { hasAccess }, request: { false })
        let model = OnboardingModel(progress: progress, permission: permission, verifyCapture: {})
        await model.refreshAccess()?.value
        XCTAssertEqual(model.page, .ready)
        hasAccess = false
        model.finish()
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(model.page, .permission)
    }

    @MainActor
    func testNativeSetupWindowCanCloseAndResumeWithoutCompletingSetup() throws {
        _ = NSApplication.shared
        let progress = OnboardingProgress(defaults: defaults, hasCaptureAccess: false)
        let permission = PermissionService(defaults: defaults, preflight: { false }, request: { XCTFail(); return false })
        let controller = OnboardingController(progress: progress, permission: permission)
        controller.show(shortcut: "⌃⇧2")
        defer { controller.hide() }
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Welcome to Point" && $0.isVisible })
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        controller.model.continueSetup()
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(progress.step, .screenAccess)
        XCTAssertFalse(progress.isComplete)
        controller.show(shortcut: "⌃⇧2")
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(controller.model.page, .permission)

        // Opt-in renders use only this test window, never screen capture or TCC.
        if let destination = ProcessInfo.processInfo.environment["POINT_ONBOARDING_PREVIEWS"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let view = try XCTUnwrap(window.contentView)
            for (name, page) in [("welcome", OnboardingModel.Page.welcome), ("permission", .permission), ("settings", .settings), ("restart", .restart), ("ready", .ready)] {
                controller.model.page = page
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name).png"))
            }
            controller.model.page = .settings
            controller.model.message = "macOS hasn’t enabled capture yet. Respond to any macOS prompt, then check again. If Point is already enabled in Settings, quit and reopen it."
            for (name, appearance) in [("settings-error", NSAppearance.Name.aqua), ("settings-dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
    }
}
