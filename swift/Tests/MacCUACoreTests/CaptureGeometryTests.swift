import XCTest
@testable import MacCUACore

final class CaptureGeometryTests: XCTestCase {
    // MARK: - backingScale

    func testBackingScalePicksMostOverlappingScreen() {
        let r1 = ScreenInfo(frame: Rect(x: 0, y: 0, w: 1000, h: 1000), backingScale: 1.0)
        let r2 = ScreenInfo(frame: Rect(x: 1000, y: 0, w: 1000, h: 1000), backingScale: 2.0)
        // Window mostly on the right (Retina) screen.
        let rect = Rect(x: 900, y: 100, w: 400, h: 200) // 100 on left, 300 on right
        XCTAssertEqual(CaptureGeometry.backingScale(forRect: rect, screens: [r1, r2]), 2.0)
    }

    func testBackingScaleFallsBackToMainWhenNoOverlap() {
        let main = ScreenInfo(frame: Rect(x: 0, y: 0, w: 100, h: 100), backingScale: 3.0, isMain: true)
        let other = ScreenInfo(frame: Rect(x: 200, y: 0, w: 100, h: 100), backingScale: 1.0)
        let rect = Rect(x: 5000, y: 5000, w: 10, h: 10) // off all screens
        XCTAssertEqual(CaptureGeometry.backingScale(forRect: rect, screens: [other, main]), 3.0)
    }

    func testBackingScaleFallsBackToDefaultWhenNoScreens() {
        let rect = Rect(x: 0, y: 0, w: 10, h: 10)
        XCTAssertEqual(CaptureGeometry.backingScale(forRect: rect, screens: []), 2.0)
        XCTAssertEqual(CaptureGeometry.backingScale(forRect: rect, screens: [], defaultScale: 1.0), 1.0)
    }

    func testBackingScaleDefaultWhenNoOverlapAndNoMain() {
        let other = ScreenInfo(frame: Rect(x: 200, y: 0, w: 100, h: 100), backingScale: 1.0)
        let rect = Rect(x: 5000, y: 5000, w: 10, h: 10)
        XCTAssertEqual(CaptureGeometry.backingScale(forRect: rect, screens: [other]), 2.0)
    }

    func testIntersectionAreaDisjointIsZero() {
        XCTAssertEqual(CaptureGeometry.intersectionArea(
            Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 100, y: 100, w: 10, h: 10)), 0)
    }

    func testIntersectionAreaOverlap() {
        XCTAssertEqual(CaptureGeometry.intersectionArea(
            Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 5, y: 5, w: 10, h: 10)), 25)
    }

    // MARK: - outputPixelSize

    func testOutputPixelSizeScalesToBacking() {
        let s = CaptureSizing.outputPixelSize(windowSize: Size(w: 800, h: 600), scale: 2.0)
        XCTAssertEqual(s?.width, 1600)
        XCTAssertEqual(s?.height, 1200)
    }

    func testOutputPixelSizeNonRetina() {
        let s = CaptureSizing.outputPixelSize(windowSize: Size(w: 800, h: 600), scale: 1.0)
        XCTAssertEqual(s?.width, 800)
        XCTAssertEqual(s?.height, 600)
    }

    func testOutputPixelSizeInvalidSizeReturnsNil() {
        XCTAssertNil(CaptureSizing.outputPixelSize(windowSize: Size(w: 0, h: 600), scale: 2.0))
        XCTAssertNil(CaptureSizing.outputPixelSize(windowSize: Size(w: 800, h: 0), scale: 2.0))
        XCTAssertNil(CaptureSizing.outputPixelSize(windowSize: Size(w: -5, h: 600), scale: 2.0))
    }

    func testOutputPixelSizeTruncatesLikePython() {
        // int(window) guard floors first; scaled dims floor too.
        let s = CaptureSizing.outputPixelSize(windowSize: Size(w: 100.9, h: 50.5), scale: 1.5)
        XCTAssertEqual(s?.width, Int(100.9 * 1.5)) // 151
        XCTAssertEqual(s?.height, Int(50.5 * 1.5)) // 75
    }
}
