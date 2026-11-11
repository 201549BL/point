import AppKit
import XCTest
@testable import Point

final class SettingsPreviewTests: XCTestCase {
    private let preferenceKeys = [
        "settingsSelectedPane", "captureBackground", "usesDesktopBackdrop", "backdropMargin",
        "annotationColorRed", "annotationColorGreen", "annotationColorBlue",
        "annotationLineWidth", "annotationFontSize", "borderColorRed", "borderColorGreen",
        "borderColorBlue", "shortcutChoice", TrackpadShortcutPreference.defaultsKey,
        SunsetWashPalette.defaultsKey, SunsetWashStrength.defaultsKey,
    ]

    @MainActor
    func testOpeningPreviewsKeepsTheActualEditorStatic() throws {
        try withSettings { _, content in
            for pane in ["appearance", "annotations"] {
                try selectPane(pane, in: content)
                let preview = try find(SettingsPreviewView.self, "settings.preview.\(pane)", in: content)
                XCTAssertFalse(preview.isAnimating)
                XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
                XCTAssertTrue(descendants(preview).contains { $0 is AnnotationFrameView })
                XCTAssertTrue(descendants(preview).contains { $0 is AnnotationCanvasView })
                XCTAssertTrue(descendants(preview).compactMap { $0 as? NSButton }.isEmpty,
                              "The preview should not have capture playback controls")
                let settled = try renderedPixels(preview)
                RunLoop.current.run(until: Date().addingTimeInterval(0.12))
                XCTAssertFalse(preview.isAnimating)
                XCTAssertEqual(try renderedPixels(preview), settled,
                               "Opening a settings pane should not animate the screenshot")
            }
        }
    }

