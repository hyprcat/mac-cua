import XCTest
@testable import MacCUACore

// Ports the pure-logic intent of tests around app/_lib/observer.py:
// DebounceStateMachine settle semantics (animation-aware, time-injected) and
// AssertionTracker ref-count balance.
final class ObserverTests: XCTestCase {

    // MARK: - DebounceStateMachine

    func testNoChangeWhenNothingMovesForQuietPeriod() {
        let m = DebounceStateMachine(quietPeriod: 0.1, maxWait: 2.0, startTime: 0)
        XCTAssertNil(m.tick(now: 0.0, fingerprint: 1))        // baseline
        XCTAssertNil(m.tick(now: 0.05, fingerprint: 1))       // still quiet
        XCTAssertEqual(m.tick(now: 0.1, fingerprint: 1), .noChange)
    }

    func testQuietConvergesToSettledAfterAChange() {
        let m = DebounceStateMachine(quietPeriod: 0.1, maxWait: 2.0, startTime: 0)
        XCTAssertNil(m.tick(now: 0.0, fingerprint: 1))        // baseline
        XCTAssertNil(m.tick(now: 0.05, fingerprint: 2))       // change observed
        XCTAssertNil(m.tick(now: 0.1, fingerprint: 2))        // 50ms quiet, not yet
        XCTAssertEqual(m.tick(now: 0.16, fingerprint: 2), .settled) // 110ms quiet
        XCTAssertTrue(m.hasObservedChange)
    }

    func testAnimationKeepsWaiting() {
        // Fingerprint is stable but a key-frame rect keeps moving every poll:
        // must not report settled/noChange — it's an in-flight animation.
        let m = DebounceStateMachine(quietPeriod: 0.1, maxWait: 5.0, startTime: 0)
        XCTAssertNil(m.tick(now: 0.0, fingerprint: 1, frameRects: [rect(0)]))
        for i in 1...10 {
            let t = Double(i) * 0.05
            // a moving rect each poll => animation in flight
            XCTAssertNil(m.tick(now: t, fingerprint: 1, frameRects: [rect(Double(i))]),
                         "should still be waiting at t=\(t)")
        }
        // Animation stops: rect now stable -> settles after quiet elapses.
        let last = rect(10)
        XCTAssertNil(m.tick(now: 0.55, fingerprint: 1, frameRects: [last]))
        XCTAssertEqual(m.tick(now: 0.66, fingerprint: 1, frameRects: [last]), .settled)
    }

    func testHardCapFiresWhenAnimationNeverStops() {
        let m = DebounceStateMachine(quietPeriod: 0.1, maxWait: 0.3, startTime: 0)
        XCTAssertNil(m.tick(now: 0.0, fingerprint: 1, frameRects: [rect(0)]))
        XCTAssertNil(m.tick(now: 0.1, fingerprint: 1, frameRects: [rect(1)]))
        XCTAssertNil(m.tick(now: 0.2, fingerprint: 1, frameRects: [rect(2)]))
        // Still animating at the cap -> TIMEOUT.
        XCTAssertEqual(m.tick(now: 0.3, fingerprint: 1, frameRects: [rect(3)]), .timeout)
    }

    func testCancelled() {
        let m = DebounceStateMachine(quietPeriod: 0.1, maxWait: 2.0, startTime: 0)
        XCTAssertNil(m.tick(now: 0.0, fingerprint: 1))
        m.cancel()
        XCTAssertEqual(m.tick(now: 0.05, fingerprint: 2), .cancelled)
    }

    func testFingerprintChangeResetsQuietTimer() {
        let m = DebounceStateMachine(quietPeriod: 0.1, maxWait: 5.0, startTime: 0)
        XCTAssertNil(m.tick(now: 0.0, fingerprint: 1))
        XCTAssertNil(m.tick(now: 0.05, fingerprint: 2))   // change
        XCTAssertNil(m.tick(now: 0.14, fingerprint: 3))   // another change resets timer
        XCTAssertNil(m.tick(now: 0.2, fingerprint: 3))    // only 60ms quiet
        XCTAssertEqual(m.tick(now: 0.25, fingerprint: 3), .settled) // 110ms quiet
    }

    private func rect(_ y: Double) -> SettleRect {
        SettleRect(x: 0, y: y, width: 100, height: 20)
    }

    // MARK: - AssertionTracker

    func testAcquireReleaseBalances() {
        let t = AssertionTracker()
        t.acquire(pid: 42, kind: .readAttributes)
        XCTAssertTrue(t.isActive(pid: 42, kind: .readAttributes))
        XCTAssertEqual(t.activeCount(pid: 42, kind: .readAttributes), 1)
        t.acquire(pid: 42, kind: .readAttributes)
        XCTAssertEqual(t.activeCount(pid: 42, kind: .readAttributes), 2)
        t.release(pid: 42, kind: .readAttributes)
        t.release(pid: 42, kind: .readAttributes)
        XCTAssertFalse(t.isActive(pid: 42, kind: .readAttributes))
        XCTAssertEqual(t.activeCount(pid: 42, kind: .readAttributes), 0)
    }

    func testReleaseWithoutAcquireIsSafe() {
        let t = AssertionTracker()
        t.release(pid: 1, kind: .writeAttributes)   // no underflow
        XCTAssertEqual(t.activeCount(pid: 1, kind: .writeAttributes), 0)
    }

    func testScopedAssertionBalancesEvenWhenBodyThrows() {
        let t = AssertionTracker()
        struct Boom: Error {}
        XCTAssertThrowsError(try t.withAssertion(pid: 7, kind: .performActions) {
            XCTAssertEqual(t.activeCount(pid: 7, kind: .performActions), 1)
            throw Boom()
        })
        XCTAssertEqual(t.activeCount(pid: 7, kind: .performActions), 0)
    }

    func testReleaseAllAndPIDScoping() {
        let t = AssertionTracker()
        t.acquire(pid: 1, kind: .readAttributes)
        t.acquire(pid: 1, kind: .writeAttributes)
        t.acquire(pid: 2, kind: .readAttributes)
        t.releaseAll(pid: 1)
        XCTAssertEqual(t.activeCount(pid: 1, kind: .readAttributes), 0)
        XCTAssertEqual(t.activeCount(pid: 1, kind: .writeAttributes), 0)
        XCTAssertEqual(t.activeCount(pid: 2, kind: .readAttributes), 1)  // untouched
    }
}
