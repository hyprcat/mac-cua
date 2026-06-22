import XCTest
@testable import MacCUACore

// Ports tests/test_confirmed_verification.py — covers every StateDiff branch and
// every DeliveryVerdict branch of ActionVerifier.computeVerdict.
final class VerdictTests: XCTestCase {

    // MARK: - ElementSnapshot.diff

    func testDiffDetectsValueChange() {
        let before = ElementSnapshot(value: "old", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let after = ElementSnapshot(value: "new", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let diff = before.diff(after)
        XCTAssertTrue(diff.valueChanged)
        XCTAssertFalse(diff.selectionChanged)
        XCTAssertFalse(diff.focusChanged)
    }

    func testDiffDetectsSelectionChange() {
        let before = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let after = ElementSnapshot(value: "x", selected: true, focusedElementId: 1, menuOpen: false, childCount: 3)
        let diff = before.diff(after)
        XCTAssertTrue(diff.selectionChanged)
        XCTAssertFalse(diff.valueChanged)
    }

    func testDiffDetectsFocusChange() {
        let before = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let after = ElementSnapshot(value: "x", selected: false, focusedElementId: 2, menuOpen: false, childCount: 3)
        let diff = before.diff(after)
        XCTAssertTrue(diff.focusChanged)
    }

    func testDiffDetectsMenuToggle() {
        let before = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let after = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: true, childCount: 3)
        let diff = before.diff(after)
        XCTAssertTrue(diff.menuToggled)
    }

    func testDiffDetectsLayoutChange() {
        let before = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let after = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: false, childCount: 5)
        let diff = before.diff(after)
        XCTAssertTrue(diff.layoutChanged)
    }

    func testDiffNoChanges() {
        let snap = ElementSnapshot(value: "x", selected: false, focusedElementId: 1, menuOpen: false, childCount: 3)
        let diff = snap.diff(snap)
        XCTAssertFalse(diff.anyChanged)
    }

    // MARK: - ActionVerifier.computeVerdict

    func testTransportConfirmedAndSemanticConfirmed() {
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            diffAnyChanged: true,
            expected: .focusOrLayout,
            fallbackUsed: false
        )
        XCTAssertEqual(verdict, .confirmed)
    }

    func testTransportConfirmedNoSemanticChange() {
        // The heart of "transport ≠ outcome": confirmed delivery + no UI diff is
        // DELIVERED_NO_EFFECT, not a failure.
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            diffAnyChanged: false,
            expected: .focusOrLayout,
            fallbackUsed: false
        )
        XCTAssertEqual(verdict, .deliveredNoEffect)
    }

    func testTransportFailed() {
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: false,
            diffAnyChanged: false,
            expected: .focusOrLayout,
            fallbackUsed: false
        )
        XCTAssertEqual(verdict, .transportFailed)
    }

    func testFallbackConfirmed() {
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            diffAnyChanged: true,
            expected: .focusOrLayout,
            fallbackUsed: true
        )
        XCTAssertEqual(verdict, .confirmedViaFallback)
    }

    func testTransportOnlyForScroll() {
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            diffAnyChanged: false,
            expected: .transportOnly,
            fallbackUsed: false
        )
        XCTAssertEqual(verdict, .confirmed)
    }

    // Transport-failure dominates even a transportOnly expectation: no transport,
    // no confirmation. (Guards the check ordering in computeVerdict.)
    func testTransportFailedBeatsTransportOnly() {
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: false,
            diffAnyChanged: false,
            expected: .transportOnly,
            fallbackUsed: true
        )
        XCTAssertEqual(verdict, .transportFailed)
    }

    // transportOnly ignores fallbackUsed — it short-circuits to plain confirmed
    // before the fallback branch is reached.
    func testTransportOnlyIgnoresFallback() {
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            diffAnyChanged: true,
            expected: .transportOnly,
            fallbackUsed: true
        )
        XCTAssertEqual(verdict, .confirmed)
    }

    // MARK: - Enum raw values match Python wire strings

    func testVerdictRawValuesMatchPython() {
        XCTAssertEqual(DeliveryVerdict.confirmed.rawValue, "confirmed")
        XCTAssertEqual(DeliveryVerdict.confirmedViaFallback.rawValue, "confirmed_via_fallback")
        XCTAssertEqual(DeliveryVerdict.deliveredNoEffect.rawValue, "delivered_no_effect")
        XCTAssertEqual(DeliveryVerdict.transportFailed.rawValue, "transport_failed")
    }

    func testExpectedDiffRawValuesMatchPython() {
        XCTAssertEqual(ExpectedDiff.focusOrLayout.rawValue, "focus_or_layout")
        XCTAssertEqual(ExpectedDiff.selectionChanged.rawValue, "selection_changed")
        XCTAssertEqual(ExpectedDiff.valueChanged.rawValue, "value_changed")
        XCTAssertEqual(ExpectedDiff.layoutOrMenu.rawValue, "layout_or_menu")
        XCTAssertEqual(ExpectedDiff.menuToggled.rawValue, "menu_toggled")
        XCTAssertEqual(ExpectedDiff.actionDependent.rawValue, "action_dependent")
        XCTAssertEqual(ExpectedDiff.transportOnly.rawValue, "transport_only")
    }
}
