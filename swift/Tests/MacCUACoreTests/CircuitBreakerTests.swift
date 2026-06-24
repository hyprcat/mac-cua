import XCTest
@testable import MacCUACore

// US-043: SCK failure counter + circuit breaker. Verifies the time-injected pure
// state machine (open after N failures, bypass during cooldown, probe after,
// reset on success) and the thread-safe counter wrapper.
final class CircuitBreakerTests: XCTestCase {

    // MARK: - Pure state machine (CircuitBreakerState)

    func testFreshBreakerAttempts() {
        let s = CircuitBreakerState(threshold: 2, cooldown: 30)
        XCTAssertTrue(s.shouldAttempt(now: 0))
        XCTAssertFalse(s.isTripped)
        XCTAssertEqual(s.consecutiveFailures, 0)
    }

    func testSingleFailureBelowThresholdStillAttempts() {
        var s = CircuitBreakerState(threshold: 2, cooldown: 30)
        s.recordFailure(now: 100)
        XCTAssertEqual(s.consecutiveFailures, 1)
        XCTAssertFalse(s.isTripped)
        // One failure < threshold: SCK still attempted.
        XCTAssertTrue(s.shouldAttempt(now: 101))
    }

    func testTripsAfterThresholdAndBypassesDuringCooldown() {
        var s = CircuitBreakerState(threshold: 2, cooldown: 30)
        s.recordFailure(now: 100)
        s.recordFailure(now: 101) // crosses threshold -> openUntil = 131
        XCTAssertTrue(s.isTripped)
        XCTAssertEqual(s.openUntil, 131)
        // Inside cooldown: bypass SCK.
        XCTAssertFalse(s.shouldAttempt(now: 110))
        XCTAssertFalse(s.shouldAttempt(now: 130.9))
    }

    func testProbeAllowedAfterCooldownExpires() {
        var s = CircuitBreakerState(threshold: 2, cooldown: 30)
        s.recordFailure(now: 100)
        s.recordFailure(now: 101) // openUntil = 131
        // At/after cooldown a probe is allowed even though failures still >= threshold.
        XCTAssertTrue(s.shouldAttempt(now: 131))
        XCTAssertTrue(s.shouldAttempt(now: 200))
    }

    func testSuccessResetsBreaker() {
        var s = CircuitBreakerState(threshold: 2, cooldown: 30)
        s.recordFailure(now: 100)
        s.recordFailure(now: 101)
        XCTAssertTrue(s.isTripped)
        s.recordSuccess()
        XCTAssertEqual(s.consecutiveFailures, 0)
        XCTAssertEqual(s.openUntil, 0)
        XCTAssertFalse(s.isTripped)
        XCTAssertTrue(s.shouldAttempt(now: 105))
    }

    func testProbeFailureRearmsCooldown() {
        var s = CircuitBreakerState(threshold: 2, cooldown: 30)
        s.recordFailure(now: 100)
        s.recordFailure(now: 101) // openUntil = 131
        // Cooldown expires, probe attempted, probe fails again -> re-arm from new now.
        XCTAssertTrue(s.shouldAttempt(now: 131))
        s.recordFailure(now: 131) // openUntil = 161
        XCTAssertEqual(s.consecutiveFailures, 3)
        XCTAssertFalse(s.shouldAttempt(now: 140))
        XCTAssertTrue(s.shouldAttempt(now: 161))
    }

    func testThresholdOfOneTripsImmediately() {
        var s = CircuitBreakerState(threshold: 1, cooldown: 5)
        s.recordFailure(now: 10)
        XCTAssertTrue(s.isTripped)
        XCTAssertFalse(s.shouldAttempt(now: 12))
        XCTAssertTrue(s.shouldAttempt(now: 15))
    }

    // MARK: - Thread-safe wrapper (CircuitBreaker)

    func testWrapperDrivesInjectedClock() {
        let clock = ClockBox(0)
        let cb = CircuitBreaker(threshold: 2, cooldown: 30, now: { clock.value })
        XCTAssertTrue(cb.shouldAttempt())
        clock.value = 100; cb.recordFailure()
        clock.value = 101; cb.recordFailure()
        XCTAssertTrue(cb.isTripped)
        XCTAssertEqual(cb.consecutiveFailures, 2)
        clock.value = 110
        XCTAssertFalse(cb.shouldAttempt()) // cooling down
        clock.value = 131
        XCTAssertTrue(cb.shouldAttempt())  // probe
        cb.recordSuccess()
        XCTAssertEqual(cb.consecutiveFailures, 0)
        XCTAssertFalse(cb.isTripped)
    }

    /// Thread-safe mutable clock for the injected `now` closure.
    private final class ClockBox: @unchecked Sendable {
        var value: Double
        init(_ v: Double) { value = v }
    }
}
