import AppKit
import ImageIO
import AVFoundation

enum AnnotationTool: String, CaseIterable {
    case arrow
    case blur
    case redaction

    var shortcut: String {
        switch self {
        case .arrow: "A"
        case .blur: "B"
        case .redaction: "R"
        }
    }
}

struct ArrowAnnotation: Equatable {
    let id: UUID
    var tail: CGPoint
    var head: CGPoint
    var caption: String
    var captionWidth: CGFloat? = nil
    var captionFontSize: CGFloat? = nil
}

struct RectangleAnnotation: Equatable {
    let id: UUID
    var rect: CGRect
}

struct TextAnnotation: Equatable {
    let id: UUID
    var anchor: CGPoint
    var text: String
    var width: CGFloat? = nil
    var fontSize: CGFloat? = nil
}

enum Annotation: Equatable {
    case arrow(ArrowAnnotation)
    case blur(RectangleAnnotation)
    case redaction(RectangleAnnotation)
    case text(TextAnnotation)

    var id: UUID {
        switch self {
        case let .arrow(value): value.id
        case let .blur(value), let .redaction(value): value.id
        case let .text(value): value.id
        }
    }

    var bounds: CGRect {
        switch self {
        case let .arrow(value):
            return CGRect(
                x: min(value.tail.x, value.head.x),
                y: min(value.tail.y, value.head.y),
                width: abs(value.head.x - value.tail.x),
                height: abs(value.head.y - value.tail.y)
            ).insetBy(dx: -10, dy: -10)
        case let .blur(value), let .redaction(value):
            return value.rect.standardized
        case let .text(value):
            return CGRect(origin: value.anchor, size: CGSize(width: 1, height: 1)).insetBy(dx: -10, dy: -10)
        }
    }

    mutating func translate(by delta: CGPoint, constrainedTo canvas: CGRect) {
        switch self {
        case var .arrow(value):
            let union = CGRect(x: min(value.tail.x, value.head.x), y: min(value.tail.y, value.head.y), width: abs(value.head.x - value.tail.x), height: abs(value.head.y - value.tail.y))
            let adjusted = Geometry.constrainedDelta(delta, moving: union, inside: canvas)
            value.tail.x += adjusted.x
            value.tail.y += adjusted.y
            value.head.x += adjusted.x
            value.head.y += adjusted.y
            self = .arrow(value)
        case var .blur(value):
            value.rect = Geometry.translated(value.rect, by: Geometry.constrainedDelta(delta, moving: value.rect, inside: canvas))
            self = .blur(value)
        case var .redaction(value):
            value.rect = Geometry.translated(value.rect, by: Geometry.constrainedDelta(delta, moving: value.rect, inside: canvas))
            self = .redaction(value)
        case var .text(value):
            let marker = CGRect(origin: value.anchor, size: CGSize(width: 1, height: 1))
            let adjusted = Geometry.constrainedDelta(delta, moving: marker, inside: canvas)
            value.anchor.x += adjusted.x
            value.anchor.y += adjusted.y
            self = .text(value)
        }
    }
}

struct AnnotationStyle {
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat

    static var preferred: AnnotationStyle {
        let defaults = UserDefaults.standard
        let red = defaults.object(forKey: "annotationColorRed") as? CGFloat ?? 0.04
        let green = defaults.object(forKey: "annotationColorGreen") as? CGFloat ?? 0.48
        let blue = defaults.object(forKey: "annotationColorBlue") as? CGFloat ?? 1.0
        return AnnotationStyle(
            color: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1),
            lineWidth: max(2, defaults.object(forKey: "annotationLineWidth") as? CGFloat ?? 4),
            fontSize: max(11, defaults.object(forKey: "annotationFontSize") as? CGFloat ?? 15)
        )
    }
}

struct CaptureAppearance {
    var usesDesktopBackdrop: Bool
    var backdropMargin: CGFloat
    var borderColor: NSColor

