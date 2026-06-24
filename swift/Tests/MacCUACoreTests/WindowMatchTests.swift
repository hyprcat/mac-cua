import XCTest
@testable import MacCUACore

// Pure A4 fallback matcher (US-020). Mirrors screenshot.py scoring; the primary
// `_AXUIElementGetWindow` binding is Kit-only and unit-tested via smoke there.
final class WindowMatchTests: XCTestCase {

    private func win(
        _ id: Int, pid: Int, title: String? = nil,
        x: Double = 0, y: Double = 0, w: Double = 100, h: Double = 100,
        onscreen: Bool = true
    ) -> WindowInfo {
        WindowInfo(windowId: id, ownerPid: pid, ownerName: nil, title: title,
                   x: x, y: y, width: w, height: h, onscreen: onscreen)
    }

    func testExactTitleAndPidWins() {
        let a = win(1, pid: 42, title: "Untitled")
        let b = win(2, pid: 99, title: "Other")
        let sig = AXWindowSignature(title: "Untitled", position: Point(x: 0, y: 0), size: Point(x: 100, y: 100))
        XCTAssertEqual(WindowMatcher.bestMatch(windows: [a, b], layers: [:], signature: sig, pid: 42), 1)
    }

    func testCaseInsensitiveTitleBeatsSubstring() {
        let exactCase = win(1, pid: 0, title: "doc.txt")        // 950 (case-insensitive equal)
        let substring = win(2, pid: 0, title: "my doc.TXT file") // 700 (contains)
        let sig = AXWindowSignature(title: "DOC.TXT")
        XCTAssertEqual(WindowMatcher.bestMatch(windows: [substring, exactCase], layers: [:], signature: sig, pid: 0), 1)
    }

    func testGeometryProximityChoosesClosest() {
        let near = win(1, pid: 7, x: 10, y: 10, w: 100, h: 100)
        let far = win(2, pid: 7, x: 500, y: 500, w: 100, h: 100)
        let sig = AXWindowSignature(position: Point(x: 12, y: 12), size: Point(x: 100, y: 100))
        XCTAssertEqual(WindowMatcher.bestMatch(windows: [far, near], layers: [:], signature: sig, pid: 7), 1)
    }

    func testWindowIdZeroSkipped() {
        let zero = win(0, pid: 42, title: "Untitled")
        XCTAssertNil(WindowMatcher.score(window: zero, layer: 0,
            signature: AXWindowSignature(title: "Untitled"), pid: 42))
    }

    func testNonBaseLayerSkipped() {
        let overlay = win(1, pid: 42, title: "Untitled")
        XCTAssertNil(WindowMatcher.score(window: overlay, layer: 25,
            signature: AXWindowSignature(title: "Untitled"), pid: 42))
    }

    func testEmptySizeSkipped() {
        let degenerate = win(1, pid: 42, title: "X", w: 0, h: 0)
        XCTAssertNil(WindowMatcher.score(window: degenerate, layer: 0,
            signature: AXWindowSignature(title: "X"), pid: 42))
    }

    func testLayerLookupSkipsOverlay() {
        let real = win(1, pid: 5, title: "App")
        let overlay = win(2, pid: 5, title: "App")
        let sig = AXWindowSignature(title: "App")
        // overlay (id 2) is layer 25 → ineligible; real (id 1) chosen.
        let best = WindowMatcher.bestMatch(windows: [overlay, real], layers: [2: 25, 1: 0], signature: sig, pid: 5)
        XCTAssertEqual(best, 1)
    }

    func testNoEligibleReturnsNil() {
        let only = win(0, pid: 1)
        XCTAssertNil(WindowMatcher.bestMatch(windows: [only], layers: [:], signature: AXWindowSignature(), pid: 1))
    }

    func testPidBonusBreaksTie() {
        // No title/geometry signal; only pid distinguishes.
        let mine = win(1, pid: 42)
        let theirs = win(2, pid: 99)
        let best = WindowMatcher.bestMatch(windows: [theirs, mine], layers: [:], signature: AXWindowSignature(), pid: 42)
        XCTAssertEqual(best, 1)
    }

    func testOnscreenAndNamedBonuses() {
        let s = WindowMatcher.score(window: win(1, pid: 7, title: "T", onscreen: true),
                                    layer: 0, signature: AXWindowSignature(), pid: 99)
        // 50 (onscreen) + 10 (has title) = 60, no pid-match/title-match/geometry.
        XCTAssertEqual(s, 60)
    }
}
