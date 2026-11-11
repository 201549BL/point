import AppKit
import XCTest
@testable import Point

final class PreferencesTests: XCTestCase {
    private let preferenceKeys = [
        "settingsSelectedPane", "shortcutChoice", TrackpadShortcutPreference.defaultsKey,
        SunsetWashPalette.defaultsKey, SunsetWashStrength.defaultsKey,
        "annotationColorRed", "annotationColorGreen", "annotationColorBlue",
        "annotationLineWidth", "annotationFontSize", "borderColorRed", "borderColorGreen",
        "borderColorBlue", "usesDesktopBackdrop", "backdropMargin", "captureBackground",
    ]

    @MainActor
    func testPanesNavigateAndRestoreTheLastSelection() throws {
        try withSettings { _, window, content in
            let capture = try control(NSButton.self, "settings.pane.capture", in: content)
            let appearance = try control(NSButton.self, "settings.pane.appearance", in: content)
            let annotations = try control(NSButton.self, "settings.pane.annotations", in: content)
            XCTAssertEqual([capture.state, appearance.state, annotations.state], [.on, .off, .off])

            try sendAction(appearance)
            XCTAssertEqual([capture.state, appearance.state, annotations.state], [.off, .on, .off])
            XCTAssertEqual(UserDefaults.standard.string(forKey: "settingsSelectedPane"), "appearance")
            let pane = try control(NSView.self, "settings.content.appearance", in: content)
            XCTAssertFalse(pane.isHidden)

            window.close()
            let reopenedController = PreferencesController()
            reopenedController.show()
            let reopenedWindow = try settingsWindow()
            defer { reopenedWindow.close() }
            let reopenedContent = try XCTUnwrap(reopenedWindow.contentView)
            XCTAssertEqual(try control(NSButton.self, "settings.pane.appearance", in: reopenedContent).state, .on)
            XCTAssertFalse(try control(NSView.self, "settings.content.appearance", in: reopenedContent).isHidden)
        }
    }

    @MainActor
    func testColorMoodRemainsExclusiveAndStrengthSavesImmediately() throws {
        try withSettings { _, window, content in
            try sendAction(control(NSButton.self, "settings.pane.appearance", in: content))
            let appearance = try control(NSView.self, "settings.content.appearance", in: content)
            let capture = try control(NSView.self, "settings.content.capture", in: content)
            let preview = try control(SettingsPreviewView.self, "settings.preview.appearance", in: appearance)
            let focus = NSTextView(frame: .zero)
            content.addSubview(focus)
            XCTAssertTrue(window.makeFirstResponder(focus))
            func unrelatedPreferences() -> [String: NSObject] {
                Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
                    guard ![SunsetWashPalette.defaultsKey, SunsetWashStrength.defaultsKey, "usesDesktopBackdrop", "backdropMargin"].contains(key) else { return nil }
                    return (UserDefaults.standard.object(forKey: key) as? NSObject).map { (key, $0) }
                })
            }
            let preferences = unrelatedPreferences()
            let clipboardChangeCount = NSPasteboard.general.changeCount
            let visibleWindows = NSApplication.shared.windows.filter(\.isVisible).map(\.windowNumber).sorted()
            let paletteButtons = try SunsetWashPalette.allCases.map {
                try control(NSButton.self, "settings.palette.\($0.rawValue)", in: appearance)
            }
            XCTAssertFalse(descendants(capture).contains { $0.identifier?.rawValue.hasPrefix("settings.palette.") == true })
            XCTAssertFalse(descendants(capture).contains { $0.identifier?.rawValue == "settings.overlayStrength" })
            XCTAssertEqual(paletteButtons.map(\.title), ["Sunset", "Lagoon", "Twilight"])
            XCTAssertEqual(paletteButtons.map(\.state), [.on, .off, .off])
            let slider = try control(NSSlider.self, "settings.overlayStrength", in: appearance)
            XCTAssertEqual(slider.minValue, 0)
            XCTAssertEqual(slider.maxValue, 100)
            let capturePixels = try renderedPixels(preview)
            try sendAction(paletteButtons[1])
            slider.doubleValue = 60
            try sendAction(slider)
            XCTAssertEqual(SunsetWashPalette.preferred(), .lagoon)
            XCTAssertEqual(SunsetWashStrength.preferred(), 0.6)
            XCTAssertFalse(preview.isAnimating)
            XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
            XCTAssertEqual(try renderedPixels(preview), capturePixels,
                           "Changing overlay preferences without hovering should keep the screenshot preview")

