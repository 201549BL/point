import AppKit
import XCTest
@testable import Point

final class CaptureMotionTests: XCTestCase {
    func testBackdropExpansionKeepsCaptureAnchoredThroughOvershootAndSettle() {
        let motion = transition(isEnabling: true)
        let start = motion.sample(at: 10)
        XCTAssertEqual(start.panelFrame, motion.startPanelFrame)
        XCTAssertEqual(start.opacity, 0)
        XCTAssertEqual(start.revealPadding, 0)
        XCTAssertFalse(start.isComplete)

        let overshoot = motion.sample(at: 10 + motion.duration * 0.62)
        XCTAssertGreaterThan(overshoot.panelFrame.width, motion.endPanelFrame.width)
        XCTAssertGreaterThan(overshoot.revealPadding, 80)
        XCTAssertEqual(overshoot.opacity, 1)

        for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
            let sample = motion.sample(at: 10 + motion.duration * progress)
            let origin = motion.canvasOrigin(in: sample.panelFrame)
            XCTAssertEqual(sample.panelFrame.minX + origin.x, 300, accuracy: 0.0001)
            XCTAssertEqual(sample.panelFrame.minY + origin.y, 200, accuracy: 0.0001)
        }
        let end = motion.sample(at: 11)
        XCTAssertEqual(end.panelFrame, motion.endPanelFrame)
        XCTAssertEqual(end.opacity, 1)
        XCTAssertEqual(end.revealPadding, 80)
        XCTAssertTrue(end.isComplete)
    }

    func testBackdropCollapseAndInterruptedMotionStartFromCurrentPresentation() {
        let expansion = transition(isEnabling: true)
        let interrupted = expansion.sample(at: 10.08)
        let collapse = CaptureBackdropTransition(
            startTime: 10.08,
            startPanelFrame: interrupted.panelFrame,
            endPanelFrame: expansion.startPanelFrame,
            startOpacity: interrupted.opacity,
            endOpacity: 0,
            startRevealPadding: interrupted.revealPadding,
            endRevealPadding: 0,
            isEnabling: false,
            canvasScreenOrigin: expansion.canvasScreenOrigin
        )
        XCTAssertEqual(collapse.duration, 0.36)
        let start = collapse.sample(at: 10.08)
        XCTAssertEqual(start.panelFrame, interrupted.panelFrame)
        XCTAssertEqual(start.opacity, interrupted.opacity)
        XCTAssertEqual(start.revealPadding, interrupted.revealPadding)
        let end = collapse.sample(at: 11)
        XCTAssertEqual(end.panelFrame, expansion.startPanelFrame)
        XCTAssertEqual(end.opacity, 0, accuracy: 0.0001)
        XCTAssertEqual(end.revealPadding, 0, accuracy: 0.0001)
        XCTAssertTrue(end.isComplete)
    }

    private func transition(isEnabling: Bool) -> CaptureBackdropTransition {
        CaptureBackdropTransition(
            startTime: 10,
            startPanelFrame: CGRect(x: 288, y: 188, width: 324, height: 144),
            endPanelFrame: CGRect(x: 220, y: 120, width: 460, height: 280),
            startOpacity: 0,
            endOpacity: 1,
            startRevealPadding: 0,
            endRevealPadding: 80,
            isEnabling: isEnabling,
            canvasScreenOrigin: CGPoint(x: 300, y: 200)
        )
    }
}
