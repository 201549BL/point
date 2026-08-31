import AppKit

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
