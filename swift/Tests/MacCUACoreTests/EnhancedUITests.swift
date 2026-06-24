import XCTest
@testable import MacCUACore

final class EnhancedUITests: XCTestCase {

    // MARK: EnhancedUIPolicy — which app types warrant enhanced UI

    func testPolicyEnablesElectronAndBrowserOnly() {
        XCTAssertTrue(EnhancedUIPolicy.shouldEnable(for: .electron))
        XCTAssertTrue(EnhancedUIPolicy.shouldEnable(for: .browser))
        XCTAssertFalse(EnhancedUIPolicy.shouldEnable(for: .nativeCocoa))
        XCTAssertFalse(EnhancedUIPolicy.shouldEnable(for: .java))
        XCTAssertFalse(EnhancedUIPolicy.shouldEnable(for: .qt))
        XCTAssertFalse(EnhancedUIPolicy.shouldEnable(for: .unknown))
    }

    // MARK: EnhancedUIRewalkPolicy — re-walk poll stop condition

    func testRewalkContinuesWhileEmptyUntilAttemptsExhausted() {
        let p = EnhancedUIRewalkPolicy(maxAttempts: 3, pollIntervalMs: 50)
        // First walk expected empty -> keep going.
        XCTAssertTrue(p.shouldContinue(attempt: 0, nodeCount: 0))
        XCTAssertTrue(p.shouldContinue(attempt: 1, nodeCount: 0))
        XCTAssertTrue(p.shouldContinue(attempt: 2, nodeCount: 0))
        // Attempts exhausted.
        XCTAssertFalse(p.shouldContinue(attempt: 3, nodeCount: 0))
    }

    func testRewalkStopsAsSoonAsTreeIsNonEmpty() {
        let p = EnhancedUIRewalkPolicy(maxAttempts: 5, pollIntervalMs: 50)
        XCTAssertFalse(p.shouldContinue(attempt: 1, nodeCount: 7))
        XCTAssertFalse(p.shouldContinue(attempt: 0, nodeCount: 1))
    }

    func testRewalkDefaultsAndBudget() {
        let p = EnhancedUIRewalkPolicy()
        XCTAssertEqual(p.maxAttempts, 5)
        XCTAssertEqual(p.pollIntervalMs, 80)
        XCTAssertEqual(p.totalBudgetMs, 400)
    }

    func testRewalkClampsInvalidConfig() {
        let p = EnhancedUIRewalkPolicy(maxAttempts: 0, pollIntervalMs: -10)
        XCTAssertEqual(p.maxAttempts, 1)
        XCTAssertEqual(p.pollIntervalMs, 0)
        // Loop runs exactly one walk when empty.
        XCTAssertTrue(p.shouldContinue(attempt: 0, nodeCount: 0))
        XCTAssertFalse(p.shouldContinue(attempt: 1, nodeCount: 0))
    }

    // MARK: EnhancedUITracker — remembered + reversible

    func testTrackerRemembersPerPidAndCapturesPriorState() {
        let t = EnhancedUITracker()
        XCTAssertFalse(t.isEnabled(pid: 42))
        let prior = EnhancedUITracker.PriorState(enhancedUI: false, manualAccessibility: nil)
        t.markEnabled(pid: 42, prior: prior)
        XCTAssertTrue(t.isEnabled(pid: 42))
        XCTAssertEqual(t.priorState(pid: 42), prior)
        // Distinct pid untouched.
        XCTAssertFalse(t.isEnabled(pid: 99))
    }

    func testTrackerDisableReturnsAndForgetsPrior() {
        let t = EnhancedUITracker()
        let prior = EnhancedUITracker.PriorState(enhancedUI: true, manualAccessibility: false)
        t.markEnabled(pid: 7, prior: prior)
        let returned = t.markDisabled(pid: 7)
        XCTAssertEqual(returned, prior)
        XCTAssertFalse(t.isEnabled(pid: 7))
        XCTAssertNil(t.priorState(pid: 7))
        // Disabling an unknown pid is a nil no-op.
        XCTAssertNil(t.markDisabled(pid: 7))
    }

    func testTrackerReset() {
        let t = EnhancedUITracker()
        t.markEnabled(pid: 1, prior: .init())
        t.markEnabled(pid: 2, prior: .init())
        t.reset()
        XCTAssertFalse(t.isEnabled(pid: 1))
        XCTAssertFalse(t.isEnabled(pid: 2))
    }
}
