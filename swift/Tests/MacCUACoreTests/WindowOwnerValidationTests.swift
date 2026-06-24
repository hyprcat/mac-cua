import XCTest
@testable import MacCUACore

/// Fake lookups: each operation returns a fixed scripted result (`nil` models an
/// absent SPI / CGS error → the assume-valid signal).
private struct FakeLookups: WindowOwnerLookups {
    var isAvailable: Bool = true
    var ownerCid: UInt32? = nil
    var cidForPid: UInt32? = nil
    var pidForCid: Int32? = nil

    func windowOwnerConnectionId(windowId: UInt32) -> UInt32? { ownerCid }
    func connectionId(forPid pid: Int32) -> UInt32? { cidForPid }
    func pid(forConnectionId connectionId: UInt32) -> Int32? { pidForCid }
}

final class WindowOwnerValidationTests: XCTestCase {
    private func validate(_ l: FakeLookups, win: UInt32 = 11, pid: Int32 = 500) -> Bool {
        WindowOwnerValidator.validate(windowId: win, expectedPid: pid, lookups: l)
    }

    // MARK: - assume-valid fallbacks (Invariant 19 — never block an action)

    func testUnavailableAssumesValid() {
        var l = FakeLookups(); l.isAvailable = false
        // Even with a mismatch scripted, unavailable short-circuits to valid.
        l.ownerCid = 1; l.cidForPid = 2
        XCTAssertTrue(validate(l))
    }

    func testOwnerLookupFailureAssumesValid() {
        var l = FakeLookups(); l.ownerCid = nil; l.cidForPid = 99
        XCTAssertTrue(validate(l))
    }

    func testNeitherStrategyRunsAssumesValid() {
        var l = FakeLookups(); l.ownerCid = 7; l.cidForPid = nil; l.pidForCid = nil
        XCTAssertTrue(validate(l))
    }

    // MARK: - Strategy 1 (pre-26): compare connection ids

    func testStrategy1MatchValid() {
        var l = FakeLookups(); l.ownerCid = 42; l.cidForPid = 42
        XCTAssertTrue(validate(l))
    }

    func testStrategy1MismatchInvalid() {
        var l = FakeLookups(); l.ownerCid = 42; l.cidForPid = 7
        // Strategy 2 would say valid, but Strategy 1 wins when its lookup succeeds.
        l.pidForCid = 500
        XCTAssertFalse(validate(l, pid: 500))
    }

    // MARK: - Strategy 2 (26+): reverse owner cid → pid

    func testStrategy2MatchValid() {
        var l = FakeLookups(); l.ownerCid = 9; l.cidForPid = nil; l.pidForCid = 500
        XCTAssertTrue(validate(l, pid: 500))
    }

    func testStrategy2MismatchInvalid() {
        var l = FakeLookups(); l.ownerCid = 9; l.cidForPid = nil; l.pidForCid = 999
        XCTAssertFalse(validate(l, pid: 500))
    }

    func testStrategy1TakesPrecedenceOverStrategy2() {
        // When CGSGetConnectionIDForPID is available, Strategy 2 is never consulted.
        var l = FakeLookups(); l.ownerCid = 1; l.cidForPid = 1; l.pidForCid = 999
        XCTAssertTrue(validate(l, pid: 500))
    }
}
