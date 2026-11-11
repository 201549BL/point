import AppKit
import XCTest
@testable import Point

final class SunsetWashTests: XCTestCase {
    private var previousSunsetStrength: Any?
    private var previousPalette: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousSunsetStrength = UserDefaults.standard.object(forKey: SunsetWashStrength.defaultsKey)
        previousPalette = UserDefaults.standard.object(forKey: SunsetWashPalette.defaultsKey)
        SunsetWashPalette.sunset.remember()
        SunsetWashStrength.remember(0.45)
    }

    override func tearDownWithError() throws {
        if let previousSunsetStrength {
            UserDefaults.standard.set(previousSunsetStrength, forKey: SunsetWashStrength.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SunsetWashStrength.defaultsKey)
        }
        if let previousPalette {
            UserDefaults.standard.set(previousPalette, forKey: SunsetWashPalette.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SunsetWashPalette.defaultsKey)
        }
        try super.tearDownWithError()
    }

    func testSunsetStrengthIsRememberedAndClamped() throws {
        let suite = "Point.SunsetStrengthTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SunsetWashStrength.preferred(defaults: defaults), 0.45)
        SunsetWashStrength.remember(0.3, defaults: defaults)
        XCTAssertEqual(SunsetWashStrength.preferred(defaults: defaults), 0.3)
        defaults.set(2, forKey: SunsetWashStrength.defaultsKey)
        XCTAssertEqual(SunsetWashStrength.preferred(defaults: defaults), 1)
        defaults.set(-1, forKey: SunsetWashStrength.defaultsKey)
        XCTAssertEqual(SunsetWashStrength.preferred(defaults: defaults), 0)
        defaults.set(Double.nan, forKey: SunsetWashStrength.defaultsKey)
        XCTAssertEqual(SunsetWashStrength.preferred(defaults: defaults), 0.45)
    }

    func testColorMoodIsRememberedWithSunsetAsFallback() throws {
        let suite = "Point.PaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SunsetWashPalette.preferred(defaults: defaults), .sunset)
        for palette in SunsetWashPalette.allCases {
            palette.remember(defaults: defaults)
            XCTAssertEqual(SunsetWashPalette.preferred(defaults: defaults), palette)
        }
        defaults.set("custom", forKey: SunsetWashPalette.defaultsKey)
        XCTAssertEqual(SunsetWashPalette.preferred(defaults: defaults), .sunset)
        defaults.set("unknown", forKey: SunsetWashPalette.defaultsKey)
        XCTAssertEqual(SunsetWashPalette.preferred(defaults: defaults), .sunset)
    }

    func testColorMoodsChangeHueWithoutChangingStrength() throws {
        var samples: [NSColor] = []
        for palette in SunsetWashPalette.allCases {
            palette.remember()
            let image = try XCTUnwrap(SunsetWash.image(size: CGSize(width: 320, height: 200), scale: 1))
            samples.append(try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 40, y: 40)?.usingColorSpace(.sRGB)))
        }
        let sunset = samples[0], lagoon = samples[1], twilight = samples[2]
        XCTAssertGreaterThan(sunset.redComponent, sunset.blueComponent)
        XCTAssertGreaterThan(lagoon.greenComponent, lagoon.redComponent + 0.1)
        XCTAssertGreaterThan(twilight.blueComponent, twilight.redComponent)
        for sample in samples {
            XCTAssertEqual(sample.alphaComponent, sunset.alphaComponent, accuracy: 0.005)
        }
    }

    func testDarkModeSoftensEveryPaletteWithoutChangingHue() throws {
        for palette in SunsetWashPalette.allCases {
            palette.remember()
            func sample(darkMode: Bool) throws -> NSColor {
                let image = try XCTUnwrap(SunsetWash.image(size: CGSize(width: 320, height: 200), scale: 1, darkMode: darkMode))
                return try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 160, y: 100)?.usingColorSpace(.sRGB))
            }
            let light = try sample(darkMode: false), dark = try sample(darkMode: true)
            XCTAssertGreaterThan(dark.alphaComponent, 0.1)
            XCTAssertLessThan(dark.alphaComponent, light.alphaComponent)
            XCTAssertEqual(dark.redComponent, light.redComponent, accuracy: 0.02)
            XCTAssertEqual(dark.blueComponent, light.blueComponent, accuracy: 0.02)
        }
    }

    func testSunsetStrengthChangesRenderedOpacity() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SunsetWashStrength.defaultsKey)
        defer {
            if let previous { defaults.set(previous, forKey: SunsetWashStrength.defaultsKey) }
            else { defaults.removeObject(forKey: SunsetWashStrength.defaultsKey) }
        }
        func alpha(_ strength: CGFloat) throws -> CGFloat {
            SunsetWashStrength.remember(strength)
            let image = try XCTUnwrap(SunsetWash.image(size: CGSize(width: 320, height: 200), scale: 1))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 160, y: 100)).alphaComponent
        }
        XCTAssertEqual(try alpha(0), 0)
        let soft = try alpha(0.3), strong = try alpha(0.6)
        XCTAssertGreaterThan(soft, 0)
        XCTAssertEqual(strong, soft * 2, accuracy: 0.01)
    }

    @MainActor
    func testSelectionRevealsAndExportsTheFrozenFrame() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let snapshot = DisplaySnapshot(displayID: 0, screenFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
                                       image: try XCTUnwrap(context.makeImage()), wallpaperImage: nil)
        let view = SelectionView(snapshot: snapshot)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func pixel(x: CGFloat, y: CGFloat) throws -> NSColor {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / 320),
                                               y: Int((200 - y) * CGFloat(bitmap.pixelsHigh) / 200))?.usingColorSpace(.sRGB))
        }
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                            clickCount: 1, pressure: 1))
        }
        let frozen = try pixel(x: 160, y: 100)
        XCTAssertEqual(frozen.alphaComponent, 1)
        view.beginSelection()
        let outside = try pixel(x: 20, y: 100)
        XCTAssertLessThan(try pixel(x: 160, y: 100).greenComponent, frozen.greenComponent - 0.04)
        // Simulate the source advancing after the activation frame was captured.
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 85, y: 80)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 230, y: 140)))
        let selected = try pixel(x: 160, y: 100)
        XCTAssertEqual(selected.redComponent, frozen.redComponent, accuracy: 0.005)
        XCTAssertEqual(selected.greenComponent, frozen.greenComponent, accuracy: 0.005)
        XCTAssertEqual(selected.blueComponent, frozen.blueComponent, accuracy: 0.005)
        XCTAssertEqual(try pixel(x: 20, y: 100).greenComponent, outside.greenComponent, accuracy: 0.005)
        let cropped = try ScreenCaptureService().crop(snapshot: snapshot, selectionInPoints: CGRect(x: 85, y: 80, width: 145, height: 60))
        let exported = try XCTUnwrap(NSBitmapImageRep(cgImage: cropped).colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertEqual(exported.greenComponent, 1, accuracy: 0.005)
        XCTAssertEqual(exported.blueComponent, 1, accuracy: 0.005)
        window.contentView = nil
    }

    func testSunsetRendersAtNativeScale() throws {
        let image = try XCTUnwrap(SunsetWash.image(size: CGSize(width: 320, height: 200), scale: 2))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 400)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let center = try XCTUnwrap(bitmap.colorAt(x: 320, y: 200))
        XCTAssertGreaterThan(center.alphaComponent, 0.2)
        XCTAssertLessThan(center.alphaComponent, 0.35)
        let peach = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1))
        let violet = try XCTUnwrap(bitmap.colorAt(x: 638, y: 398)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(peach.redComponent, peach.blueComponent)
        XCTAssertGreaterThan(violet.blueComponent, violet.redComponent)
    }

    @MainActor
    func testSunsetEntranceFinishesWithoutSettlingOrDisappearing() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Reduce Motion shows the wash immediately")
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let snapshot = DisplaySnapshot(displayID: 0, screenFrame: CGRect(x: 0, y: 0, width: 320, height: 200),
                                       image: try XCTUnwrap(context.makeImage()), wallpaperImage: nil)
        let view = SelectionView(snapshot: snapshot)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func green() throws -> CGFloat {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)).greenComponent
        }
        view.beginEntrance()
        let initial = try green()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let visible = try green()
        XCTAssertLessThan(visible, initial - 0.04)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(try green(), visible, accuracy: 0.005)
        window.contentView = nil
    }

}
