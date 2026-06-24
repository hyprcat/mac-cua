import XCTest
@testable import MacCUACore

final class WindowOrderingTests: XCTestCase {
    func testFirstNonEmptySampleReportsChange() {
        var s = WindowOrderingState()
        XCTAssertTrue(s.sample([3, 1, 2]))
        XCTAssertEqual(s.lastOrder, [3, 1, 2])
    }

    func testIdenticalSampleReportsNoChange() {
        var s = WindowOrderingState()
        _ = s.sample([3, 1, 2])
        XCTAssertFalse(s.sample([3, 1, 2]))
        XCTAssertEqual(s.lastOrder, [3, 1, 2])
    }

    func testReorderReportsChange() {
        var s = WindowOrderingState()
        _ = s.sample([3, 1, 2])
        XCTAssertTrue(s.sample([1, 3, 2]))
        XCTAssertEqual(s.lastOrder, [1, 3, 2])
    }

    func testOrderSensitive() {
        // Same set, different order -> change.
        var s = WindowOrderingState()
        _ = s.sample([1, 2])
        XCTAssertTrue(s.sample([2, 1]))
    }

    func testAddedOrRemovedWindowReportsChange() {
        var s = WindowOrderingState()
        _ = s.sample([1, 2])
        XCTAssertTrue(s.sample([1, 2, 3]))   // window opened
        XCTAssertTrue(s.sample([2, 3]))      // window closed
    }

    func testNilSampleIgnored() {
        var s = WindowOrderingState()
        _ = s.sample([1, 2])
        XCTAssertFalse(s.sample(nil))
        XCTAssertEqual(s.lastOrder, [1, 2])  // not clobbered
    }

    func testEmptySampleIgnored() {
        var s = WindowOrderingState()
        _ = s.sample([1, 2])
        XCTAssertFalse(s.sample([]))
        XCTAssertEqual(s.lastOrder, [1, 2])  // not clobbered
    }

    func testFirstNilThenRealSample() {
        var s = WindowOrderingState()
        XCTAssertFalse(s.sample(nil))
        XCTAssertTrue(s.sample([5]))
        XCTAssertEqual(s.lastOrder, [5])
    }

    func testResetClearsState() {
        var s = WindowOrderingState()
        _ = s.sample([1, 2])
        s.reset()
        XCTAssertEqual(s.lastOrder, [])
        // After reset, the same order reports a change again (fresh baseline).
        XCTAssertTrue(s.sample([1, 2]))
    }
}
