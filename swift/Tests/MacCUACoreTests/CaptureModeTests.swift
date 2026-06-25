import XCTest
@testable import MacCUACore

// US-058: capture modes (som/ax/vision) mirroring the upstream cua-driver.
// Pure-Core decision logic: mode → CapturePlan, parsing, and defaults.

final class CaptureModeTests: XCTestCase {

    // MARK: - plan mapping

    func testSomPlanCapturesTreeAndScreenshot() {
        let plan = CaptureMode.som.plan
        XCTAssertTrue(plan.captureTree)
        XCTAssertTrue(plan.captureScreenshot)
    }

    func testAxPlanCapturesTreeOnly() {
        let plan = CaptureMode.ax.plan
        XCTAssertTrue(plan.captureTree)
        XCTAssertFalse(plan.captureScreenshot, "ax must not capture a screenshot (no Screen Recording permission)")
    }

    func testVisionPlanCapturesScreenshotOnly() {
        let plan = CaptureMode.vision.plan
        XCTAssertFalse(plan.captureTree, "vision must not capture the AX tree (no element indices)")
        XCTAssertTrue(plan.captureScreenshot)
    }

    func testEveryModeHasAPlan() {
        // Each mode produces at least one capture artifact; none is a no-op.
        for mode in CaptureMode.allCases {
            let plan = mode.plan
            XCTAssertTrue(plan.captureTree || plan.captureScreenshot, "\(mode) produced an empty plan")
        }
    }

    // MARK: - parse() (case-insensitive, unknown → nil, nil → nil)

    func testParseCaseInsensitive() {
        XCTAssertEqual(CaptureMode.parse("som"), .som)
        XCTAssertEqual(CaptureMode.parse("ax"), .ax)
        XCTAssertEqual(CaptureMode.parse("vision"), .vision)
        XCTAssertEqual(CaptureMode.parse("SOM"), .som)
        XCTAssertEqual(CaptureMode.parse("Ax"), .ax)
        XCTAssertEqual(CaptureMode.parse("Vision"), .vision)
        XCTAssertEqual(CaptureMode.parse("VISION"), .vision)
    }

    func testParseUnknownReturnsNil() {
        XCTAssertNil(CaptureMode.parse("screenshot"))
        XCTAssertNil(CaptureMode.parse(""))
        XCTAssertNil(CaptureMode.parse("som "), "whitespace is not trimmed; unknown → nil")
    }

    func testParseNilReturnsNil() {
        XCTAssertNil(CaptureMode.parse(nil))
    }

    // MARK: - default

    func testDefaultIsSom() {
        XCTAssertEqual(CaptureMode.default, .som)
    }

    // MARK: - rawValue round-trips

    func testRawValueRoundTrips() {
        for mode in CaptureMode.allCases {
            XCTAssertEqual(CaptureMode(rawValue: mode.rawValue), mode)
        }
    }

    func testRawValueStrings() {
        XCTAssertEqual(CaptureMode.som.rawValue, "som")
        XCTAssertEqual(CaptureMode.ax.rawValue, "ax")
        XCTAssertEqual(CaptureMode.vision.rawValue, "vision")
    }
}
