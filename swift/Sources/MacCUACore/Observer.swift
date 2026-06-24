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

// MARK: - TreeFingerprint (poll feed for the SettleMonitor)

/// Pure derivation of the two signals the `DebounceStateMachine` consumes from a
/// pruned node tree: a stable structural/content fingerprint and the set of
/// key-frame rects whose motion means an animation is still in flight.
///
/// This replaces AXObserver as the settle-correctness feed (§5.3): the Kit
/// `SettleMonitor` re-walks the tree each poll and runs these two pure functions,
/// so "did the UI change / is it still moving" is decided by observation, never
/// by a notification flag.
public enum TreeFingerprint {
    /// Stable hash over the structure + content that the model can perceive.
    /// Deliberately excludes per-node geometry (position/size) — geometry is fed
    /// separately as `keyFrameRects` so a moving control reads as "animating"
    /// (keep waiting), not as a brand-new structural change every poll.
    public static func compute(_ nodes: [Node]) -> Int {
        var hasher = Hasher()
        hasher.combine(nodes.count)
        for node in nodes {
            hasher.combine(node.depth)
            hasher.combine(node.role)
            hasher.combine(node.label)
            hasher.combine(node.value)
            hasher.combine(node.description)
            hasher.combine(node.valueDescription)
            hasher.combine(node.placeholder)
            hasher.combine(node.selectedText)
            // States are already emitted in a canonical sorted order by the
            // walker; combine as-is so set membership changes register.
            for state in node.states { hasher.combine(state) }
        }
        return hasher.finalize()
    }

    /// Key-frame rects for animation detection: one `SettleRect` per node that
    /// carries both a position and a size, in stable preorder. A change in this
    /// list between two polls = motion in flight, which keeps the machine waiting.
    public static func keyFrameRects(_ nodes: [Node]) -> [SettleRect] {
        var rects: [SettleRect] = []
        rects.reserveCapacity(nodes.count)
        for node in nodes {
            guard let p = node.position, let s = node.size else { continue }
            rects.append(SettleRect(x: p.x, y: p.y, width: s.w, height: s.h))
        }
        return rects
    }
}

// MARK: - SettlePoller (pure poll-loop driver)

/// Pure, fully-injected driver of the settle poll loop. Wraps a
/// `DebounceStateMachine` and pumps it with samples until it returns a terminal
/// `SettleResult`, sleeping `pollInterval` between polls. Time and I/O are
/// injected (`now` / `sleep` / `sample`) so the loop itself is Linux-testable;
/// the Kit `SettleMonitor` supplies a real clock, `Thread.sleep`, and a tree
/// re-walk for `sample`.
public struct SettlePoller {
    public let quietPeriod: Double
    public let maxWait: Double
    public let pollInterval: Double

    public init(quietPeriod: Double, maxWait: Double, pollInterval: Double) {
        self.quietPeriod = quietPeriod
        self.maxWait = max(0, maxWait)
        // Never let a zero/negative interval spin the CPU; never overshoot the cap.
        self.pollInterval = min(max(pollInterval, 0.001), max(self.maxWait, 0.001))
    }

    /// Run the loop to a terminal result.
    ///
    /// - Parameters:
    ///   - now: monotonic clock read (seconds).
    ///   - sample: produces (fingerprint, key-frame rects) for the current tree.
    ///   - sleep: blocks for the given seconds (real clock advance between polls).
    ///   - isCancelled: optional cooperative cancel check (Inv 16 user-yield).
    public func run(
        now: () -> Double,
        sample: () -> (fingerprint: Int, frames: [SettleRect]),
        sleep: (Double) -> Void,
        isCancelled: () -> Bool = { false }
    ) -> SettleResult {
        let machine = DebounceStateMachine(quietPeriod: quietPeriod, maxWait: maxWait, startTime: now())
        while true {
            if isCancelled() { return .cancelled }
            let s = sample()
            if let result = machine.tick(now: now(), fingerprint: s.fingerprint, frameRects: s.frames) {
                return result
            }
            sleep(pollInterval)
        }
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
