import AppKit
import CoreGraphics
import ScreenCaptureKit

struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let image: CGImage
    let wallpaperImage: CGImage?

    var pointPixelScale: CGFloat {
        CGFloat(image.width) / screenFrame.width
    }
}

enum CaptureError: LocalizedError {
    case noDisplays
    case displayUnavailable(CGDirectDisplayID)
    case invalidSelection
    case cropFailed

    var errorDescription: String? {
        switch self {
        case .noDisplays: "No displays are available to capture."
        case let .displayUnavailable(id): "Display \(id) is no longer available."
        case .invalidSelection: "The selected region is empty or outside the display."
        case .cropFailed: "The selected pixels could not be cropped."
        }
    }
}

final class ScreenCaptureService {
    @MainActor
    func captureConnectedDisplays() async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let screenPairs: [(CGDirectDisplayID, NSScreen)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen)
        }
        let screensByID = Dictionary(uniqueKeysWithValues: screenPairs)
        let ownApplications = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }

        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            guard let screen = screensByID[display.displayID] else { continue }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            let nativeSize = NativeCaptureDimensions.outputSize(
                contentRect: filter.contentRect,
                pointPixelScale: CGFloat(filter.pointPixelScale)
            )
            configuration.width = nativeSize.width
            configuration.height = nativeSize.height
            configuration.scalesToFit = true
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let wallpaperImage = NSWorkspace.shared.desktopImageURL(for: screen)
                .flatMap { NSImage(contentsOf: $0) }
                .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            snapshots.append(DisplaySnapshot(
                displayID: display.displayID,
                screenFrame: screen.frame,
                image: image,
                wallpaperImage: wallpaperImage
            ))
        }
        guard !snapshots.isEmpty else { throw CaptureError.noDisplays }
        return snapshots
    }

    func crop(snapshot: DisplaySnapshot, selectionInPoints: CGRect) throws -> CGImage {
        let pixelRect = CoordinateTransform.pixelCropRect(
            selectionInPoints: selectionInPoints,
            screenSizeInPoints: snapshot.screenFrame.size,
            imageSizeInPixels: CGSize(width: snapshot.image.width, height: snapshot.image.height)
        )
        guard pixelRect.width > 0, pixelRect.height > 0 else { throw CaptureError.invalidSelection }
        guard let image = snapshot.image.cropping(to: pixelRect) else { throw CaptureError.cropFailed }
        return image
    }
}

enum NativeCaptureDimensions {
    static func outputSize(contentRect: CGRect, pointPixelScale: CGFloat) -> (width: Int, height: Int) {
        let scale = max(1, pointPixelScale)
        return (
            max(1, Int((contentRect.width * scale).rounded())),
            max(1, Int((contentRect.height * scale).rounded()))
        )
    }
}

enum CoordinateTransform {
    /// Converts an AppKit-local rectangle (origin at bottom-left) into a CGImage crop
    /// rectangle (origin at top-left), clamped and snapped to native pixels.
    static func pixelCropRect(
        selectionInPoints: CGRect,
        screenSizeInPoints: CGSize,
        imageSizeInPixels: CGSize
    ) -> CGRect {
        guard screenSizeInPoints.width > 0, screenSizeInPoints.height > 0 else { return .zero }

        let bounds = CGRect(origin: .zero, size: screenSizeInPoints)
        let selection = selectionInPoints.standardized.intersection(bounds)
        guard !selection.isNull, !selection.isEmpty else { return .zero }

        let scaleX = imageSizeInPixels.width / screenSizeInPoints.width
        let scaleY = imageSizeInPixels.height / screenSizeInPoints.height
        let minX = floor(selection.minX * scaleX)
        let maxX = ceil(selection.maxX * scaleX)
        let minY = floor((screenSizeInPoints.height - selection.maxY) * scaleY)
        let maxY = ceil((screenSizeInPoints.height - selection.minY) * scaleY)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(CGRect(origin: .zero, size: imageSizeInPixels))
    }
}