    @MainActor
    func testBackdropAnimatesOnAndOffWithoutMovingTheScreenshotOrChangingUserState() throws {
        try withSettings { window, content in
            try selectPane("appearance", in: content)
            let preview = try find(SettingsPreviewView.self, "settings.preview.appearance", in: content)
            let backdrop = try find(NSSwitch.self, "settings.backdrop", in: content)
            let focus = NSTextView(frame: .zero)
            content.addSubview(focus)
            XCTAssertTrue(window.makeFirstResponder(focus))
            let preferences = unrelatedPreferences()
            let clipboardChangeCount = NSPasteboard.general.changeCount
            let visibleWindows = NSApplication.shared.windows.filter(\.isVisible).map(\.windowNumber).sorted()
            let originalCanvas = try canvasRect(in: preview)

            for enabled in [true, false] {
                let previousImage = try renderedPixels(preview)
                backdrop.state = enabled ? .on : .off
                try sendAction(backdrop)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    XCTAssertFalse(preview.isAnimating)
                } else {
                    XCTAssertTrue(preview.isAnimating)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.06))
                    try assertCanvas(in: preview, matches: originalCanvas)
                    XCTAssertTrue(waitUntil(timeout: 2) { !preview.isAnimating },
                                  "The backdrop animation should finish")
                }
                preview.layoutSubtreeIfNeeded()
                let frame = try XCTUnwrap(descendants(preview).compactMap { $0 as? AnnotationFrameView }.first)
                XCTAssertEqual(frame.padding, enabled ? 48 : AnnotationFrameView.borderWidth, accuracy: 0.001)
                XCTAssertEqual(frame.wallpaperOpacity, enabled ? 1 : 0, accuracy: 0.001)
                try assertCanvas(in: preview, matches: originalCanvas)
                XCTAssertNotEqual(try renderedPixels(preview), previousImage)
            }

            XCTAssertTrue(window.firstResponder === focus, "The preview must not take keyboard focus")
            XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount,
                           "The preview must not copy a screenshot to the clipboard")
            XCTAssertEqual(unrelatedPreferences(), preferences)
            XCTAssertEqual(NSApplication.shared.windows.filter(\.isVisible).map(\.windowNumber).sorted(), visibleWindows,
                           "The preview must stay inside the settings window")
        }
    }

    @MainActor
    func testBackdropToggleRetargetsAnimationButMarginChangesSettleImmediately() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Reduce Motion settles the backdrop immediately")
        }
        try withSettings { _, content in
            try selectPane("appearance", in: content)
            let preview = try find(SettingsPreviewView.self, "settings.preview.appearance", in: content)
            let backdrop = try find(NSSwitch.self, "settings.backdrop", in: content)
            backdrop.state = .on
            try sendAction(backdrop)
            XCTAssertTrue(preview.isAnimating)
            RunLoop.current.run(until: Date().addingTimeInterval(0.06))
            backdrop.state = .off
            try sendAction(backdrop)
            XCTAssertTrue(preview.isAnimating, "Reversing the backdrop should retarget the current animation")

            backdrop.state = .on
            try sendAction(backdrop)
            XCTAssertTrue(preview.isAnimating)
            let margin = try find(NSSlider.self, "settings.backdropMargin", in: content)
            margin.doubleValue = 64
            try sendAction(margin)
            XCTAssertFalse(preview.isAnimating, "Margin changes should match the editor's immediate layout")
            let frame = try XCTUnwrap(descendants(preview).compactMap { $0 as? AnnotationFrameView }.first)
            XCTAssertEqual(frame.padding, 64)
            XCTAssertEqual(preview.accessibilityLabel(), "Capture preview. Background on, 64 point margin.")
        }
    }

    @MainActor
    func testBackdropAnimationStopsWhenItsPaneIsHiddenOrSettingsCloses() throws {
        try withSettings { window, content in
            try selectPane("appearance", in: content)
            let appearance = try find(SettingsPreviewView.self, "settings.preview.appearance", in: content)
            let backdrop = try find(NSSwitch.self, "settings.backdrop", in: content)
            backdrop.state = .on
            try sendAction(backdrop)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertTrue(appearance.isAnimating) }

            try selectPane("annotations", in: content)
            XCTAssertFalse(appearance.isAnimating)
            let annotations = try find(SettingsPreviewView.self, "settings.preview.annotations", in: content)
            XCTAssertFalse(annotations.isAnimating)

            try selectPane("appearance", in: content)
            backdrop.state = .off
            try sendAction(backdrop)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertTrue(appearance.isAnimating) }
            window.close()
            XCTAssertFalse(appearance.isAnimating)
            XCTAssertFalse(annotations.isAnimating)
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            XCTAssertFalse(appearance.isAnimating, "Closing Settings must cancel pending animation work")
        }
    }

    @MainActor
    func testOverlayHoverReversesSmoothlyAndResetsWhenHiddenOrClosed() throws {
        try withSettings { window, content in
            try selectPane("appearance", in: content)
            let preview = try find(SettingsPreviewView.self, "settings.preview.appearance", in: content)
            let overlayOptions = try find(NSView.self, "settings.overlayOptions", in: content)
            let capturePixels = try renderedPixels(preview)
            let preferences = snapshotPreferences()

            try sendHover(true, to: overlayOptions, in: window)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertFalse(preview.isAnimating)
            } else {
                XCTAssertTrue(preview.isTransitioning)
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
                let fadingSelection = try XCTUnwrap(descendants(preview).compactMap { $0 as? SelectionView }.first)
                XCTAssertGreaterThan(fadingSelection.alphaValue, 0)
                XCTAssertLessThan(fadingSelection.alphaValue, 1,
                                 "The real selection view should fade in rather than appear immediately")
            }
            try sendHover(false, to: overlayOptions, in: window)
            try sendHover(true, to: overlayOptions, in: window)
            XCTAssertTrue(waitUntil(timeout: 2) { !preview.isAnimating })
            let selection = try XCTUnwrap(descendants(preview).compactMap { $0 as? SelectionView }.first)
            XCTAssertFalse(selection.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(preview.accessibilityLabel()?.hasPrefix("Selection overlay preview.") == true)
            XCTAssertNotEqual(try renderedPixels(preview), capturePixels)

            try sendHover(false, to: overlayOptions, in: window)
            XCTAssertTrue(waitUntil(timeout: 2) { !preview.isAnimating })
            XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
            XCTAssertEqual(try renderedPixels(preview), capturePixels,
                           "The latest exit should restore the real screenshot after rapid hover changes")

            try sendHover(true, to: overlayOptions, in: window)
            try selectPane("annotations", in: content)
            XCTAssertFalse(preview.isAnimating)
            XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
            try selectPane("appearance", in: content)
            XCTAssertFalse(preview.isAnimating)
            XCTAssertEqual(try renderedPixels(preview), capturePixels,
                           "Reopening the pane should not retain an old hover state")

            try sendHover(true, to: overlayOptions, in: window)
            window.close()
            XCTAssertFalse(preview.isAnimating)
            XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            XCTAssertFalse(preview.isAnimating, "Closing Settings must cancel pending hover work")
            XCTAssertEqual(snapshotPreferences(), preferences, "Hovering must not change saved preferences")
        }
    }

    @MainActor
    private func withSettings(_ body: (NSWindow, NSView) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let previous = snapshotPreferences()
        defer {
            for key in preferenceKeys {
                if let value = previous[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        preferenceKeys.forEach { defaults.removeObject(forKey: $0) }
        CaptureBackground.aurora.remember()
        defaults.set(false, forKey: "usesDesktopBackdrop")
        SettingsTestApplication.prepare()
        let controller = PreferencesController()
        controller.show()
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == "point.settings" && $0.isVisible
        })
        defer { window.close() }
        window.setFrameOrigin(CGPoint(x: NSEvent.mouseLocation.x + 40, y: window.frame.minY))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        try body(window, content)
    }

    @MainActor
    private func snapshotPreferences() -> [String: NSObject] {
        Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            (UserDefaults.standard.object(forKey: key) as? NSObject).map { (key, $0) }
        })
    }

    @MainActor
    private func unrelatedPreferences() -> [String: NSObject] {
        snapshotPreferences().filter { !["usesDesktopBackdrop", "backdropMargin"].contains($0.key) }
    }

    @MainActor
    private func selectPane(_ name: String, in content: NSView) throws {
        let button = try find(NSButton.self, "settings.pane.\(name)", in: content)
        try sendAction(button)
        content.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func sendAction(_ control: NSControl) throws {
        XCTAssertTrue(control.sendAction(try XCTUnwrap(control.action), to: control.target))
    }

    @MainActor
    private func sendHover(_ entered: Bool, to view: NSView, in window: NSWindow) throws {
        SettingsTestApplication.makeKey(window)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(
            with: entered ? .mouseEntered : .mouseExited, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil
        ))
        if entered { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    @MainActor
    private func canvasRect(in preview: NSView) throws -> CGRect {
        preview.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(descendants(preview).compactMap { $0 as? AnnotationCanvasView }.first)
        return canvas.convert(canvas.bounds, to: preview)
    }

    @MainActor
    private func assertCanvas(in preview: NSView, matches expected: CGRect) throws {
        let actual = try canvasRect(in: preview)
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
    }

    @MainActor
    private func renderedPixels(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        view.display()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        let count = bitmap.bytesPerRow * bitmap.pixelsHigh
        pixels.update(repeating: 0, count: count)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return Data(bytes: pixels, count: count)
    }

    @MainActor
    private func find<T: NSView>(_ type: T.Type, _ identifier: String, in view: NSView) throws -> T {
        try XCTUnwrap(([view] + descendants(view)).first { $0.identifier?.rawValue == identifier } as? T)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
