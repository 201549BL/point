import AppKit
import CoreGraphics

enum ClipboardError: LocalizedError {
    case pngEncodingFailed
    case pasteboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .pngEncodingFailed: "The capture could not be encoded as a PNG."
        case .pasteboardWriteFailed: "The PNG could not be written to the clipboard."
        }
    }
}

enum ClipboardWriter {
    static func writePNG(_ image: CGImage) throws {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ClipboardError.pngEncodingFailed
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw ClipboardError.pasteboardWriteFailed
        }
    }
}
