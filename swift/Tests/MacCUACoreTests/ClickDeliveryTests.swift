import XCTest
@testable import MacCUACore

final class ClickDeliveryTests: XCTestCase {
    func testSingleClickIsDownThenUp() {
        let steps = ClickDelivery.sequence(count: 1)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0], ClickEventStep(phase: .down, clickState: 1, pressure: 1.0))
        XCTAssertEqual(steps[1], ClickEventStep(phase: .up, clickState: 1, pressure: 0.0))
    }

    func testDoubleClickHasIncreasingClickState() {
        let steps = ClickDelivery.sequence(count: 2)
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.map { $0.phase }, [.down, .up, .down, .up])
        XCTAssertEqual(steps.map { $0.clickState }, [1, 1, 2, 2])
    }

    func testTripleClickStates() {
        let steps = ClickDelivery.sequence(count: 3)
        XCTAssertEqual(steps.count, 6)
        XCTAssertEqual(steps.map { $0.clickState }, [1, 1, 2, 2, 3, 3])
    }

    func testNonPositiveCountClampsToSingleClick() {
        XCTAssertEqual(ClickDelivery.sequence(count: 0), ClickDelivery.sequence(count: 1))
        XCTAssertEqual(ClickDelivery.sequence(count: -5), ClickDelivery.sequence(count: 1))
    }

    func testPressureIsFullOnDownZeroOnUp() {
        for step in ClickDelivery.sequence(count: 2) {
            XCTAssertEqual(step.pressure, step.phase == .down ? 1.0 : 0.0)
        }
    }
}

final class WindowLocalPointTests: XCTestCase {
    func testNoScreenshotSizeIsIdentityLocal() {
        let bounds = Rect(x: 100, y: 200, w: 800, h: 600)
        let p = InputCoords.windowLocalPoint(
            windowBounds: bounds, x: 40, y: 50, screenshotSize: nil)
        XCTAssertEqual(p.x, 40, accuracy: 0.001)
        XCTAssertEqual(p.y, 50, accuracy: 0.001)
    }

    func testDownscaledScreenshotScalesToWindowPoints() {
        // Window is 800x600 points; screenshot was captured at 400x300 (0.5x).
        let bounds = Rect(x: 0, y: 0, w: 800, h: 600)
        let p = InputCoords.windowLocalPoint(
            windowBounds: bounds, x: 100, y: 150, screenshotSize: (width: 400, height: 300))
        XCTAssertEqual(p.x, 200, accuracy: 0.001)
        XCTAssertEqual(p.y, 300, accuracy: 0.001)
    }

    func testLocalPointHasNoWindowOriginOffset() {
        // Differs from windowToScreenCoords by exactly the window origin.
        let bounds = Rect(x: 100, y: 200, w: 800, h: 600)
        let local = InputCoords.windowLocalPoint(
            windowBounds: bounds, x: 40, y: 50, screenshotSize: nil)
        let screen = InputCoords.windowToScreenCoords(
            windowBounds: bounds, x: 40, y: 50, screenshotSize: nil)
        XCTAssertEqual(screen.x - local.x, bounds.x, accuracy: 0.001)
        XCTAssertEqual(screen.y - local.y, bounds.y, accuracy: 0.001)
    }
}
