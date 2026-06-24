// Ports the pure, Linux-testable logic of app/_lib/observer.py.
//
// The Python module mixes CFRunLoop / AXObserver bindings (macOS-only, lives in
// Kit) with two pieces of pure state-machine logic that are settle-correctness
// load-bearing:
//
//   * DebounceStateMachine — settle by OBSERVATION, never a fixed sleep (§5.3).
//     Here it is rebuilt as an animation-aware, time-INJECTED machine: it
//     consumes (timestamp, tree-fingerprint, key-frame rects) ticks, requires
//     N ms of quiet, treats changing frame rects as in-flight animation and
//     keeps waiting, and is bounded by a hard cap. No clock calls inside.
//
//   * AssertionTracker — ref-counted, PID-scoped AX-enablement assertions with
//     try/finally (acquire/release) balance semantics.
//
// The macOS frame/fingerprint feed is a Kit concern (Phase 3); the `SettleMonitor`
// seam in Providers.swift drives this machine in its poll loop.

import Foundation

// MARK: - Geometry sample

/// A key-frame rectangle sampled from the tree. Equality is what tells the
/// machine whether an animation is still in flight.
public struct SettleRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - DebounceStateMachine

/// Animation-aware settle debounce. Pure: time is injected via `tick(now:…)`,
/// never read from a clock. Feed it polls; it tells you when to stop.
///
/// Semantics ported from `observer.py::wait_for_settle` + `DebounceStateMachine`:
///   - NO_CHANGE: nothing observed for `quietPeriod` since start.
///   - SETTLED:   a change was observed, then `quietPeriod` of quiet elapsed.
///   - TIMEOUT:   `maxWait` (hard cap) elapsed while still in flight.
///   - CANCELLED: explicitly cancelled (e.g. user interruption — Inv 16).
///
/// A changing key-frame rect counts as an in-flight animation and keeps the
/// machine waiting exactly like a structural fingerprint change does, so an
/// animation that never quiesces falls through to the hard cap rather than
/// reporting a premature SETTLED/NO_CHANGE.
public final class DebounceStateMachine {
    public let quietPeriod: Double
    public let maxWait: Double
    private let startTime: Double

    private var lastFingerprint: Int?
    private var lastFrames: [SettleRect] = []
    private var lastChangeTime: Double?
    private var observedChange = false
    private var cancelled = false

    public init(quietPeriod: Double, maxWait: Double, startTime: Double) {
        self.quietPeriod = quietPeriod
        self.maxWait = maxWait
        self.startTime = startTime
    }

    /// Cancel the wait. The next `tick` (or `currentResult`) reports `.cancelled`.
    public func cancel() { cancelled = true }

    /// True once any structural or frame change has been observed since start.
    public var hasObservedChange: Bool { observedChange }

    /// Consume one poll. Returns a terminal `SettleResult` once the wait is
    /// resolved, or `nil` to keep polling.
    ///
    /// - Parameters:
    ///   - now: monotonic timestamp of this poll (injected — no clock inside).
    ///   - fingerprint: stable hash of the pruned tree structure/content.
    ///   - frameRects: key-frame rects; any change vs the prior tick = animation.
    public func tick(now: Double, fingerprint: Int, frameRects: [SettleRect] = []) -> SettleResult? {
        if cancelled { return .cancelled }

        if lastFingerprint == nil {
            // First poll establishes the baseline; no change recorded yet.
            lastFingerprint = fingerprint
            lastFrames = frameRects
        } else {
            let fingerprintChanged = fingerprint != lastFingerprint
            let framesChanged = frameRects != lastFrames
            lastFingerprint = fingerprint
            lastFrames = frameRects
            if fingerprintChanged || framesChanged {
                observedChange = true
                lastChangeTime = now
            }
        }

        // Resolve a successful settle before the hard cap so a genuine quiesce
        // always wins over a same-tick budget expiry.
        if observedChange {
            if let last = lastChangeTime, now - last >= quietPeriod {
                return .settled
            }
        } else if now - startTime >= quietPeriod {
            return .noChange
        }

        // Hard cap: still in flight when the per-tool budget elapsed.
        if now - startTime >= maxWait {
            return .timeout
        }

        return nil
    }
}

// MARK: - AssertionTracker

/// Kinds of AX access that can be asserted (ports `AXEnablementKind`).
public enum AXEnablementKind: String, Sendable, CaseIterable {
    case readAttributes
    case writeAttributes
    case performActions
    case observeNotifications
}

/// Ref-counted, PID-scoped AX-enablement assertions. Pure state — the macOS
/// side-effects of enabling/disabling AX live in Kit. The contract that matters
/// is balance: every `acquire` is matched by a `release`, and `withAssertion`
/// guarantees it even when the body throws (try/finally semantics).
public final class AssertionTracker {
    private var counts: [Key: Int] = [:]
    private var initializedPIDs: Set<Int> = []

    private struct Key: Hashable {
        let pid: Int
        let kind: AXEnablementKind
    }

    public init() {}

    public func acquire(pid: Int, kind: AXEnablementKind) {
        let key = Key(pid: pid, kind: kind)
        counts[key, default: 0] += 1
        initializedPIDs.insert(pid)
    }

    public func release(pid: Int, kind: AXEnablementKind) {
        let key = Key(pid: pid, kind: kind)
        guard let count = counts[key] else { return }
        if count <= 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = count - 1
        }
    }

    public func isActive(pid: Int, kind: AXEnablementKind) -> Bool {
        (counts[Key(pid: pid, kind: kind)] ?? 0) > 0
    }

    public func activeCount(pid: Int, kind: AXEnablementKind) -> Int {
        counts[Key(pid: pid, kind: kind)] ?? 0
    }

    /// Release every assertion held for a PID (cleanup on session end).
    public func releaseAll(pid: Int) {
        for key in counts.keys where key.pid == pid {
            counts.removeValue(forKey: key)
        }
        initializedPIDs.remove(pid)
    }

    public func reset() {
        counts.removeAll()
        initializedPIDs.removeAll()
    }

    /// Run `body` while holding an assertion, releasing it even if `body`
    /// throws (port of `AXEnablementAssertion.__enter__/__exit__`).
    @discardableResult
    public func withAssertion<T>(pid: Int, kind: AXEnablementKind, _ body: () throws -> T) rethrows -> T {
        acquire(pid: pid, kind: kind)
        defer { release(pid: pid, kind: kind) }
        return try body()
    }
}
