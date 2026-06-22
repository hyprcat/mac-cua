import Foundation

// Port of app/_lib/retry.py — retry policy with exponential backoff.
//
// Applied to: AX operations, screenshot capture, event posting.
//
// Framework dependency abstracted: Python uses `time.sleep` and `random.random`
// directly. Here `withRetry` takes injected `sleep` and `random` closures so tests
// run instantly and deterministically. Defaults call `Thread.sleep` and
// `Double.random(in:)` so production behaviour matches Python.

/// Configurable retry with exponential backoff. Mirrors `RetryPolicy`.
public struct RetryPolicy: Equatable, Sendable {
    public var maxRetries: Int
    public var baseInterval: Double
    public var backoffMultiplier: Double
    public var maxInterval: Double
    public var jitter: Bool

    public init(
        maxRetries: Int = 3,
        baseInterval: Double = 0.5,
        backoffMultiplier: Double = 2.0,
        maxInterval: Double = 10.0,
        jitter: Bool = true
    ) {
        self.maxRetries = maxRetries
        self.baseInterval = baseInterval
        self.backoffMultiplier = backoffMultiplier
        self.maxInterval = maxInterval
        self.jitter = jitter
    }

    /// Generate the sequence of retry intervals with exponential backoff.
    /// Mirrors `RetryPolicy.intervals()`.
    ///
    /// When `jitter` is true each yielded interval is scaled by `0.5 + random()`,
    /// where `random()` returns a value in `[0, 1)` — matching Python's
    /// `random.random()`. The closure is injected for deterministic tests.
    public func intervals(random: () -> Double = { Double.random(in: 0..<1) }) -> [Double] {
        var result: [Double] = []
        var interval = baseInterval
        for _ in 0..<maxRetries {
            if jitter {
                result.append(interval * (0.5 + random()))
            } else {
                result.append(interval)
            }
            interval = Swift.min(interval * backoffMultiplier, maxInterval)
        }
        return result
    }
}

/// A predicate deciding whether a thrown error should trigger a retry.
/// Mirrors Python's `retryable: type[Exception] | tuple[...]`; default retries all.
public typealias RetryablePredicate = (Error) -> Bool

/// Execute `operation` with the given retry policy. Mirrors `with_retry()`.
///
/// The first call is not counted as a retry. On a retryable failure, the policy's
/// intervals are slept through (via the injected `sleep`) before each retry. If
/// every attempt fails, the last error is rethrown.
///
/// - Parameters:
///   - policy: Retry configuration.
///   - retryable: Predicate selecting which errors trigger a retry (default: all).
///   - sleep: Sleep closure given seconds (default: `Thread.sleep`). Injected so
///     tests are instant.
///   - random: Jitter RNG forwarded to `policy.intervals` (default: real RNG).
///   - onRetry: Optional hook called after each failed attempt with
///     `(attempt, error)` — mirrors the Python `logger.debug` retry log lines.
///   - operation: The work to perform.
/// - Throws: The last error if all retries are exhausted.
@discardableResult
public func withRetry<T>(
    policy: RetryPolicy,
    retryable: RetryablePredicate = { _ in true },
    sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
    random: () -> Double = { Double.random(in: 0..<1) },
    onRetry: ((Int, Error) -> Void)? = nil,
    operation: () throws -> T
) throws -> T {
    var lastError: Error?
    var attempt = 0

    // First attempt (not a retry).
    do {
        return try operation()
    } catch {
        guard retryable(error) else { throw error }
        lastError = error
        attempt = 1
        onRetry?(attempt, error)
    }

    // Retry attempts.
    for interval in policy.intervals(random: random) {
        sleep(interval)
        do {
            return try operation()
        } catch {
            guard retryable(error) else { throw error }
            lastError = error
            attempt += 1
            onRetry?(attempt, error)
        }
    }

    throw lastError!
}

// MARK: - Pre-configured policies (mirror module-level constants)

public let axRetryPolicy = RetryPolicy(
    maxRetries: 2, baseInterval: 0.1, backoffMultiplier: 2.0, jitter: false
)
public let screenshotRetryPolicy = RetryPolicy(
    maxRetries: 2, baseInterval: 0.2, backoffMultiplier: 2.0, jitter: false
)
public let eventRetryPolicy = RetryPolicy(
    maxRetries: 1, baseInterval: 0.05, backoffMultiplier: 1.0, jitter: false
)
