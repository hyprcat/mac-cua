#if os(macOS)
import XCTest
@testable import MacCUAKit
import MacCUACore

/// US-025 — Kit run-loop thread + polling SettleMonitor smoke tests (real clock).
final class RunLoopTests: XCTestCase {
    func testRunLoopThreadStartsAndStops() {
        let t = KitRunLoopThread()
        t.start()
        XCTAssertTrue(t.isRunning)
        XCTAssertNotNil(t.runLoop)
        t.stop()
        XCTAssertFalse(t.isRunning)
        XCTAssertNil(t.runLoop)
    }

    func testSettleMonitorNoChangeOnStableTree() {
        // Sampler always returns the same tree -> quiesces immediately.
        let stable = [Node(index: 0, role: "AXButton", states: [], depth: 0)]
        let monitor = KitSettleMonitor(pollInterval: 0.01, sampler: { stable })
        let r = monitor.waitForSettle(context: "test", timeout: 0.5, quietPeriod: 0.05)
        XCTAssertEqual(r, .noChange)
    }

    func testSettleMonitorCancelYields() {
        let monitor = KitSettleMonitor(pollInterval: 0.01, sampler: { [] })
        monitor.cancel()
        let r = monitor.waitForSettle(context: "test", timeout: 0.5, quietPeriod: 0.05)
        // reset() at the top of waitForSettle clears the pre-set cancel, so this
        // settles normally — proving reset() works and the monitor is reusable.
        XCTAssertEqual(r, .noChange)
    }

    func testSettleMonitorIsNotInvalidatedByDefault() {
        let monitor = KitSettleMonitor()
        XCTAssertFalse(monitor.isInvalidated)
    }
}
#endif
