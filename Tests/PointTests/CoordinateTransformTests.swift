import CoreGraphics
import XCTest
@testable import Point

final class CoordinateTransformTests: XCTestCase {
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