    static var preferred: CaptureAppearance {
        let defaults = UserDefaults.standard
        let annotationColor = AnnotationStyle.preferred.color.usingColorSpace(.sRGB) ?? AnnotationStyle.preferred.color
        let borderRed = defaults.object(forKey: "borderColorRed") as? CGFloat ?? annotationColor.redComponent
        let borderGreen = defaults.object(forKey: "borderColorGreen") as? CGFloat ?? annotationColor.greenComponent
        let borderBlue = defaults.object(forKey: "borderColorBlue") as? CGFloat ?? annotationColor.blueComponent
        return CaptureAppearance(
            usesDesktopBackdrop: defaults.bool(forKey: "usesDesktopBackdrop"),
            backdropMargin: min(80, max(32, defaults.object(forKey: "backdropMargin") as? CGFloat ?? 48)),
            borderColor: NSColor(srgbRed: borderRed, green: borderGreen, blue: borderBlue, alpha: 1)
        )
    }
}

@MainActor
final class AnnotationSession {
    private(set) var annotations: [Annotation] = []
    private(set) var selectedID: UUID?
    var tool: AnnotationTool = .arrow

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    func select(_ id: UUID?) { selectedID = id }

    func checkpoint() {
        undoStack.append(annotations)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func append(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
        selectedID = annotation.id
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func annotation(id: UUID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    func deleteSelection() {
        guard let selectedID, annotations.contains(where: { $0.id == selectedID }) else { return }
        remove(id: selectedID)
        self.selectedID = nil
    }

    func remove(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func cancelNewAnnotation(id: UUID) {
        guard annotations.last?.id == id else { return }
        annotations.removeLast()
        if !undoStack.isEmpty { undoStack.removeLast() }
        redoStack.removeAll()
        if selectedID == id { selectedID = nil }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
}

enum Geometry {
    static let minimumTextBoxWidth: CGFloat = 64

    static func translated(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        rect.offsetBy(dx: delta.x, dy: delta.y)
    }

    static func constrainedDelta(_ delta: CGPoint, moving rect: CGRect, inside bounds: CGRect) -> CGPoint {
        var result = delta
        if rect.minX + result.x < bounds.minX { result.x = bounds.minX - rect.minX }
        if rect.maxX + result.x > bounds.maxX { result.x = bounds.maxX - rect.maxX }
        if rect.minY + result.y < bounds.minY { result.y = bounds.minY - rect.minY }
        if rect.maxY + result.y > bounds.maxY { result.y = bounds.maxY - rect.maxY }
        return result
    }

    static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    static func captionRect(for arrow: ArrowAnnotation, text: String, style: AnnotationStyle, canvas: CGRect) -> CGRect {
        textRect(anchor: arrow.tail, text: text, fontSize: arrow.captionFontSize ?? style.fontSize, preferredWidth: arrow.captionWidth, canvas: canvas, offset: CGPoint(x: 12, y: 12))
    }

    static func standaloneTextRect(for annotation: TextAnnotation, style: AnnotationStyle, canvas: CGRect) -> CGRect {
        textRect(anchor: annotation.anchor, text: annotation.text, fontSize: annotation.fontSize ?? style.fontSize, preferredWidth: annotation.width, canvas: canvas, offset: .zero)
    }

    private static func textRect(anchor: CGPoint, text: String, fontSize: CGFloat, preferredWidth: CGFloat?, canvas: CGRect, offset: CGPoint) -> CGRect {
        let displayText = text.isEmpty ? "Caption" : text
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]
        let availableWidth = min(420, max(minimumTextBoxWidth, canvas.width * 0.72))
        let usefulWidth = maximumUsefulTextWidth(text: displayText, fontSize: fontSize, canvas: canvas)
        let contentWidth = preferredWidth.map { max(minimumTextBoxWidth, min($0, usefulWidth)) }
        let measurementWidth = max(30, (contentWidth ?? availableWidth) - 16)
        let measured = (displayText as NSString).boundingRect(
            with: CGSize(width: measurementWidth, height: 300),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).integral.size
        let size = CGSize(width: contentWidth ?? max(minimumTextBoxWidth, min(usefulWidth, measured.width + 16)), height: max(30, measured.height + 10))
        var origin = CGPoint(x: anchor.x + offset.x, y: anchor.y + offset.y)
        if origin.x + size.width > canvas.maxX - 6 { origin.x = anchor.x - size.width - max(6, offset.x) }
        if origin.y + size.height > canvas.maxY - 6 { origin.y = anchor.y - size.height - max(6, offset.y) }
        origin.x = min(max(origin.x, canvas.minX + 6), canvas.maxX - size.width - 6)
        origin.y = min(max(origin.y, canvas.minY + 6), canvas.maxY - size.height - 6)
        return CGRect(origin: origin, size: size)
    }

    static func maximumUsefulTextWidth(text: String, fontSize: CGFloat, canvas: CGRect) -> CGFloat {
        let displayText = text.isEmpty ? "Caption" : text
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]
        let natural = (displayText as NSString).boundingRect(
            with: CGSize(width: 10_000, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        ).integral.width + 16
        let available = min(420, max(minimumTextBoxWidth, canvas.width * 0.72))
        return max(minimumTextBoxWidth, min(natural, available))
    }
}


/// Background selection is independent of the backdrop visibility switch.
enum CaptureBackground: String, CaseIterable {
    case desktop, aurora, ocean, sunset, custom, system

    var title: String {
        switch self {
        case .desktop: "Desktop wallpaper"
        case .aurora: "Aurora"
        case .ocean: "Ocean"
        case .sunset: "Sunset"
        case .custom: "Custom image"
        case .system: "macOS Wallpapers"
        }
    }

    static func preferred(defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "captureBackground") ?? "") ?? .desktop
    }

    func remember(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "captureBackground")
    }

    static var customImageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Point", isDirectory: true)
            .appendingPathComponent("CaptureBackground.png")
    }

