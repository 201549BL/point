import CoreGraphics
import XCTest
@testable import Point

final class CoordinateTransformTests: XCTestCase {
    func testSelectionDimensionsFollowEachDraggedCorner() {
        let selection = CGRect(x: 300, y: 300, width: 200, height: 150)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 120, height: 26)
        for cursor in [CGPoint(x: 300, y: 300), CGPoint(x: 500, y: 300),
                       CGPoint(x: 300, y: 450), CGPoint(x: 500, y: 450)] {
            let label = SelectionLabelLayout.frame(selection: selection, cursor: cursor, size: size, bounds: bounds)
            if cursor.x == selection.minX { XCTAssertEqual(label.maxX, cursor.x - 12) }
            else { XCTAssertEqual(label.minX, cursor.x + 12) }
            if cursor.y == selection.minY { XCTAssertEqual(label.maxY, cursor.y - 12) }
            else { XCTAssertEqual(label.minY, cursor.y + 12) }
        }
    }

    func testSelectionDimensionsFlipAtScreenEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 120, height: 26)
        for cursor in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0),
                       CGPoint(x: 0, y: 800), CGPoint(x: 1000, y: 800)] {
            let selection = CGRect(x: min(cursor.x, 500), y: min(cursor.y, 400), width: 500, height: 400)
            let label = SelectionLabelLayout.frame(selection: selection, cursor: cursor, size: size, bounds: bounds)
            XCTAssertTrue(bounds.insetBy(dx: 8, dy: 8).contains(label))
            XCTAssertLessThan(abs(label.midX - cursor.x), size.width)
            XCTAssertLessThan(abs(label.midY - cursor.y), size.height)
        }
    }

    func testNativeCaptureDimensionsApplyRetinaPointPixelScale() {
        let result = NativeCaptureDimensions.outputSize(
            contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
            pointPixelScale: 2
        )

        XCTAssertEqual(result.width, 3024)
        XCTAssertEqual(result.height, 1964)
    }

    func testRetinaCropConvertsBottomLeftPointsToTopLeftPixels() {
        let result = CoordinateTransform.pixelCropRect(
            selectionInPoints: CGRect(x: 100, y: 200, width: 500, height: 300),
            screenSizeInPoints: CGSize(width: 1512, height: 982),
            imageSizeInPixels: CGSize(width: 3024, height: 1964)
        )

        XCTAssertEqual(result, CGRect(x: 200, y: 964, width: 1000, height: 600))
    }

    func testOneScaleCropPreservesPointDimensions() {
        let result = CoordinateTransform.pixelCropRect(
            selectionInPoints: CGRect(x: 10, y: 20, width: 50, height: 30),
            screenSizeInPoints: CGSize(width: 1920, height: 1080),
            imageSizeInPixels: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(result, CGRect(x: 10, y: 1030, width: 50, height: 30))
    }

    func testFractionalPointBoundsExpandToWholePixels() {
        let result = CoordinateTransform.pixelCropRect(
            selectionInPoints: CGRect(x: 1.25, y: 2.25, width: 2.5, height: 3.5),
            screenSizeInPoints: CGSize(width: 100, height: 100),
            imageSizeInPixels: CGSize(width: 200, height: 200)
        )

        XCTAssertEqual(result, CGRect(x: 2, y: 188, width: 6, height: 8))
    }

    func testSelectionIsClampedToDisplay() {
        let result = CoordinateTransform.pixelCropRect(
            selectionInPoints: CGRect(x: -10, y: 90, width: 30, height: 30),
            screenSizeInPoints: CGSize(width: 100, height: 100),
            imageSizeInPixels: CGSize(width: 200, height: 200)
        )

        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 40, height: 20))
    }
}