            let overlayOptions = try control(NSView.self, "settings.overlayOptions", in: appearance)
            try sendHover(true, to: overlayOptions, in: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            XCTAssertFalse(preview.isAnimating)
            let selectedPixels = try renderedPixels(preview)
            XCTAssertNotEqual(selectedPixels, capturePixels)
            let selectedPalette = SunsetWashPalette.preferred()
            let selectedStates = paletteButtons.map(\.state)
            var hoveredImages: [String: Data] = [:]
            for (index, palette) in SunsetWashPalette.allCases.enumerated() {
                try sendHover(true, to: paletteButtons[index], in: window)
                XCTAssertFalse(preview.isAnimating, "Swatch hover should update the existing selection preview immediately")
                XCTAssertEqual(preview.accessibilityLabel(), "Selection overlay preview. \(palette.title), 60% strength.")
                let pixels = try renderedPixels(preview)
                hoveredImages[palette.rawValue] = pixels
                if palette == selectedPalette { XCTAssertEqual(pixels, selectedPixels) }
                else { XCTAssertNotEqual(pixels, selectedPixels) }
                XCTAssertTrue(descendants(preview).contains { $0 is SelectionView })
                XCTAssertEqual(SunsetWashPalette.preferred(), selectedPalette, "Hovering must not save a palette")
                XCTAssertEqual(paletteButtons.map(\.state), selectedStates, "Hovering must not change the checked palette")

                try sendHover(false, to: paletteButtons[index], in: window)
                XCTAssertEqual(try renderedPixels(preview), selectedPixels)
                XCTAssertEqual(preview.accessibilityLabel(), "Selection overlay preview. \(selectedPalette.title), 60% strength.")
                XCTAssertEqual(SunsetWashPalette.preferred(), selectedPalette)
                XCTAssertEqual(paletteButtons.map(\.state), selectedStates)
            }

            try sendHover(true, to: paletteButtons[0], in: window)
            try sendHover(true, to: paletteButtons[2], in: window)
            try sendHover(false, to: paletteButtons[0], in: window)
            XCTAssertEqual(try renderedPixels(preview), try XCTUnwrap(hoveredImages[SunsetWashPalette.twilight.rawValue]),
                           "An old swatch exit must not clear a newer swatch hover")
            XCTAssertEqual(preview.accessibilityLabel(), "Selection overlay preview. Twilight, 60% strength.")
            XCTAssertEqual(SunsetWashPalette.preferred(), selectedPalette)
            XCTAssertEqual(paletteButtons.map(\.state), selectedStates)
            try sendHover(false, to: paletteButtons[2], in: window)
            XCTAssertEqual(try renderedPixels(preview), selectedPixels)

            var previousPixels = selectedPixels
            for (index, palette) in SunsetWashPalette.allCases.enumerated() {
                try sendAction(paletteButtons[index])
                XCTAssertEqual(SunsetWashPalette.preferred(), palette)
                XCTAssertEqual(paletteButtons.filter { $0.state == .on }.map(\.title), [palette.title])
                XCTAssertFalse(preview.isAnimating, "Palette changes should show the selection overlay immediately")
                let pixels = try renderedPixels(preview)
                XCTAssertNotEqual(pixels, previousPixels)
                previousPixels = pixels
                let selection = try XCTUnwrap(descendants(preview).compactMap { $0 as? SelectionView }.first)
                XCTAssertFalse(selection.isHiddenOrHasHiddenAncestor)
                XCTAssertFalse(selection.acceptsFirstResponder)
            }
            slider.doubleValue = 30
            try sendAction(slider)
            XCTAssertEqual(SunsetWashStrength.preferred(), 0.3)
            XCTAssertEqual(try control(NSTextField.self, "settings.overlayStrength.value", in: appearance).stringValue, "30%")
            XCTAssertFalse(preview.isAnimating)
            let softenedPixels = try renderedPixels(preview)
            XCTAssertNotEqual(softenedPixels, previousPixels)
            let softenedSelection = try XCTUnwrap(descendants(preview).compactMap { $0 as? SelectionView }.first)
            let inside = try renderedColor(softenedSelection, at: CGPoint(x: 250, y: 150))
            let outside = try renderedColor(softenedSelection, at: CGPoint(x: 40, y: 150))

            slider.doubleValue = 0
            try sendAction(slider)
            XCTAssertEqual(SunsetWashStrength.preferred(), 0)
            XCTAssertEqual(try control(NSTextField.self, "settings.overlayStrength.value", in: appearance).stringValue, "0%")
            XCTAssertFalse(preview.isAnimating)
            XCTAssertNotEqual(try renderedPixels(preview), softenedPixels)
            let clearSelection = try XCTUnwrap(descendants(preview).compactMap { $0 as? SelectionView }.first)
            let clearInside = try renderedColor(clearSelection, at: CGPoint(x: 250, y: 150))
            let clearOutside = try renderedColor(clearSelection, at: CGPoint(x: 40, y: 150))
            XCTAssertEqual(clearInside.redComponent, inside.redComponent, accuracy: 0.005)
            XCTAssertEqual(clearInside.greenComponent, inside.greenComponent, accuracy: 0.005)
            XCTAssertEqual(clearInside.blueComponent, inside.blueComponent, accuracy: 0.005)
            let outsideChange = abs(clearOutside.redComponent - outside.redComponent)
                + abs(clearOutside.greenComponent - outside.greenComponent)
                + abs(clearOutside.blueComponent - outside.blueComponent)
            XCTAssertGreaterThan(outsideChange, 0.02, "Strength should change the wash outside the clear selection")

            try sendHover(false, to: overlayOptions, in: window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            XCTAssertFalse(preview.isAnimating)
            XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
            XCTAssertEqual(try renderedPixels(preview), capturePixels,
                           "Leaving the overlay group should restore the screenshot preview")
            let backdrop = try control(NSSwitch.self, "settings.backdrop", in: appearance)
            backdrop.state = .on
            try sendAction(backdrop)
            XCTAssertFalse(descendants(preview).contains { $0 is SelectionView })
            XCTAssertTrue(descendants(preview).contains { $0 is AnnotationFrameView })
            XCTAssertTrue(descendants(preview).contains { $0 is AnnotationCanvasView })
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertTrue(preview.isAnimating) }
            XCTAssertTrue(window.firstResponder === focus, "The selection preview must not take keyboard focus")
            XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
            XCTAssertEqual(unrelatedPreferences(), preferences)
            XCTAssertEqual(NSApplication.shared.windows.filter(\.isVisible).map(\.windowNumber).sorted(), visibleWindows)
        }
    }

    @MainActor
    func testShortcutFailureRestoresTheWorkingChoiceAndSuccessPersists() throws {
        try withSettings { controller, _, content in
            let popup = try control(NSPopUpButton.self, "settings.shortcut", in: content)
            XCTAssertEqual(popup.itemTitles, ShortcutChoice.allCases.map(\.title))
            var requested: ShortcutChoice?
            controller.onShortcutChange = { requested = $0; return false }
            popup.selectItem(at: ShortcutChoice.controlShift3.rawValue)
            try sendAction(popup)
            XCTAssertEqual(requested, .controlShift3)
            XCTAssertEqual(popup.indexOfSelectedItem, ShortcutChoice.controlShift2.rawValue)
            XCTAssertEqual(ShortcutChoice.preferred, .controlShift2)

            controller.onShortcutChange = { requested = $0; return true }
            popup.selectItem(at: ShortcutChoice.optionShift2.rawValue)
            try sendAction(popup)
            XCTAssertEqual(requested, .optionShift2)
            XCTAssertEqual(ShortcutChoice.preferred, .optionShift2)

            var trackpadEnabled: Bool?
            controller.onTrackpadShortcutChange = { trackpadEnabled = $0 }
            let trackpad = try control(NSSwitch.self, "settings.trackpad", in: content)
            trackpad.state = .off
            try sendAction(trackpad)
            XCTAssertEqual(trackpadEnabled, false)
            XCTAssertFalse(TrackpadShortcutPreference.isEnabled)
        }
    }

    @MainActor
    func testAnnotationDefaultsUpdateValuesPreferencesAndEditorCallback() throws {
        try withSettings { controller, _, content in
            try sendAction(control(NSButton.self, "settings.pane.annotations", in: content))
            var updatedStyle: AnnotationStyle?
            controller.onStyleChange = { updatedStyle = $0 }
            let color = try control(NSColorWell.self, "settings.annotationColor", in: content)
            let arrow = try control(NSSlider.self, "settings.arrowSize", in: content)
            let text = try control(NSSlider.self, "settings.textSize", in: content)
            color.color = NSColor(srgbRed: 0.8, green: 0.2, blue: 0.3, alpha: 1)
            arrow.doubleValue = 7
            text.doubleValue = 22
            try sendAction(arrow)
            let style = try XCTUnwrap(updatedStyle)
            XCTAssertEqual(style.lineWidth, 7)
            XCTAssertEqual(style.fontSize, 22)
            XCTAssertEqual(AnnotationStyle.preferred.lineWidth, 7)
            XCTAssertEqual(AnnotationStyle.preferred.fontSize, 22)
            XCTAssertEqual(style.color.redComponent, 0.8, accuracy: 0.001)
            XCTAssertEqual(AnnotationStyle.preferred.color.greenComponent, 0.2, accuracy: 0.001)
            XCTAssertEqual(try control(NSTextField.self, "settings.arrowSize.value", in: content).stringValue, "7 pt")
            XCTAssertEqual(try control(NSTextField.self, "settings.textSize.value", in: content).stringValue, "22 pt")
        }
    }

    @MainActor
    func testBackgroundMarginFollowsToggleAndBorderColorKeepsItsCallback() throws {
        try withSettings { controller, _, content in
            try sendAction(control(NSButton.self, "settings.pane.appearance", in: content))
            let backdrop = try control(NSSwitch.self, "settings.backdrop", in: content)
            let margin = try control(NSSlider.self, "settings.backdropMargin", in: content)
            XCTAssertEqual(backdrop.state, .off)
            XCTAssertFalse(margin.isEnabled)
            backdrop.state = .on
            try sendAction(backdrop)
            XCTAssertTrue(margin.isEnabled)
            XCTAssertTrue(CaptureAppearance.preferred.usesDesktopBackdrop)
            margin.doubleValue = 64
            try sendAction(margin)
            XCTAssertEqual(CaptureAppearance.preferred.backdropMargin, 64)
            XCTAssertEqual(try control(NSTextField.self, "settings.backdropMargin.value", in: content).stringValue, "64 pt")
            backdrop.state = .off
            try sendAction(backdrop)
            XCTAssertFalse(margin.isEnabled)
            XCTAssertFalse(CaptureAppearance.preferred.usesDesktopBackdrop)

            var updatedBorder: NSColor?
            controller.onBorderColorChange = { updatedBorder = $0 }
            let border = try control(NSColorWell.self, "settings.borderColor", in: content)
            border.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            try sendAction(border)
            XCTAssertEqual(try XCTUnwrap(updatedBorder).blueComponent, 0.6, accuracy: 0.001)
            XCTAssertEqual(CaptureAppearance.preferred.borderColor.redComponent, 0.2, accuracy: 0.001)
        }
    }

    @MainActor
    func testRealPreviewsUpdateAfterAppearanceAndAnnotationChanges() throws {
        try withSettings { _, _, content in
            try sendAction(control(NSButton.self, "settings.pane.appearance", in: content))
            let appearance = try control(SettingsPreviewView.self, "settings.preview.appearance", in: content)
            appearance.stopAnimation()
            XCTAssertTrue(descendants(appearance).contains { $0 is AnnotationFrameView })
            XCTAssertTrue(descendants(appearance).contains { $0 is AnnotationCanvasView })
            let initialAppearance = try renderedPixels(appearance)
            XCTAssertEqual(try renderedPixels(appearance), initialAppearance)
            XCTAssertEqual(appearance.accessibilityLabel(), "Capture preview. Background off.")

            let backdrop = try control(NSSwitch.self, "settings.backdrop", in: content)
            backdrop.state = .on
            try sendAction(backdrop)
            let framedAppearance = try renderedPixels(appearance)
            XCTAssertNotEqual(framedAppearance, initialAppearance)
            XCTAssertEqual(appearance.accessibilityLabel(), "Capture preview. Background on, 48 point margin.")

            let margin = try control(NSSlider.self, "settings.backdropMargin", in: content)
            margin.doubleValue = 80
            try sendAction(margin)
            let widerMargin = try renderedPixels(appearance)
            XCTAssertNotEqual(widerMargin, framedAppearance)
            XCTAssertEqual(appearance.accessibilityLabel(), "Capture preview. Background on, 80 point margin.")

            let border = try control(NSColorWell.self, "settings.borderColor", in: content)
            border.color = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.3, alpha: 1)
            try sendAction(border)
            XCTAssertNotEqual(try renderedPixels(appearance), widerMargin)

            try sendAction(control(NSButton.self, "settings.pane.annotations", in: content))
            let annotations = try control(SettingsPreviewView.self, "settings.preview.annotations", in: content)
            annotations.stopAnimation()
            XCTAssertTrue(descendants(annotations).contains { $0 is AnnotationFrameView })
            XCTAssertTrue(descendants(annotations).contains { $0 is AnnotationCanvasView })
            let initialAnnotations = try renderedPixels(annotations)
            let arrow = try control(NSSlider.self, "settings.arrowSize", in: content)
            let text = try control(NSSlider.self, "settings.textSize", in: content)
            arrow.doubleValue = 12
            text.doubleValue = 28
            try sendAction(arrow)
            XCTAssertNotEqual(try renderedPixels(annotations), initialAnnotations)
            XCTAssertEqual(annotations.accessibilityLabel(), "Annotation preview. 12 point arrow, 28 point text.")
        }
    }

    @MainActor
    func testColorWellsDeactivateWhenLeavingTheirPaneOrClosingSettings() throws {
        try withSettings { _, window, content in
            defer { NSColorPanel.shared.orderOut(nil) }
            try sendAction(control(NSButton.self, "settings.pane.annotations", in: content))
            let annotationColor = try control(NSColorWell.self, "settings.annotationColor", in: content)
            annotationColor.activate(true)
            XCTAssertTrue(annotationColor.isActive)
            try sendAction(control(NSButton.self, "settings.pane.appearance", in: content))
            XCTAssertFalse(annotationColor.isActive)

            let borderColor = try control(NSColorWell.self, "settings.borderColor", in: content)
            borderColor.activate(true)
            XCTAssertTrue(borderColor.isActive)
            window.close()
            XCTAssertFalse(borderColor.isActive)
        }
    }

    @MainActor
    func testPaneControlsFitInLightAndDarkAppearances() throws {
        try withSettings { _, window, content in
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                for pane in ["capture", "appearance", "annotations"] {
                    try sendAction(control(NSButton.self, "settings.pane.\(pane)", in: content))
                    content.layoutSubtreeIfNeeded()
                    let selected = try control(NSView.self, "settings.content.\(pane)", in: content)
                    let sectionTitles: [String]
                    switch pane {
                    case "capture": sectionTitles = ["Shortcuts"]
                    case "appearance": sectionTitles = ["Screenshot", "Selection overlay"]
                    default: sectionTitles = ["Defaults"]
                    }
                    let labels = descendants(selected).compactMap { ($0 as? NSTextField)?.stringValue }
                    for title in sectionTitles { XCTAssertTrue(labels.contains(title), "Missing \(title) section title") }
                    if pane != "capture" {
                        XCTAssertFalse(descendants(selected).contains { $0 is NSScrollView },
                                       "\(pane) should fit without scrolling")
                    }
                    let views = descendants(selected).filter {
                        ($0 is NSControl || $0 is SettingsPreviewView)
                            && $0.identifier?.rawValue.hasPrefix("settings.") == true && !$0.isHidden
                    }
                    XCTAssertFalse(views.isEmpty)
                    if pane != "capture" {
                        let preview = try control(SettingsPreviewView.self, "settings.preview.\(pane)", in: selected)
                        let previewFrame = preview.convert(preview.bounds, to: selected)
                        for setting in views where setting is NSControl {
                            let settingFrame = setting.convert(setting.bounds, to: selected)
                            XCTAssertGreaterThanOrEqual(previewFrame.minX, settingFrame.maxX,
                                                        "The \(pane) preview should be to the right of \(setting.identifier?.rawValue ?? "")")
                        }
                    }
                    for view in views {
                        XCTAssertGreaterThan(view.bounds.width, 0)
                        XCTAssertGreaterThan(view.bounds.height, 0)
                        for container in [selected, content] {
                            let frame = view.convert(view.bounds, to: container)
                            XCTAssertGreaterThanOrEqual(frame.minX, container.bounds.minX - 1, "\(view.identifier?.rawValue ?? "") in \(pane)")
                            XCTAssertGreaterThanOrEqual(frame.minY, container.bounds.minY - 1, "\(view.identifier?.rawValue ?? "") in \(pane)")
                            XCTAssertLessThanOrEqual(frame.maxX, container.bounds.maxX + 1, "\(view.identifier?.rawValue ?? "") in \(pane)")
                            XCTAssertLessThanOrEqual(frame.maxY, container.bounds.maxY + 1, "\(view.identifier?.rawValue ?? "") in \(pane)")
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func withSettings(_ body: (PreferencesController, NSWindow, NSView) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let previous = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in preferenceKeys {
                if let value = previous[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        preferenceKeys.forEach { defaults.removeObject(forKey: $0) }
        CaptureBackground.aurora.remember()
        SettingsTestApplication.prepare()
        let controller = PreferencesController()
        controller.show()
        let window = try settingsWindow()
        defer { window.close() }
        window.setFrameOrigin(CGPoint(x: NSEvent.mouseLocation.x + 40, y: window.frame.minY))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        try body(controller, window, content)
    }

    @MainActor
    private func settingsWindow() throws -> NSWindow {
        try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == "point.settings" && $0.isVisible
        })
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    private func renderedPixels(_ view: NSView) throws -> Data {
        (view as? SettingsPreviewView)?.stopAnimation()
        view.layoutSubtreeIfNeeded()
        view.display()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        let byteCount = bitmap.bytesPerRow * bitmap.pixelsHigh
        pixels.update(repeating: 0, count: byteCount)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return Data(bytes: pixels, count: byteCount)
    }

    @MainActor
    private func renderedColor(_ view: NSView, at point: CGPoint) throws -> NSColor {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let x = Int((point.x - view.bounds.minX) * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        let y = Int((view.bounds.maxY - point.y) * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    @MainActor
    private func control<T: NSView>(_ type: T.Type, _ identifier: String, in content: NSView) throws -> T {
        try XCTUnwrap(([content] + descendants(content)).first {
            $0.identifier?.rawValue == identifier
        } as? T, "Missing settings view \(identifier)")
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
}

@MainActor
enum SettingsTestApplication {
    private static var isPrepared = false

    static func prepare() {
        guard !isPrepared else { return }
        let application = NSApplication.shared
        if application.activationPolicy() == .prohibited {
            XCTAssertTrue(application.setActivationPolicy(.accessory))
        }
        if !application.isRunning { application.finishLaunching() }
        isPrepared = true
    }

    static func makeKey(_ window: NSWindow) {
        prepare()
        let application = NSApplication.shared
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let deadline = Date().addingTimeInterval(1)
        while !window.isKeyWindow, Date() < deadline {
            if let event = application.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                                 inMode: .default, dequeue: true) {
                application.sendEvent(event)
            }
            application.updateWindows()
        }
        XCTAssertTrue(window.isKeyWindow,
                      "Hover events require a key window (active: \(NSApplication.shared.isActive), policy: \(NSApplication.shared.activationPolicy().rawValue))")
    }
}