    static func loadImage(at url: URL, maxPixelSize: Int = 4096) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    static func importImage(at url: URL, destination: URL = customImageURL) throws -> CGImage {
        guard let image = loadImage(at: url),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Point.Background", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This image could not be opened. Please choose another image."
            ])
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return image
    }

    func image(desktop: CGImage?) -> CGImage? {
        switch self {
        case .desktop: return desktop
        case .custom: return Self.loadImage(at: Self.customImageURL)
        case .system: return Self.loadImage(at: Self.systemImageURL)
        default:
            let colors: [NSColor]
            switch self {
            case .aurora: colors = [NSColor(srgbRed: 0.12, green: 0.08, blue: 0.35, alpha: 1), .systemPurple, .systemTeal]
            case .ocean: colors = [NSColor(srgbRed: 0.02, green: 0.12, blue: 0.3, alpha: 1), .systemBlue, .systemCyan]
            default: colors = [.systemPurple, .systemPink, .systemOrange]
            }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSGradient(colors: colors)?.draw(in: CGRect(x: 0, y: 0, width: 1600, height: 1000), angle: 35)
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.cgImage
        }
    }
}


extension CaptureBackground {
    static var systemImageURL: URL {
        customImageURL.deletingLastPathComponent().appendingPathComponent("SystemBackground.png")
    }
}

struct SystemWallpaper {
    let title: String
    let url: URL
    var remoteURL: URL? = nil
    var isPreviewOnly = false
    var desktopAssetID: String? = nil

    var canSelect: Bool { !isPreviewOnly || remoteURL != nil || desktopAssetID != nil }

