import AppKit
import XCTest
@testable import Point

final class CurvedArrowTests: XCTestCase {
    private func arrow(bend: CGFloat = 0) -> ArrowAnnotation {
        ArrowAnnotation(id: UUID(), tail: CGPoint(x: 40, y: 80), head: CGPoint(x: 240, y: 80), caption: "", bend: bend)
    }

    func testStraightDefaultAndSymmetricCurveMatchesOriginalShape() {
        let straight = arrow()
        XCTAssertEqual(straight.bend, 0)
        XCTAssertEqual(straight.bendHandle, CGPoint(x: 140, y: 80))
        XCTAssertEqual(straight.curveBounds, CGRect(x: 40, y: 80, width: 200, height: 0))
        let curved = arrow(bend: 0.4)
        XCTAssertEqual(curved.bendHandle, CGPoint(x: 140, y: 160))
        XCTAssertEqual(curved.endTangent.y / curved.endTangent.x, -1.6, accuracy: 0.0001)
        XCTAssertEqual(curved.curveBounds.maxY, 160, accuracy: 0.001)
        XCTAssertTrue(curved.containsShaft(curved.bendHandle, tolerance: 2))
        for x in stride(from: CGFloat(40), through: 240, by: 10) {
            let t = (x - 40) / 200
            let originalPoint = CGPoint(x: x, y: 80 + 320 * t * (1 - t))
            XCTAssertTrue(curved.containsShaft(originalPoint, tolerance: 0.1))
        }
        XCTAssertFalse(curved.containsShaft(straight.bendHandle, tolerance: 8))
    }

    func testSingleArchPassesThroughHandleWithoutInflectionOrBacktracking() throws {
        let chords = [CGPoint(x: 200, y: 0), CGPoint(x: 120, y: 160), CGPoint(x: -200, y: 0)]
        for chord in chords {
            for position: CGFloat in [0.08, 0.18, 0.5, 0.82, 0.92] {
                for bend: CGFloat in [-0.4, 0.4] {
                    var value = arrow(bend: bend)
                    value.head = CGPoint(x: value.tail.x + chord.x, y: value.tail.y + chord.y)
                    value.bendPosition = position
                    var controls: [CGPoint] = []
                    var endpoints: [CGPoint] = []
                    value.shaft.applyWithBlock { pointer in
                        let element = pointer.pointee
                        if element.type == .addQuadCurveToPoint {
                            controls.append(element.points[0])
                            endpoints.append(element.points[1])
                        } else {
                            XCTAssertEqual(element.type, .moveToPoint)
                            XCTAssertEqual(element.points[0], value.tail)
                        }
                    }
                    XCTAssertEqual(controls.count, 1)
                    let control = try XCTUnwrap(controls.first)
                    XCTAssertEqual(endpoints, [value.head])
                    func sample(_ t: CGFloat) -> CGPoint {
                        let q = 1 - t
                        return CGPoint(x: q*q*value.tail.x + 2*q*t*control.x + t*t*value.head.x,
                                       y: q*q*value.tail.y + 2*q*t*control.y + t*t*value.head.y)
                    }
                    func along(_ point: CGPoint) -> CGFloat {
                        ((point.x - value.tail.x)*chord.x + (point.y - value.tail.y)*chord.y) / 40_000
                    }
                    func offset(_ point: CGPoint) -> CGFloat {
                        (-(point.x - value.tail.x)*chord.y + (point.y - value.tail.y)*chord.x) / 40_000
                    }
                    var low: CGFloat = 0
                    var high: CGFloat = 1
                    for _ in 0..<40 {
                        let middle = (low + high) / 2
                        if along(sample(middle)) < position { low = middle } else { high = middle }
                    }
                    let handlePoint = sample((low + high) / 2)
                    XCTAssertEqual(handlePoint.x, value.bendHandle.x, accuracy: 0.000001)
                    XCTAssertEqual(handlePoint.y, value.bendHandle.y, accuracy: 0.000001)
                    XCTAssertTrue(value.containsShaft(value.bendHandle, tolerance: 0.1))
                    var previous = sample(0)
                    var previousStep: CGPoint?
                    var peakCount = 0
                    var wasRising = true
                    for step in 1...200 {
                        let point = sample(CGFloat(step) / 200)
                        XCTAssertGreaterThan(along(point), along(previous))
                        XCTAssertGreaterThanOrEqual(offset(point) * bend, -0.000001)
                        let delta = CGPoint(x: point.x - previous.x, y: point.y - previous.y)
                        if let previousStep {
                            let cross = previousStep.x * delta.y - previousStep.y * delta.x
                            XCTAssertLessThan(cross * bend, 0)
                        }
                        let rising = (offset(point) - offset(previous)) * bend > 0
                        if wasRising && !rising { peakCount += 1 }
                        if !wasRising { XCTAssertFalse(rising) }
                        wasRising = rising
                        previous = point
                        previousStep = delta
                    }
                    XCTAssertEqual(peakCount, 1)
                    XCTAssertEqual(along(sample(0.5)), 0.25 + position / 2, accuracy: 0.000001)
                    XCTAssertEqual(value.endTangent.x, value.head.x - control.x, accuracy: 0.000001)
                    XCTAssertEqual(value.endTangent.y, value.head.y - control.y, accuracy: 0.000001)
                }
            }
        }
    }

