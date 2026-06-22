import XCTest
@testable import MacCUACore

// Ports the intent of app/_lib/retry.py: backoff schedule, jitter scaling,
// max-interval clamping, give-up behaviour, and pre-configured policies.
// Sleep and RNG are injected so tests are instant and deterministic.

final class RetryTests: XCTestCase {

    // MARK: - intervals() backoff schedule

    func testBackoffScheduleNoJitter() {
        let policy = RetryPolicy(
            maxRetries: 4, baseInterval: 0.5, backoffMultiplier: 2.0, jitter: false
        )
        // 0.5, 1.0, 2.0, 4.0
        XCTAssertEqual(policy.intervals(), [0.5, 1.0, 2.0, 4.0])
    }

    func testBackoffClampsAtMaxInterval() {
        let policy = RetryPolicy(
            maxRetries: 5, baseInterval: 4.0, backoffMultiplier: 2.0,
            maxInterval: 10.0, jitter: false
        )
        // 4, 8, min(16,10)=10, 10, 10
        XCTAssertEqual(policy.intervals(), [4.0, 8.0, 10.0, 10.0, 10.0])
    }

    func testBackoffCountMatchesMaxRetries() {
        XCTAssertEqual(RetryPolicy(maxRetries: 0, jitter: false).intervals().count, 0)
        XCTAssertEqual(RetryPolicy(maxRetries: 3, jitter: false).intervals().count, 3)
    }

    func testJitterScalesByHalfPlusRandom() {
        // random() pinned to 0.0 -> each interval scaled by 0.5
        let policy = RetryPolicy(
            maxRetries: 3, baseInterval: 1.0, backoffMultiplier: 2.0, jitter: true
        )
        let lo = policy.intervals(random: { 0.0 })
        XCTAssertEqual(lo, [0.5, 1.0, 2.0])  // 1*0.5, 2*0.5, 4*0.5

        // random() -> 1.0 -> scaled by 1.5
        let hi = policy.intervals(random: { 1.0 })
        let expected = [1.5, 3.0, 6.0]
        XCTAssertEqual(hi.count, expected.count)
        for (a, b) in zip(hi, expected) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    // MARK: - with_retry success / give-up

    func testSucceedsFirstTryNoSleep() throws {
        var sleeps = 0
        let result = try withRetry(
            policy: RetryPolicy(maxRetries: 3, jitter: false),
            sleep: { _ in sleeps += 1 }
        ) { 42 }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(sleeps, 0, "no retries -> no sleep")
    }

    func testSucceedsAfterRetries() throws {
        var calls = 0
        var sleptIntervals: [Double] = []
        let policy = RetryPolicy(maxRetries: 3, baseInterval: 0.1, backoffMultiplier: 2.0, jitter: false)

        let result = try withRetry(
            policy: policy,
            sleep: { sleptIntervals.append($0) }
        ) { () throws -> Int in
            calls += 1
            if calls < 3 { throw AutomationError.ax("fail \(calls)") }
            return calls
        }

        XCTAssertEqual(result, 3)
        XCTAssertEqual(calls, 3)            // 1 initial + 2 retries
        XCTAssertEqual(sleptIntervals, [0.1, 0.2])  // slept before retry 2 and 3
    }

    func testGivesUpAndThrowsLastError() {
        var calls = 0
        var attempts: [Int] = []
        let policy = RetryPolicy(maxRetries: 2, baseInterval: 0.1, jitter: false)

        XCTAssertThrowsError(
            try withRetry(
                policy: policy,
                sleep: { _ in },
                onRetry: { attempt, _ in attempts.append(attempt) }
            ) { () throws -> Int in
                calls += 1
                throw AutomationError.ax("fail \(calls)")
            }
        ) { error in
            let e = error as? AutomationError
            XCTAssertEqual(e?.message, "fail 3", "should rethrow the last error")
        }
        XCTAssertEqual(calls, 3)            // 1 initial + 2 retries, all failed
        XCTAssertEqual(attempts, [1, 2, 3])
    }

    func testNonRetryableRethrowsImmediately() {
        var calls = 0
        XCTAssertThrowsError(
            try withRetry(
                policy: RetryPolicy(maxRetries: 5, jitter: false),
                retryable: { ($0 as? AutomationError)?.kind == .ax },
                sleep: { _ in }
            ) { () throws -> Int in
                calls += 1
                throw AutomationError.safety("not retryable")  // not .ax
            }
        ) { error in
            XCTAssertEqual((error as? AutomationError)?.kind, .safety)
        }
        XCTAssertEqual(calls, 1, "non-retryable error must not retry")
    }

    // MARK: - pre-configured policies

    func testPreconfiguredPolicies() {
        XCTAssertEqual(axRetryPolicy.maxRetries, 2)
        XCTAssertEqual(axRetryPolicy.baseInterval, 0.1)
        XCTAssertFalse(axRetryPolicy.jitter)
        XCTAssertEqual(axRetryPolicy.intervals(), [0.1, 0.2])

        XCTAssertEqual(screenshotRetryPolicy.maxRetries, 2)
        XCTAssertEqual(screenshotRetryPolicy.baseInterval, 0.2)
        XCTAssertEqual(screenshotRetryPolicy.intervals(), [0.2, 0.4])

        XCTAssertEqual(eventRetryPolicy.maxRetries, 1)
        XCTAssertEqual(eventRetryPolicy.baseInterval, 0.05)
        XCTAssertEqual(eventRetryPolicy.backoffMultiplier, 1.0)
        XCTAssertEqual(eventRetryPolicy.intervals(), [0.05])
    }
}
