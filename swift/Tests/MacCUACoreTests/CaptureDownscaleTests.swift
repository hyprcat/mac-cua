import XCTest
@testable import MacCUACore

final class CaptureDownscaleTests: XCTestCase {
    // MARK: needsDownscale

    func testFitsNoDownscale() {
        XCTAssertFalse(CaptureDownscale.needsDownscale(width: 1920, height: 1080))
        XCTAssertFalse(CaptureDownscale.needsDownscale(width: 800, height: 600))
    }

    func testExceedsNeedsDownscale() {
        XCTAssertTrue(CaptureDownscale.needsDownscale(width: 3840, height: 2160))
        // tall image: longest side is height
        XCTAssertTrue(CaptureDownscale.needsDownscale(width: 1000, height: 2400))
    }

    func testCustomMaxDimension() {
        XCTAssertTrue(CaptureDownscale.needsDownscale(width: 1000, height: 800, maxDimension: 512))
        XCTAssertFalse(CaptureDownscale.needsDownscale(width: 400, height: 300, maxDimension: 512))
    }

    func testNonPositiveMaxDimensionNeverDownscales() {
        XCTAssertFalse(CaptureDownscale.needsDownscale(width: 5000, height: 5000, maxDimension: 0))
    }

    // MARK: maxPixelSize

    func testMaxPixelSizeNilWhenFits() {
        XCTAssertNil(CaptureDownscale.maxPixelSize(width: 1600, height: 900))
    }

    func testMaxPixelSizeReturnsCapWhenExceeds() {
        XCTAssertEqual(CaptureDownscale.maxPixelSize(width: 4000, height: 2000), 1920)
        XCTAssertEqual(CaptureDownscale.maxPixelSize(width: 100, height: 4000, maxDimension: 512), 512)
    }

    // MARK: scaledSize

    func testScaledSizeUnchangedWhenFits() {
        let s = CaptureDownscale.scaledSize(width: 1920, height: 1080)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }

    func testScaledSizeLandscapeClampsWidth() {
        // 3840x2160 -> longest side 3840, ratio 0.5
        let s = CaptureDownscale.scaledSize(width: 3840, height: 2160)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }

    func testScaledSizePortraitClampsHeight() {
        // 1000x2400 -> longest side 2400, ratio 0.8
        let s = CaptureDownscale.scaledSize(width: 1000, height: 2400)
        XCTAssertEqual(s.height, 1920)
        XCTAssertEqual(s.width, 800)
    }

    func testScaledSizePreservesAspectWithRounding() {
        let s = CaptureDownscale.scaledSize(width: 2000, height: 1333)
        XCTAssertEqual(s.width, 1920)
        // 1333 * (1920/2000) = 1279.68 -> 1280
        XCTAssertEqual(s.height, 1280)
    }

    func testScaledSizeInvalidReturnsInput() {
        let s = CaptureDownscale.scaledSize(width: 0, height: 100)
        XCTAssertEqual(s.width, 0)
        XCTAssertEqual(s.height, 100)
    }

    func testScaledSizeNeverZero() {
        // extreme aspect ratio still floors at 1px on the short side
        let s = CaptureDownscale.scaledSize(width: 5000, height: 2, maxDimension: 1920)
        XCTAssertEqual(s.width, 1920)
        XCTAssertGreaterThanOrEqual(s.height, 1)
    }

    // MARK: CaptureMetadata

    func testCaptureMetadataHoldsProvenance() {
        let m = CaptureMetadata(
            producedWidth: 1920, producedHeight: 1080,
            backingScale: 2.0,
            cropOrigin: Point(x: 100, y: 50),
            windowId: 42, windowTitle: "Doc", displayId: 1
        )
        XCTAssertEqual(m.producedWidth, 1920)
        XCTAssertEqual(m.backingScale, 2.0)
        XCTAssertEqual(m.cropOrigin, Point(x: 100, y: 50))
        XCTAssertEqual(m.windowId, 42)
        XCTAssertEqual(m.windowTitle, "Doc")
        XCTAssertEqual(m.displayId, 1)
    }
}