    func testStraightTangentFollowsChordForOffCenterHandle() {
        var value = arrow()
        value.head = CGPoint(x: 220, y: 170)
        for position: CGFloat in [0.08, 0.5, 0.92] {
            value.bendPosition = position
            XCTAssertEqual(value.endTangent, CGPoint(x: 180, y: 90))
        }
    }

    func testBendSnapHasEnterAndLeaveThresholds() {
        var value = arrow(bend: 0.2)
        var snapped = false
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 300)
        value.bend(toward: CGPoint(x: 100, y: 85), snapped: &snapped, canvas: canvas)
        XCTAssertTrue(snapped)
        XCTAssertEqual(value.bend, 0)
        XCTAssertEqual(value.bendHandle, CGPoint(x: 100, y: 80))
        value.bend(toward: CGPoint(x: 180, y: 87), snapped: &snapped, canvas: canvas)
        XCTAssertTrue(snapped)
        XCTAssertEqual(value.bendHandle, CGPoint(x: 180, y: 80))
        value.bend(toward: CGPoint(x: 200, y: 89), snapped: &snapped, canvas: canvas)
        XCTAssertFalse(snapped)
        XCTAssertEqual(value.bend, 9 / 200, accuracy: 0.0001)
    }

    func testAsymmetricHandleMovesTheCurvePeakAndTangent() {
        var value = arrow()
        var snapped = true
        let target = CGPoint(x: 90, y: 160)
        value.bend(toward: target, snapped: &snapped, canvas: CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(value.bendPosition, 0.25)
        XCTAssertEqual(value.bendHandle, target)
        XCTAssertGreaterThan(value.curveBounds.maxY, target.y)
        XCTAssertTrue(value.containsShaft(target, tolerance: 0.1))
        XCTAssertFalse(value.containsShaft(CGPoint(x: 140, y: 140), tolerance: 2))
        XCTAssertEqual(value.endTangent.y / value.endTangent.x, -1.1491736205, accuracy: 0.0001)
    }

    func testStraightHandleRemainsOutsideEndpointHitAreas() {
        for length: CGFloat in [36, 80, 200] {
            var value = ArrowAnnotation(id: UUID(), tail: CGPoint(x: 40, y: 80),
                head: CGPoint(x: 40 + length, y: 80), caption: "")
            var snapped = true
            for x in [CGFloat(-100), 500] {
                value.bend(toward: CGPoint(x: x, y: 80), snapped: &snapped,
                    canvas: CGRect(x: 0, y: 0, width: 600, height: 300))
                XCTAssertGreaterThan(hypot(value.bendHandle.x - value.tail.x, value.bendHandle.y - value.tail.y), 9)
                XCTAssertGreaterThan(hypot(value.bendHandle.x - value.head.x, value.bendHandle.y - value.head.y), 9)
            }
        }
    }

    func testConstraintAndTranslationUseActualCurveBounds() {
        var value = arrow(bend: 2)
        value.bendPosition = 0.25
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 200)
        value.constrainBend(to: canvas)
        XCTAssertEqual(value.curveBounds.maxY, 200, accuracy: 0.001)
        XCTAssertLessThan(value.bendHandle.y, canvas.maxY)
        XCTAssertTrue(value.containsShaft(value.bendHandle, tolerance: 1))
        var annotation = Annotation.arrow(value)
        annotation.translate(by: CGPoint(x: 100, y: 100), constrainedTo: canvas)
        guard case let .arrow(moved) = annotation else { return XCTFail() }
        XCTAssertEqual(moved.bendPosition, value.bendPosition)
        XCTAssertEqual(moved.bend, value.bend)
        XCTAssertEqual(moved.curveBounds.maxX, 300, accuracy: 0.001)
        XCTAssertEqual(moved.curveBounds.maxY, 200, accuracy: 0.001)
    }

    func testResizingKeepsTheBendHandleOutsideEndpointHitAreas() {
        let canvas = CGRect(x: 0, y: 0, width: 300, height: 300)
        for position: CGFloat in [0.08, 0.92] {
            var value = arrow()
            var snapped = true
            value.bend(toward: CGPoint(x: 40 + position * 200, y: 80), snapped: &snapped, canvas: canvas)
            value.head = CGPoint(x: 140, y: 80)
            value.constrainBend(to: canvas)
            XCTAssertGreaterThan(hypot(value.bendHandle.x - value.tail.x, value.bendHandle.y - value.tail.y), 9)
            XCTAssertGreaterThan(hypot(value.bendHandle.x - value.head.x, value.bendHandle.y - value.head.y), 9)
        }
    }

    func testRendererPaintsTheCurveInsteadOfTheChord() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 240, bitsPerComponent: 8,
            bytesPerRow: 1200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 240))
        var curved = arrow(bend: 0.4)
        curved.bendPosition = 0.25
        let image = try AnnotationRenderer.render(source: XCTUnwrap(context.makeImage()),
            canvasSize: CGSize(width: 300, height: 240), annotations: [.arrow(curved)],
            style: AnnotationStyle(color: .red, lineWidth: 4, fontSize: 15))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let bow = try XCTUnwrap(bitmap.colorAt(x: 90, y: 240 - 160)?.usingColorSpace(.sRGB))
        let chord = try XCTUnwrap(bitmap.colorAt(x: 140, y: 240 - 80)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(bow.greenComponent, 0.2)
        XCTAssertGreaterThan(chord.greenComponent, 0.95)
    }

    @MainActor
    func testHandleGestureUndoCurveSelectionAndDoubleClickCaption() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 260, bitsPerComponent: 8,
            bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let session = AnnotationSession()
        let original = arrow()
        session.append(.arrow(original))
        let canvas = AnnotationCanvasView(sourceImage: try XCTUnwrap(context.makeImage()), session: session,
            style: AnnotationStyle(color: .systemBlue, lineWidth: 4, fontSize: 15))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        }
        canvas.mouseDown(with: try event(.leftMouseDown, original.bendHandle))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 100, y: 140)))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 90, y: 160)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 90, y: 160)))
        guard case let .arrow(curved) = session.annotation(id: original.id) else { return XCTFail() }
        XCTAssertEqual(curved.bend, 0.4, accuracy: 0.001)
        XCTAssertEqual(curved.bendPosition, 0.25, accuracy: 0.001)
        session.undo()
        XCTAssertEqual(session.annotations, [.arrow(original)])
        session.redo()
        session.select(nil)
        let shaftPoint = CGPoint(x: 64, y: 135.1603337825)
        canvas.mouseDown(with: try event(.leftMouseDown, shaftPoint))
        canvas.mouseUp(with: try event(.leftMouseUp, shaftPoint))
        XCTAssertEqual(session.selectedID, original.id)
        canvas.mouseDown(with: try event(.leftMouseDown, shaftPoint))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: shaftPoint.x + 10, y: shaftPoint.y + 10)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: shaftPoint.x + 10, y: shaftPoint.y + 10)))
        guard case let .arrow(moved) = session.annotation(id: original.id) else { return XCTFail() }
        XCTAssertEqual(moved.tail, CGPoint(x: curved.tail.x + 10, y: curved.tail.y + 10))
        XCTAssertEqual(moved.bend, curved.bend)
        XCTAssertEqual(moved.bendPosition, curved.bendPosition)
        session.undo()
        canvas.mouseDown(with: try event(.leftMouseDown, curved.head))
        canvas.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 280, y: 100)))
        canvas.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 280, y: 100)))
        guard case let .arrow(resized) = session.annotation(id: original.id) else { return XCTFail() }
        XCTAssertEqual(resized.head, CGPoint(x: 280, y: 100))
        XCTAssertEqual(resized.bendPosition, curved.bendPosition)
        XCTAssertEqual(resized.bend, curved.bend)
        session.undo()
        XCTAssertEqual(session.annotations, [.arrow(curved)])
        canvas.mouseDown(with: try event(.leftMouseDown, curved.bendHandle, clicks: 2))
        canvas.mouseUp(with: try event(.leftMouseUp, curved.bendHandle, clicks: 2))
        XCTAssertNotNil(canvas.subviews.compactMap { $0 as? CaptionTextView }.first)
        XCTAssertEqual(session.annotations, [.arrow(curved)])
    }
}
