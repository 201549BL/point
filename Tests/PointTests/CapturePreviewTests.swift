import AppKit
import XCTest
@testable import Point

final class CapturePreviewTests: XCTestCase {
    func testPeekingPreviewOnlyOccupiesNarrowStripOnCaptureScreen() {
        let screen = NSRect(x: -1920, y: 40, width: 1920, height: 1040)
        let layout = CapturePreviewLayout(imageSize: NSSize(width: 3840, height: 2160), screenFrame: screen)
        let collapsed = layout.panelFrame(expanded: false)
        let expanded = layout.panelFrame(expanded: true)
        XCTAssertEqual(collapsed.minX, screen.minX)
        XCTAssertEqual(collapsed.width, 44)
        XCTAssertTrue(screen.contains(collapsed))
        XCTAssertTrue(screen.contains(expanded))
        XCTAssertLessThan(layout.cardOrigin(expanded: false).x, 0)
        XCTAssertTrue(NSRect(origin: .zero, size: expanded.size).contains(
            NSRect(origin: layout.cardOrigin(expanded: true), size: layout.cardSize)))
        XCTAssertLessThanOrEqual(layout.cardSize.width, 200)
        XCTAssertLessThanOrEqual(layout.cardSize.height, 144)
    }

    @MainActor
    func testPreviewExpandsOnHoverAndNeverBecomesKey() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let screen = try XCTUnwrap(NSScreen.main)
        let controller = CapturePreviewController(image: try XCTUnwrap(context.makeImage()), near: screen.frame)
        controller.present()
        defer { controller.dismiss() }
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Copied screenshot" })
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.frame.width, 44, accuracy: 0.5)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        panel.contentView?.mouseEntered(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(panel.frame.width, 224, accuracy: 0.5)
        XCTAssertFalse(panel.isKeyWindow)
        panel.contentView?.mouseExited(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(panel.frame.width, 44, accuracy: 0.5)
        XCTAssertFalse(panel.isKeyWindow)
    }

    func testDragPauseComposesWithHoverAndSaveWithoutSaving() throws {
        var lifetime = CapturePreviewLifetime()
        lifetime.setPaused(false, for: .hover, now: 0)
        lifetime.setPaused(true, for: .drag, now: 2)
        lifetime.setPaused(true, for: .save, now: 3)
        lifetime.setPaused(true, for: .hover, now: 4)
        lifetime.setPaused(false, for: .drag, now: 20)
        XCTAssertFalse(lifetime.isDragging)
        XCTAssertNil(lifetime.timeUntilDismissal(now: 30))
        lifetime.setPaused(false, for: .save, now: 30)
        XCTAssertNil(lifetime.timeUntilDismissal(now: 40))
        lifetime.setPaused(false, for: .hover, now: 40)
        XCTAssertEqual(try XCTUnwrap(lifetime.timeUntilDismissal(now: 43)), 1)
        XCTAssertNil(lifetime.savedURL)
        XCTAssertEqual(lifetime.actionTitle, "Save…")
    }

    @MainActor
    func testDragPayloadContainsOneFullResolutionPNGAndPersistentFileWithoutChangingClipboard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 37, height: 23, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let clipboardChangeCount = NSPasteboard.general.changeCount
        var export: CapturePreviewDragExport? = CapturePreviewDragExport(image: image, directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let item = try XCTUnwrap(export).pasteboardItem()
        XCTAssertEqual(Set(item.types), Set([.fileURL, .png]))
        let data = try XCTUnwrap(item.data(forType: .png))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 37)
        XCTAssertEqual(bitmap.pixelsHigh, 23)
        let url = try XCTUnwrap(URL(string: XCTUnwrap(item.string(forType: .fileURL))))
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: url), data)
        let secondItem = try XCTUnwrap(export).pasteboardItem()
        XCTAssertEqual(secondItem.string(forType: .fileURL), item.string(forType: .fileURL))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        export = nil
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
    }

    @MainActor
    func testFailedDragExportCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let export = CapturePreviewDragExport(image: try XCTUnwrap(context.makeImage()), directory: directory)
        XCTAssertThrowsError(try export.pasteboardItem())
        try FileManager.default.removeItem(at: directory)
        let item = try export.pasteboardItem()
        let url = try XCTUnwrap(URL(string: XCTUnwrap(item.string(forType: .fileURL))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testHoverPreservesRemainingTime() throws {
        var lifetime = CapturePreviewLifetime()
        lifetime.setPaused(false, for: .hover, now: 10)
        XCTAssertEqual(try XCTUnwrap(lifetime.timeUntilDismissal(now: 12)), 4)
        lifetime.setPaused(true, for: .hover, now: 12)
        XCTAssertNil(lifetime.timeUntilDismissal(now: 100))
        lifetime.setPaused(false, for: .hover, now: 100)
        XCTAssertEqual(try XCTUnwrap(lifetime.timeUntilDismissal(now: 103)), 1)
        XCTAssertEqual(try XCTUnwrap(lifetime.timeUntilDismissal(now: 105)), 0)
    }

    func testCancelledOrFailedSaveResumesOnlyAfterHoverEnds() throws {
        var lifetime = CapturePreviewLifetime()
        lifetime.setPaused(false, for: .hover, now: 0)
        lifetime.setPaused(true, for: .save, now: 2)
        XCTAssertTrue(lifetime.isSaving)
        lifetime.setPaused(true, for: .hover, now: 20)
        lifetime.setPaused(false, for: .save, now: 30)
        XCTAssertFalse(lifetime.isSaving)
        XCTAssertNil(lifetime.timeUntilDismissal(now: 40))
        XCTAssertEqual(lifetime.actionTitle, "Save…")
        lifetime.setPaused(false, for: .hover, now: 40)
        XCTAssertEqual(try XCTUnwrap(lifetime.timeUntilDismissal(now: 43)), 1)
        XCTAssertNil(lifetime.savedURL)
    }

    func testSuccessfulSaveSwitchesActionAndStartsFreshTimeoutAfterWorkflow() throws {
        var lifetime = CapturePreviewLifetime()
        lifetime.setPaused(false, for: .hover, now: 0)
        lifetime.setPaused(true, for: .save, now: 5)
        let url = URL(fileURLWithPath: "/tmp/Point.png")
        lifetime.didSave(to: url, now: 50)
        XCTAssertEqual(lifetime.savedURL, url)
        XCTAssertEqual(lifetime.actionTitle, "Show in Finder")
        XCTAssertNil(lifetime.timeUntilDismissal(now: 100))
        lifetime.setPaused(true, for: .hover, now: 100)
        lifetime.setPaused(false, for: .save, now: 100)
        XCTAssertNil(lifetime.timeUntilDismissal(now: 110))
        lifetime.setPaused(false, for: .hover, now: 110)
        XCTAssertEqual(try XCTUnwrap(lifetime.timeUntilDismissal(now: 115)), 1)
    }
}
