import XCTest
@testable import MacCUACore

/// US-003 — tree-wide change summary (E3) + verdict consuming it.
final class ChangeSummaryTests: XCTestCase {
    private func node(
        _ index: Int,
        role: String = "AXButton",
        label: String? = nil,
        value: String? = nil,
        states: [String] = [],
        axId: String? = nil,
        locator: GraphLocator? = nil
    ) -> Node {
        Node(
            index: index,
            role: role,
            label: label,
            states: states,
            value: value,
            axId: axId,
            depth: 0,
            graphLocator: locator
        )
    }

    private func loc(_ id: String) -> GraphLocator {
        GraphLocator(axRole: "AXButton", label: id, axId: id, depth: 0, siblingOrdinal: 0)
    }

    // MARK: - changeSummary

    func testNoChange() {
        let pre = [node(0, label: "A", axId: "a"), node(1, label: "B", axId: "b")]
        let post = [node(0, label: "A", axId: "a"), node(1, label: "B", axId: "b")]
        let s = TreeDiff.changeSummary(pre: pre, post: post)
        XCTAssertTrue(s.isEmpty)
        XCTAssertEqual(s.totalChanges, 0)
    }

    func testAddedOnly() {
        let pre = [node(0, axId: "a")]
        let post = [node(0, axId: "a"), node(1, axId: "b")]
        let s = TreeDiff.changeSummary(pre: pre, post: post)
        XCTAssertEqual(s.added, ["ax|b"])
        XCTAssertTrue(s.removed.isEmpty)
        XCTAssertTrue(s.changed.isEmpty)
        XCTAssertFalse(s.isEmpty)
    }

    func testRemovedOnly() {
        let pre = [node(0, axId: "a"), node(1, axId: "b")]
        let post = [node(0, axId: "a")]
        let s = TreeDiff.changeSummary(pre: pre, post: post)
        XCTAssertEqual(s.removed, ["ax|b"])
        XCTAssertTrue(s.added.isEmpty)
        XCTAssertTrue(s.changed.isEmpty)
    }

    func testChangedOnly() {
        let pre = [node(0, value: "off", axId: "a")]
        let post = [node(0, value: "on", axId: "a")]
        let s = TreeDiff.changeSummary(pre: pre, post: post)
        XCTAssertEqual(s.changed, ["ax|a"])
        XCTAssertTrue(s.added.isEmpty)
        XCTAssertTrue(s.removed.isEmpty)
    }

    func testStatesChangeMarksChanged() {
        let pre = [node(0, states: ["enabled"], axId: "a")]
        let post = [node(0, states: ["enabled", "selected"], axId: "a")]
        let s = TreeDiff.changeSummary(pre: pre, post: post)
        XCTAssertEqual(s.changed, ["ax|a"])
    }

    func testStateOrderIgnored() {
        let pre = [node(0, states: ["a", "b"], axId: "x")]
        let post = [node(0, states: ["b", "a"], axId: "x")]
        XCTAssertTrue(TreeDiff.changeSummary(pre: pre, post: post).isEmpty)
    }

    func testKeyedByGraphLocatorNotIndex() {
        // Same locator, different preorder index -> matched (not added/removed).
        let pre = [node(0, value: "1", locator: loc("L"))]
        let post = [node(5, value: "1", locator: loc("L"))]
        XCTAssertTrue(TreeDiff.changeSummary(pre: pre, post: post).isEmpty)
    }

    func testMixedAddRemoveChange() {
        let pre = [node(0, value: "x", axId: "a"), node(1, axId: "b")]
        let post = [node(0, value: "y", axId: "a"), node(2, axId: "c")]
        let s = TreeDiff.changeSummary(pre: pre, post: post)
        XCTAssertEqual(s.changed, ["ax|a"])
        XCTAssertEqual(s.removed, ["ax|b"])
        XCTAssertEqual(s.added, ["ax|c"])
        XCTAssertEqual(s.totalChanges, 3)
    }

    // MARK: - computeVerdict overload

    func testVerdictNoTransport() {
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: false,
            changeSummary: ChangeSummary(added: [], removed: [], changed: []),
            expected: .valueChanged,
            fallbackUsed: false)
        XCTAssertEqual(v, .transportFailed)
    }

    func testVerdictTransportConfirmedZeroChange() {
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            changeSummary: ChangeSummary(added: [], removed: [], changed: []),
            expected: .valueChanged,
            fallbackUsed: false)
        XCTAssertEqual(v, .deliveredNoEffect)
    }

    func testVerdictTransportOnlyIgnoresSummary() {
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            changeSummary: ChangeSummary(added: [], removed: [], changed: []),
            expected: .transportOnly,
            fallbackUsed: false)
        XCTAssertEqual(v, .confirmed)
    }

    func testVerdictChangeConfirmed() {
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            changeSummary: ChangeSummary(added: ["x"], removed: [], changed: []),
            expected: .valueChanged,
            fallbackUsed: false)
        XCTAssertEqual(v, .confirmed)
    }

    func testVerdictChangeFallback() {
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: true,
            changeSummary: ChangeSummary(added: [], removed: [], changed: ["x"]),
            expected: .valueChanged,
            fallbackUsed: true)
        XCTAssertEqual(v, .confirmedViaFallback)
    }
}
