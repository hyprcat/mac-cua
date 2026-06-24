import XCTest
@testable import MacCUACore

// US-038: pure staleness classification + liveness-probe verdict.
final class AXStalenessTests: XCTestCase {
    func testStaleActCodesAreExactlyTheFour() {
        XCTAssertEqual(AXStaleness.staleActCodes, [-25202, -25204, -25205, -25212])
    }

    func testIsStaleActCodeMatchesEachListedCode() {
        for code in [-25202, -25204, -25205, -25212] {
            XCTAssertTrue(AXStaleness.isStaleActCode(code), "\(code) should be stale")
        }
    }

    func testIsStaleActCodeRejectsUnlistedCodes() {
        // Success and unrelated AX errors are NOT staleness signals.
        for code in [0, -25200, -25201, -25203, -25206, -25210, -25211, -10005, 42] {
            XCTAssertFalse(AXStaleness.isStaleActCode(code), "\(code) should not be stale")
        }
    }

    func testIsAliveRequiresSuccessAndNonEmptyRole() {
        XCTAssertTrue(AXStaleness.isAlive(status: 0, role: "AXButton"))
    }

    func testIsAliveFalseOnNonZeroStatus() {
        XCTAssertFalse(AXStaleness.isAlive(status: -25205, role: "AXButton"))
    }

    func testIsAliveFalseOnNilOrEmptyRole() {
        XCTAssertFalse(AXStaleness.isAlive(status: 0, role: nil))
        XCTAssertFalse(AXStaleness.isAlive(status: 0, role: ""))
    }
}
