import AppKit
import XCTest
@testable import Point

final class CaptureBackgroundTests: XCTestCase {
    @MainActor
    func testGallerySelectionAndThumbnailLayout() async throws {
        let gallery = BackgroundGalleryView(selected: .ocean)
        let window = NSWindow(contentRect: gallery.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = gallery
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let scroll = try XCTUnwrap(gallery.subviews.compactMap { $0 as? NSScrollView }.first)
        let tiles = try XCTUnwrap(scroll.documentView).subviews.compactMap { $0 as? BackgroundThumbnailButton }
        let ocean = try XCTUnwrap(tiles.first { $0.title == "Ocean" })
        XCTAssertTrue(ocean.isSelectedBackground)
        XCTAssertNotNil(ocean.preview)
        var choice: CaptureBackground?
        gallery.onSelect = { choice = $0 }
        ocean.performClick(nil)
        XCTAssertEqual(choice, .ocean)
        XCTAssertTrue(tiles.allSatisfy { $0.frame.maxX <= scroll.documentView!.bounds.width })

    }

    func testLocalWallpaperCatalogAndDownloadedAerialCanRender() throws {
        let wallpapers = SystemWallpaper.available()
        guard !wallpapers.isEmpty else { throw XCTSkip("No local macOS wallpapers installed") }
        XCTAssertEqual(wallpapers.map(\.title), wallpapers.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        if let still = wallpapers.first(where: { $0.url.pathExtension == "heic" && !$0.isPreviewOnly }) {
            XCTAssertGreaterThan(try still.image().width, 0)
        }
        if let aerial = wallpapers.first(where: { $0.url.pathExtension == "mov" }) {
            XCTAssertGreaterThan(try aerial.image().width, 0)
        }
    }

    func testDesktopWallpaperCatalogResolvesAppleDownload() throws {
        let catalog = try PropertyListSerialization.data(fromPropertyList: ["Assets": [[
            "DesktopPictureID": "Big Sur", "__BaseURL": "https://updates.cdn-apple.com/assets/",
            "__RelativePath": "wallpaper.zip"
        ]]], format: .xml, options: 0)
        XCTAssertEqual(try SystemWallpaper.desktopDownloadURL(id: "Big Sur", catalog: catalog).absoluteString,
            "https://updates.cdn-apple.com/assets/wallpaper.zip")
        XCTAssertThrowsError(try SystemWallpaper.desktopDownloadURL(id: "Missing", catalog: catalog))
        let wallpaper = SystemWallpaper(title: "Big Sur", url: URL(fileURLWithPath: "/thumbnail.heic"),
            isPreviewOnly: true, desktopAssetID: "Big Sur")
        XCTAssertTrue(wallpaper.canSelect)
    }

    func testDesktopArchiveExtractsFullImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("AssetData")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let image = try XCTUnwrap(CaptureBackground.ocean.image(desktop: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: assets.appendingPathComponent("Wallpaper.png"))
        let archive = root.appendingPathComponent("wallpaper.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", archive.path, "AssetData/Wallpaper.png"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let extracted = try SystemWallpaper.imageFromDesktopArchive(archive)
        XCTAssertEqual(extracted.width, image.width)
        XCTAssertEqual(extracted.height, image.height)
    }

    func testPreviewCannotBeUsedAsExportImage() async throws {
        let preview = SystemWallpaper(title: "Preview", url: URL(fileURLWithPath: "/tmp/thumbnail.png"), isPreviewOnly: true)
        XCTAssertFalse(preview.canSelect)
        XCTAssertThrowsError(try preview.image())
        do {
            _ = try await preview.resolvedImage()
            XCTFail("Thumbnail-only wallpaper must not be exported")
        } catch { XCTAssertTrue(error is SystemWallpaper.WallpaperError) }
    }

    func testSelectionIsRememberedAndUnknownValuesUseDesktop() throws {
        let suite = "Point.BackgroundTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CaptureBackground.preferred(defaults: defaults), .desktop)
        CaptureBackground.sunset.remember(defaults: defaults)
        XCTAssertEqual(CaptureBackground.preferred(defaults: defaults), .sunset)
        defaults.set("removed-background", forKey: "captureBackground")
        XCTAssertEqual(CaptureBackground.preferred(defaults: defaults), .desktop)
    }

    func testCustomImageSurvivesRemovalOfOriginalAndFailedReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let destination = directory.appendingPathComponent("saved/background.png")
        let image = try XCTUnwrap(CaptureBackground.ocean.image(desktop: nil))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: source)
        _ = try CaptureBackground.importImage(at: source, destination: destination)
        try FileManager.default.removeItem(at: source)
        XCTAssertNotNil(CaptureBackground.loadImage(at: destination))
        let saved = try Data(contentsOf: destination)
        try Data("invalid image".utf8).write(to: source)
        XCTAssertThrowsError(try CaptureBackground.importImage(at: source, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), saved)
    }

    func testBuiltInBackgroundsRenderWithoutDesktopWallpaper() throws {
        for background in [CaptureBackground.aurora, .ocean, .sunset] {
            let image = try XCTUnwrap(background.image(desktop: nil))
            let composed = try BackdropRenderer.compose(screenshot: image, wallpaper: image,
                canvasSize: CGSize(width: 1600, height: 1000), margin: 48, borderColor: .systemBlue)
            XCTAssertEqual(composed.width, 1696)
            XCTAssertEqual(composed.height, 1096)
        }
    }
}
