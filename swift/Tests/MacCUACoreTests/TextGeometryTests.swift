import XCTest
@testable import MacCUACore

final class TextGeometryTests: XCTestCase {

    private final class FakeRef: AXElementRef {}

    private final class FakeGeomReader: TextGeometryReader {
        var bounds: Rect?
        var rangeAtPoint: MacCUACore.TextRange?
        var visible: MacCUACore.TextRange?
        var length: Int?
        var lastBoundsQuery: MacCUACore.TextRange?

        func boundsForRange(_ element: AXElementRef, range: MacCUACore.TextRange) -> Rect? {
            lastBoundsQuery = range
            return bounds
        }
        func rangeForPosition(_ element: AXElementRef, x: Double, y: Double) -> MacCUACore.TextRange? {
            rangeAtPoint
        }
        func visibleCharacterRange(_ element: AXElementRef) -> MacCUACore.TextRange? { visible }
        func textLength(_ element: AXElementRef) -> Int? { length }
    }

    // MARK: isValid

    func testIsValid() {
        XCTAssertTrue(TextGeometryLogic.isValid(range: MacCUACore.TextRange(location: 0, length: 5), textLength: 10))
        XCTAssertTrue(TextGeometryLogic.isValid(range: MacCUACore.TextRange(location: 10, length: 0), textLength: 10)) // caret at end
        XCTAssertFalse(TextGeometryLogic.isValid(range: MacCUACore.TextRange(location: 8, length: 5), textLength: 10))
        XCTAssertFalse(TextGeometryLogic.isValid(range: MacCUACore.TextRange(location: -1, length: 2), textLength: 10))
        XCTAssertFalse(TextGeometryLogic.isValid(range: MacCUACore.TextRange(location: 0, length: -2), textLength: 10))
    }

    // MARK: clampToVisible

    func testClampFullyVisible() {
        let r = TextGeometryLogic.clampToVisible(
            MacCUACore.TextRange(location: 5, length: 3), visible: MacCUACore.TextRange(location: 0, length: 20))
        XCTAssertEqual(r, MacCUACore.TextRange(location: 5, length: 3))
    }

    func testClampPartialOverlap() {
        let r = TextGeometryLogic.clampToVisible(
            MacCUACore.TextRange(location: 5, length: 10), visible: MacCUACore.TextRange(location: 8, length: 20))
        XCTAssertEqual(r, MacCUACore.TextRange(location: 8, length: 7)) // 5..15 clipped to 8..15
    }

    func testClampNoOverlap() {
        XCTAssertNil(TextGeometryLogic.clampToVisible(
            MacCUACore.TextRange(location: 0, length: 3), visible: MacCUACore.TextRange(location: 10, length: 5)))
    }

    func testClampCaretAtVisibleBoundaryIsVisible() {
        // zero-length caret exactly at visible start
        let r = TextGeometryLogic.clampToVisible(
            MacCUACore.TextRange(location: 10, length: 0), visible: MacCUACore.TextRange(location: 10, length: 5))
        XCTAssertEqual(r, MacCUACore.TextRange(location: 10, length: 0))
    }

    func testClampNonZeroAtBoundaryNotVisible() {
        XCTAssertNil(TextGeometryLogic.clampToVisible(
            MacCUACore.TextRange(location: 15, length: 3), visible: MacCUACore.TextRange(location: 10, length: 5)))
    }

    // MARK: unionBounds

    func testUnionBoundsEmpty() {
        XCTAssertNil(TextGeometryLogic.unionBounds([]))
    }

    func testUnionBoundsSingle() {
        XCTAssertEqual(TextGeometryLogic.unionBounds([Rect(x: 1, y: 2, w: 3, h: 4)]),
                       Rect(x: 1, y: 2, w: 3, h: 4))
    }

    func testUnionBoundsMultiLine() {
        let r = TextGeometryLogic.unionBounds([
            Rect(x: 10, y: 10, w: 100, h: 20),
            Rect(x: 5, y: 30, w: 60, h: 20),
        ])
        XCTAssertEqual(r, Rect(x: 5, y: 10, w: 105, h: 40)) // minX5 minY10 maxX110 maxY50
    }

    // MARK: resolveBounds

    func testResolveBoundsHappyPath() {
        let reader = FakeGeomReader()
        reader.length = 100
        reader.visible = MacCUACore.TextRange(location: 0, length: 100)
        reader.bounds = Rect(x: 50, y: 60, w: 30, h: 14)
        let res = TextGeometryLogic.resolveBounds(
            element: FakeRef(), range: MacCUACore.TextRange(location: 5, length: 4), reader: reader)
        XCTAssertEqual(res, .resolved(Rect(x: 50, y: 60, w: 30, h: 14), clamped: false))
        XCTAssertEqual(reader.lastBoundsQuery, MacCUACore.TextRange(location: 5, length: 4))
    }

    func testResolveBoundsInvalidRange() {
        let reader = FakeGeomReader()
        reader.length = 10
        let res = TextGeometryLogic.resolveBounds(
            element: FakeRef(), range: MacCUACore.TextRange(location: 8, length: 5), reader: reader)
        XCTAssertEqual(res, .invalidRange)
    }

    func testResolveBoundsOffscreen() {
        let reader = FakeGeomReader()
        reader.length = 100
        reader.visible = MacCUACore.TextRange(location: 50, length: 20)
        let res = TextGeometryLogic.resolveBounds(
            element: FakeRef(), range: MacCUACore.TextRange(location: 0, length: 10), reader: reader)
        XCTAssertEqual(res, .offscreen)
    }

    func testResolveBoundsClampedFlag() {
        let reader = FakeGeomReader()
        reader.length = 100
        reader.visible = MacCUACore.TextRange(location: 10, length: 80)
        reader.bounds = Rect(x: 1, y: 1, w: 2, h: 2)
        let res = TextGeometryLogic.resolveBounds(
            element: FakeRef(), range: MacCUACore.TextRange(location: 5, length: 20), reader: reader)
        XCTAssertEqual(res, .resolved(Rect(x: 1, y: 1, w: 2, h: 2), clamped: true))
        XCTAssertEqual(reader.lastBoundsQuery, MacCUACore.TextRange(location: 10, length: 15)) // 5..25 clipped 10..25
    }

    func testResolveBoundsUnavailable() {
        let reader = FakeGeomReader()
        reader.length = 100
        reader.visible = MacCUACore.TextRange(location: 0, length: 100)
        reader.bounds = nil // element exposes no bounds
        let res = TextGeometryLogic.resolveBounds(
            element: FakeRef(), range: MacCUACore.TextRange(location: 5, length: 4), reader: reader)
        XCTAssertEqual(res, .unavailable)
    }

    func testResolveBoundsNoVisibleRangeSkipsClamp() {
        let reader = FakeGeomReader()
        reader.length = nil   // unknown length -> no validation
        reader.visible = nil  // unknown visible range -> no clamp
        reader.bounds = Rect(x: 9, y: 9, w: 1, h: 1)
        let res = TextGeometryLogic.resolveBounds(
            element: FakeRef(), range: MacCUACore.TextRange(location: 1000, length: 5), reader: reader)
        XCTAssertEqual(res, .resolved(Rect(x: 9, y: 9, w: 1, h: 1), clamped: false))
        XCTAssertEqual(reader.lastBoundsQuery, MacCUACore.TextRange(location: 1000, length: 5))
    }
}