    func resolvedImage() async throws -> CGImage {
        guard isPreviewOnly else { return try image() }
        let cache = CaptureBackground.systemImageURL.deletingLastPathComponent()
            .appendingPathComponent("WallpaperCache", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
        if let image = CaptureBackground.loadImage(at: cache) { return image }
        let image: CGImage
        if let desktopAssetID {
            image = try await Self.downloadDesktopImage(id: desktopAssetID)
        } else if let remoteURL {
            // Read only the video data needed to obtain a full-quality still.
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: remoteURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 4096, height: 4096)
            image = try await generator.image(at: .zero).image
        } else {
            throw WallpaperError.downloadInSettings
        }
        try Task.checkCancellation()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CaptureError.cropFailed }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: .atomic)
        return image
    }

    enum WallpaperError: LocalizedError {
        case downloadInSettings
        var errorDescription: String? { "Download this wallpaper in macOS Wallpaper Settings first, then reopen the background picker." }
    }

    func image() throws -> CGImage {
        guard !isPreviewOnly else { throw WallpaperError.downloadInSettings }
        if ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 4096, height: 4096)
            return try generator.copyCGImage(at: .zero, actualTime: nil)
        }
        guard let image = CaptureBackground.loadImage(at: url) else { throw CaptureError.cropFailed }
        return image
    }

    static func available() -> [SystemWallpaper] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let roots = [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures"),
            URL(fileURLWithPath: "/Library/Desktop Pictures"),
            support.appendingPathComponent("com.apple.mobileAssetDesktop"),
            URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture"),
        ]
        var images: [String: SystemWallpaper] = [:]
        var descriptors: [URL] = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                let name = url.deletingPathExtension().lastPathComponent
                if url.pathExtension == "madesktop" { descriptors.append(url) }
                if ["heic", "jpg", "jpeg", "png", "tiff"].contains(url.pathExtension.lowercased()) {
                    images[name] = SystemWallpaper(title: name, url: url)
                }
            }
        }
        for url in descriptors {
            let name = url.deletingPathExtension().lastPathComponent
            guard images[name] == nil, let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let path = plist["thumbnailPath"] as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            images[name] = SystemWallpaper(title: name, url: URL(fileURLWithPath: path), isPreviewOnly: true, desktopAssetID: plist["mobileAssetID"] as? String ?? name)
        }
        let aerialRoots = [support.appendingPathComponent("com.apple.wallpaper/aerials"),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer")]
        for root in aerialRoots {
            let manifestURLs = [root.appendingPathComponent("manifest/entries.json"), root.appendingPathComponent("entries.json")]
            for manifest in manifestURLs {
                guard let data = try? Data(contentsOf: manifest),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let assets = json["assets"] as? [[String: Any]] else { continue }
                for asset in assets {
                    guard let id = asset["id"] as? String, let name = asset["accessibilityLabel"] as? String else { continue }
                    let candidates = [root.appendingPathComponent("videos/\(id).mov"),
                        root.appendingPathComponent("4KSDR240FPS/\(id).mov"),
                        root.appendingPathComponent("thumbnails/\(id).png")]
                    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
                    let remote = (asset["url-4K-SDR-240FPS"] as? String).flatMap(URL.init(string:))
                    images[id] = SystemWallpaper(title: name, url: url, remoteURL: remote, isPreviewOnly: url.pathExtension == "png")
                }
            }
        }
        return images.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}


extension SystemWallpaper {
    static func desktopDownloadURL(id: String, catalog: Data) throws -> URL {
        guard let plist = try PropertyListSerialization.propertyList(from: catalog, format: nil) as? [String: Any],
              let assets = plist["Assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["DesktopPictureID"] as? String == id }),
              let base = asset["__BaseURL"] as? String,
              let path = asset["__RelativePath"] as? String,
              let url = URL(string: base + path), url.scheme == "https",
              let host = url.host, host == "apple.com" || host.hasSuffix(".apple.com") || host.hasSuffix(".cdn-apple.com") else {
            throw WallpaperError.downloadInSettings
        }
        return url
    }

    private static func downloadDesktopImage(id: String) async throws -> CGImage {
        let catalogURL = URL(string: "https://mesu.apple.com/assets/macos/com_apple_MobileAsset_DesktopPicture/com_apple_MobileAsset_DesktopPicture.xml")!
        let (catalog, catalogResponse) = try await URLSession.shared.data(from: catalogURL)
        guard (catalogResponse as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let url = try desktopDownloadURL(id: id, catalog: catalog)
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try imageFromDesktopArchive(archive)
        }.value
    }

    /// Extract a single image to a chosen temporary file, never archive paths.
    static func imageFromDesktopArchive(_ archive: URL) throws -> CGImage {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", archive.path]
        let output = Pipe()
        listing.standardOutput = output
        listing.standardError = FileHandle.nullDevice
        try listing.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()
        let entries = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard listing.terminationStatus == 0,
              let entry = entries.first(where: {
                  $0.hasPrefix("AssetData/") && ["heic", "heif", "jpg", "jpeg", "png", "tiff"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
              }) else { throw CaptureError.cropFailed }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: temporary) }
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        let extraction = Process()
        extraction.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        extraction.arguments = ["-p", archive.path, entry]
        extraction.standardOutput = handle
        extraction.standardError = FileHandle.nullDevice
        try extraction.run()
        extraction.waitUntilExit()
        guard extraction.terminationStatus == 0, let image = CaptureBackground.loadImage(at: temporary) else { throw CaptureError.cropFailed }
        return image
    }
}
