// CircuitBreaker.swift — SCK failure counter + circuit breaker (US-043).
//
// Ported from app/_lib/screen_capture.py `ScreenCapturer`'s circuit-breaker
// fields (`_consecutive_failures` / `_circuit_open_until`, threshold 2,
// cooldown 30 s). After N consecutive SCK failures (e.g. macOS screen recording
// holding ScreenCaptureKit), SCK is bypassed for the cooldown window so the
// private CG fallback runs immediately — no crash, no foregrounding (Inv 13).
//
// Linux-green: pure Swift + Foundation, NO ScreenCaptureKit/CoreGraphics. The
// state machine is TIME-INJECTED (matches DebounceStateMachine) so the open/probe/
// reset transitions are deterministically testable. The Kit capture path drives
// it with a real monotonic clock.

import Foundation

/// Pure circuit-breaker state. Value type; time injected via `now` parameters so
/// there are no clock calls inside (deterministic tests). Mirrors the Python
/// `ScreenCapturer` breaker fields exactly.
public struct CircuitBreakerState: Equatable, Sendable {
    /// Consecutive failures that trip the breaker open. Python `_CIRCUIT_BREAKER_THRESHOLD`.
    public let threshold: Int
    /// Seconds the breaker stays open before allowing a probe. Python `_CIRCUIT_BREAKER_COOLDOWN_S`.
    public let cooldown: Double

    public private(set) var consecutiveFailures: Int = 0
    /// Monotonic timestamp until which SCK is bypassed. 0 = never tripped.
    public private(set) var openUntil: Double = 0.0

    public init(threshold: Int = 2, cooldown: Double = 30.0) {
        self.threshold = threshold
        self.cooldown = cooldown
    }

    /// True once enough consecutive failures have accrued to (potentially) bypass SCK.
    public var isTripped: Bool { consecutiveFailures >= threshold }

    /// Whether SCK should be attempted at `now`. Returns false ONLY while the
    /// breaker is tripped AND still inside the cooldown window (skip SCK, fall to
    /// the CG fallback). Once the cooldown expires a probe attempt is allowed even
    /// though `consecutiveFailures` is still ≥ threshold (matches Python). Reading
    /// the gate never mutates state.
    public func shouldAttempt(now: Double) -> Bool {
        if consecutiveFailures >= threshold && now < openUntil { return false }
        return true
    }

    /// A successful capture resets the failure counter (closes the breaker).
    public mutating func recordSuccess() {
        consecutiveFailures = 0
        openUntil = 0.0
    }

    /// A failed capture (threw or returned nil) increments the counter and, on
    /// crossing the threshold, (re)arms the cooldown window from `now`.
    public mutating func recordFailure(now: Double) {
        consecutiveFailures += 1
        if consecutiveFailures >= threshold {
            openUntil = now + cooldown
        }
    }
}

/// Thread-safe failure-counter "actor": serializes access to a `CircuitBreakerState`
/// behind a lock so the (synchronous) capture path can share one breaker across
/// concurrent sessions without data races. Functionally an actor (serialized,
/// `Sendable`) but synchronous, so it drops into the sync `captureWindow` path
/// with no async ripple. The monotonic clock is injected (`now`); the default uses
/// `ProcessInfo.systemUptime`, which is Linux-available (keeps Core Linux-green).
public final class CircuitBreaker: @unchecked Sendable {
    private let lock = NSLock()
    private var state: CircuitBreakerState
    private let now: @Sendable () -> Double

    public init(
        threshold: Int = 2,
        cooldown: Double = 30.0,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.state = CircuitBreakerState(threshold: threshold, cooldown: cooldown)
        self.now = now
    }

    /// Whether SCK should be attempted right now (false while open + cooling down).
    public func shouldAttempt() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state.shouldAttempt(now: now())
    }

    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        state.recordSuccess()
    }

    public func recordFailure() {
        lock.lock(); defer { lock.unlock() }
        state.recordFailure(now: now())
    }

    /// Current consecutive-failure count (observability / tests).
    public var consecutiveFailures: Int {
        lock.lock(); defer { lock.unlock() }
        return state.consecutiveFailures
    }

    /// Whether the breaker has accrued enough failures to be tripped.
    public var isTripped: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.isTripped
    }
}
