import XCTest
@testable import MacCUACore

final class OutcomeVerificationTests: XCTestCase {
    // MARK: - CGEventSequenceExpectation.matches

    func testEmptyExpectationAlwaysMatches() {
        XCTAssertTrue(CGEventSequenceExpectation([]).matches([]))
        XCTAssertTrue(CGEventSequenceExpectation([]).matches([1, 2, 3]))
    }

    func testOrderedMatchInSequence() {
        let exp = CGEventSequenceExpectation([1, 2], ordered: true)
        XCTAssertTrue(exp.matches([1, 2]))
        XCTAssertTrue(exp.matches([5, 1, 5, 2, 5]))  // interleaved noise ok, order kept
        XCTAssertFalse(exp.matches([2, 1]))          // wrong order
        XCTAssertFalse(exp.matches([1]))             // incomplete
    }

    func testOrderedWithMinimumMatches() {
        // Needs full ordered run AND >= minimumMatches consumed.
        let exp = CGEventSequenceExpectation([10, 11], ordered: true, minimumMatches: 2)
        XCTAssertTrue(exp.matches([10, 11]))
        XCTAssertFalse(exp.matches([11]))
    }

    func testUnorderedCountsMembership() {
        let exp = CGEventSequenceExpectation([10, 11], ordered: false, minimumMatches: 2)
        XCTAssertTrue(exp.matches([10, 10]))   // 2 members, order irrelevant
        XCTAssertTrue(exp.matches([11, 10]))
        XCTAssertFalse(exp.matches([10]))      // only 1
        XCTAssertFalse(exp.matches([5, 6]))    // none
    }

    func testUnorderedDefaultRequiresAllTypesCount() {
        let exp = CGEventSequenceExpectation([1, 2, 3], ordered: false)
        XCTAssertTrue(exp.matches([3, 2, 1]))
        XCTAssertFalse(exp.matches([1, 2]))
    }

    // MARK: - CGEventHistory

    func testHistoryMarkAndHasEventsSince() {
        let h = CGEventHistory()
        let m0 = h.mark()
        XCTAssertEqual(m0, 0)
        XCTAssertFalse(h.hasEventsSince(m0))
        h.record(eventType: CGEventTypeNumber.leftMouseDown)
        XCTAssertTrue(h.hasEventsSince(m0))
        let m1 = h.mark()
        XCTAssertFalse(h.hasEventsSince(m1))  // nothing new since latest mark
        h.record(eventType: CGEventTypeNumber.leftMouseUp)
        XCTAssertTrue(h.hasEventsSince(m1))
    }

    func testEventsSinceWindowsByMark() {
        let h = CGEventHistory()
        h.record(eventType: 1)
        let m = h.mark()
        h.record(eventType: 2)
        h.record(eventType: 3)
        XCTAssertEqual(h.eventsSince(m).map { $0.eventType }, [2, 3])
        XCTAssertEqual(h.eventsSince(0).count, 3)
    }

    func testHistoryRingBufferEvicts() {
        let h = CGEventHistory(historyLimit: 2)
        h.record(eventType: 1)
        h.record(eventType: 2)
        h.record(eventType: 3)
        // Oldest evicted, but sequence numbering is preserved (monotonic).
        let all = h.eventsSince(0)
        XCTAssertEqual(all.map { $0.eventType }, [2, 3])
        XCTAssertEqual(all.map { $0.sequence }, [2, 3])
    }

    func testHistoryMatchesExpectation() {
        let h = CGEventHistory()
        let m = h.mark()
        h.record(eventType: CGEventTypeNumber.leftMouseDown)
        h.record(eventType: CGEventTypeNumber.leftMouseUp)
        XCTAssertTrue(h.matches(since: m, expectation: CGEventExpectations.click(button: "left", count: 1)))
        XCTAssertFalse(h.matches(since: m, expectation: CGEventExpectations.scroll()))
    }

    func testHistoryClearResetsSequence() {
        let h = CGEventHistory()
        h.record(eventType: 1)
        h.clear()
        XCTAssertEqual(h.mark(), 0)
        XCTAssertFalse(h.hasEventsSince(0))
    }

    // MARK: - Expectation builders

    func testClickExpectationDoubleClick() {
        let exp = CGEventExpectations.click(button: "left", count: 2)
        XCTAssertEqual(exp.eventTypes, [1, 2, 1, 2])
        XCTAssertTrue(exp.matches([1, 2, 1, 2]))
    }

    func testRightClickExpectation() {
        let exp = CGEventExpectations.click(button: "right", count: 1)
        XCTAssertEqual(exp.eventTypes, [3, 4])
    }

    func testClickCountClampsToOne() {
        XCTAssertEqual(CGEventExpectations.click(button: "left", count: 0).eventTypes, [1, 2])
    }

    func testDragKeypressTypingScrollBuilders() {
        XCTAssertEqual(CGEventExpectations.drag().eventTypes, [1, 6, 2])
        XCTAssertEqual(CGEventExpectations.keypress().eventTypes, [10, 11])
        let typing = CGEventExpectations.typing()
        XCTAssertFalse(typing.ordered)
        XCTAssertEqual(typing.minimumMatches, 2)
        XCTAssertEqual(CGEventExpectations.scroll().eventTypes, [22])
    }

    func testSourceStateIDFieldMatchesTable() {
        XCTAssertEqual(kCGEventSourceStateIDField, 45)
        XCTAssertEqual(kCGEventSourceStateIDField, CGEventFieldNumber.eventSourceStateID)
    }

    func testAllInputEventsCoverDeliveryTypes() {
        XCTAssertTrue(CGEventTypeNumber.allInputEvents.contains(CGEventTypeNumber.keyDown))
        XCTAssertTrue(CGEventTypeNumber.allInputEvents.contains(CGEventTypeNumber.scrollWheel))
        XCTAssertFalse(CGEventTypeNumber.allInputEvents.contains(CGEventTypeNumber.null))
    }
}
