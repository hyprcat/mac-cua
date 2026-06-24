import XCTest
@testable import MacCUACore

final class InputCoordsTests: XCTestCase {
    // MARK: - windowToScreenCoords

    func testNoScreenshotSizeIsOffsetOnly() {
        let b = Rect(x: 100, y: 200, w: 800, h: 600)
        let p = InputCoords.windowToScreenCoords(windowBounds: b, x: 10, y: 20, screenshotSize: nil)
        XCTAssertEqual(p.x, 110, accuracy: 1e-9)
        XCTAssertEqual(p.y, 220, accuracy: 1e-9)
    }

    func testScreenshotScaleUp() {
        // window 800x600, screenshot 400x300 (2x downscaled) -> click at (100,75)
        // scales to (200,150) then + origin.
        let b = Rect(x: 0, y: 0, w: 800, h: 600)
        let p = InputCoords.windowToScreenCoords(windowBounds: b, x: 100, y: 75,
                                                 screenshotSize: (width: 400, height: 300))
        XCTAssertEqual(p.x, 200, accuracy: 1e-9)
        XCTAssertEqual(p.y, 150, accuracy: 1e-9)
    }

    func testScreenshotClampsToBounds() {
        let b = Rect(x: 0, y: 0, w: 400, h: 300)
        // x beyond shot width clamps to shotW-1 = 399, scaled by 400/400 = 1.0
        let p = InputCoords.windowToScreenCoords(windowBounds: b, x: 9999, y: -50,
                                                 screenshotSize: (width: 400, height: 300))
        XCTAssertEqual(p.x, 399, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0, accuracy: 1e-9)
    }

    func testZeroScreenshotSizeIgnored() {
        let b = Rect(x: 5, y: 5, w: 100, h: 100)
        let p = InputCoords.windowToScreenCoords(windowBounds: b, x: 50, y: 50,
                                                 screenshotSize: (width: 0, height: 0))
        XCTAssertEqual(p.x, 55, accuracy: 1e-9)
        XCTAssertEqual(p.y, 55, accuracy: 1e-9)
    }

    // MARK: - scroll deltas

    func testLineScrollDeltas() {
        XCTAssertEqual(InputCoords.lineScrollDeltas(direction: "up").dy, 5)
        XCTAssertEqual(InputCoords.lineScrollDeltas(direction: "down").dy, -5)
        XCTAssertEqual(InputCoords.lineScrollDeltas(direction: "left").dx, 5)
        XCTAssertEqual(InputCoords.lineScrollDeltas(direction: "right").dx, -5)
        XCTAssertEqual(InputCoords.lineScrollDeltas(direction: "bogus").dy, 0)
    }

    func testPixelScrollDeltas() {
        XCTAssertEqual(InputCoords.pixelScrollDeltas(direction: "up", pixels: 80).dy, 80)
        XCTAssertEqual(InputCoords.pixelScrollDeltas(direction: "down", pixels: 80).dy, -80)
        XCTAssertEqual(InputCoords.pixelScrollDeltas(direction: "left", pixels: 80).dx, 80)
        XCTAssertEqual(InputCoords.pixelScrollDeltas(direction: "right", pixels: 80).dx, -80)
        XCTAssertEqual(InputCoords.pixelScrollDeltas(direction: "x", pixels: 80).dy, 0)
    }

    func testPixelScrollFieldsSetsEveryAxis() {
        // 160px down → 2 wheel clicks; all delta families populated, isContinuous=1.
        let f = InputCoords.pixelScrollFields(direction: "down", pixels: 160)
        XCTAssertEqual(f.pointDy, -160)       // Chromium integer point delta
        XCTAssertEqual(f.pointDx, 0)
        XCTAssertEqual(f.fixedDy, -160.0)     // native Cocoa fixed-point delta
        XCTAssertEqual(f.fixedDx, 0.0)
        XCTAssertEqual(f.lineDy, -10)         // 2 clicks × ±5 line delta, sign preserved
        XCTAssertEqual(f.lineDx, 0)
        XCTAssertEqual(f.isContinuous, 1)
        // Not integer-only: at least the line, fixedPt, and point families all set.
        XCTAssertNotEqual(f.fixedDy, 0.0)
        XCTAssertNotEqual(f.lineDy, 0)
    }

    func testPixelScrollFieldsDirections() {
        XCTAssertEqual(InputCoords.pixelScrollFields(direction: "up", pixels: 80).pointDy, 80)
        XCTAssertEqual(InputCoords.pixelScrollFields(direction: "up", pixels: 80).lineDy, 5)
        XCTAssertEqual(InputCoords.pixelScrollFields(direction: "left", pixels: 80).pointDx, 80)
        XCTAssertEqual(InputCoords.pixelScrollFields(direction: "left", pixels: 80).lineDx, 5)
        XCTAssertEqual(InputCoords.pixelScrollFields(direction: "right", pixels: 240).lineDx, -15)
    }

    func testPixelScrollFieldsFloorsAtOneClickAndZeroesBogus() {
        // < one quantum still produces one line click in the scroll direction.
        let small = InputCoords.pixelScrollFields(direction: "down", pixels: 10)
        XCTAssertEqual(small.lineDy, -5)
        XCTAssertEqual(small.pointDy, -10)
        // Bogus direction → all deltas zero (still a well-formed, no-op event).
        let bogus = InputCoords.pixelScrollFields(direction: "x", pixels: 80)
        XCTAssertEqual(bogus.lineDy, 0)
        XCTAssertEqual(bogus.lineDx, 0)
        XCTAssertEqual(bogus.pointDy, 0)
        XCTAssertEqual(bogus.fixedDy, 0.0)
        XCTAssertEqual(bogus.isContinuous, 1)
    }

    // MARK: - button table

    func testMouseButtonMapping() {
        XCTAssertEqual(MouseButton(name: "left")?.buttonNumber, 0)
        XCTAssertEqual(MouseButton(name: "right")?.buttonNumber, 1)
        XCTAssertEqual(MouseButton(name: "middle")?.buttonNumber, 2)
        XCTAssertNil(MouseButton(name: "wheel"))
    }

    // MARK: - coerceTextKey

    func testCoerceTextKeyLiterals() {
        XCTAssertEqual(InputCoords.coerceTextKey("a"), "a")
        XCTAssertEqual(InputCoords.coerceTextKey("Z"), "Z")
        XCTAssertEqual(InputCoords.coerceTextKey("5"), "5")
        XCTAssertEqual(InputCoords.coerceTextKey(" "), " ")
    }

    func testCoerceTextKeyComboIsNil() {
        XCTAssertNil(InputCoords.coerceTextKey("cmd+a"))
    }

    func testCoerceTextKeyAliases() {
        XCTAssertEqual(InputCoords.coerceTextKey("apostrophe"), "'")
        XCTAssertEqual(InputCoords.coerceTextKey("backslash"), "\\")
        XCTAssertEqual(InputCoords.coerceTextKey("SLASH"), "/")
        XCTAssertEqual(InputCoords.coerceTextKey("period"), ".")
    }

    func testCoerceTextKeyNamedKeyFallsThrough() {
        // Named keys that are not aliases (e.g. "space", "return") return nil so
        // the caller resolves them via parseKeyCombo.
        XCTAssertNil(InputCoords.coerceTextKey("space"))
        XCTAssertNil(InputCoords.coerceTextKey("return"))
        XCTAssertNil(InputCoords.coerceTextKey("\t"))
    }
}
