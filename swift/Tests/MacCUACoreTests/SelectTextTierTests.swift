import XCTest
@testable import MacCUACore

// Pure tier-selection logic for the `select_text` Mac impl (US-040, design D1).
// Verifies SelectTextTierDecider.decide / isWebAreaRole / markerEndpoints. The
// real macOS apply (CFRange vs AXTextMarker) is fake-unverifiable on Linux and is
// covered by the MANUAL-VERIFY backlog; this asserts the pure branch logic.
final class SelectTextTierTests: XCTestCase {
    private func facts(
        settable: Bool = false, markers: Bool = false, web: Bool = false
    ) -> SelectTextElementFacts {
        SelectTextElementFacts(
            selectedTextRangeSettable: settable, supportsTextMarkers: markers, isWebArea: web)
    }

    func testWebAreaAlwaysTextMarkerEvenIfRangeSettable() {
        // A web area takes Tier 2 even when it (mis)reports a settable CFRange.
        XCTAssertEqual(SelectTextTierDecider.decide(facts(settable: true, web: true)), .textMarker)
        XCTAssertEqual(SelectTextTierDecider.decide(facts(markers: true, web: true)), .textMarker)
    }

    func testSettableSimpleFieldIsCFRange() {
        XCTAssertEqual(SelectTextTierDecider.decide(facts(settable: true)), .cfRange)
    }

    func testNonSettableButMarkersIsTextMarker() {
        XCTAssertEqual(SelectTextTierDecider.decide(facts(settable: false, markers: true)), .textMarker)
    }

    func testDefaultBestEffortIsCFRange() {
        // Nothing known settable/markers/web → best-effort Tier 1.
        XCTAssertEqual(SelectTextTierDecider.decide(facts()), .cfRange)
    }

    func testSettableWinsOverMarkersForNonWeb() {
        // A simple field that also vends markers prefers the reliable CFRange.
        XCTAssertEqual(SelectTextTierDecider.decide(facts(settable: true, markers: true)), .cfRange)
    }

    func testIsWebAreaRole() {
        XCTAssertTrue(SelectTextTierDecider.isWebAreaRole("AXWebArea"))
        XCTAssertFalse(SelectTextTierDecider.isWebAreaRole("AXTextField"))
        XCTAssertFalse(SelectTextTierDecider.isWebAreaRole("AXTextArea"))
        XCTAssertFalse(SelectTextTierDecider.isWebAreaRole(nil))
    }

    func testMarkerEndpoints() {
        let sel = SelectTextTierDecider.markerEndpoints(for: TextRange(location: 5, length: 3))
        XCTAssertEqual(sel.start, 5)
        XCTAssertEqual(sel.end, 8)
        // Zero-length caret → start == end.
        let caret = SelectTextTierDecider.markerEndpoints(for: TextRange(location: 7, length: 0))
        XCTAssertEqual(caret.start, 7)
        XCTAssertEqual(caret.end, 7)
    }
}
