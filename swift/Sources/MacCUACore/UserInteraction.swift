// US-044 — User-interruption monitor (pure state machine).
//
// Ports the load-bearing pure logic of `focus.py`'s `UserInteractionMonitor`:
// per-bundle debounce of user input that targets the driven app, and the
// one-shot warning that tells the model to stop and re-query. The macOS
// CGEventTap that feeds this lives in `MacCUAKit.KitUserInteractionMonitor`
// (listen-only — Invariant 5); this type is the time-INJECTED state so it stays
// Linux-pure and testable, exactly like `DebounceStateMachine` (US-002).
//
// Semantics (matching focus.py):
//   - Each user event targeting the monitored app records its bundle's last-event
//     time. While more events arrive within DEBOUNCE_DURATION the timer "resets"
//     (the bundle is not yet interrupted).
//   - Once DEBOUNCE_DURATION of quiet elapses after the last event, that bundle is
//     promoted to "interrupted" (the debounce fired).
//   - `consumeInterruption` is one-shot: it returns the warning ONCE per fired
//     interruption, then clears it (focus.py `check_interruption` discards).

import Foundation

/// Pure, time-injected per-bundle interruption debounce. No clock calls inside —
/// the Kit monitor feeds `now`. Not thread-safe by itself; the Kit wrapper owns
/// the lock (mirrors the OutcomeMonitor/CircuitBreaker split).
public struct UserInteractionState {
    /// Per-bundle debounce window (focus.py `DEBOUNCE_DURATION = 0.5`).
    public let debounceDuration: Double

    /// bundleId -> timestamp of the most recent user event targeting it.
    private var lastEvent: [String: Double] = [:]
    /// Bundles whose debounce has fired and are awaiting a `consumeInterruption`.
    private var interrupted: Set<String> = []

    public init(debounceDuration: Double = 0.5) {
        self.debounceDuration = debounceDuration
    }

    /// Record a user event targeting `bundleId` at time `now`. Resets that
    /// bundle's debounce window.
    public mutating func recordInteraction(bundleId: String, now: Double) {
        guard !bundleId.isEmpty else { return }
        lastEvent[bundleId] = now
    }

    /// Promote any bundle that has been quiet for `>= debounceDuration` to
    /// interrupted (the debounce timer fired). Call before consuming. Idempotent.
    public mutating func advance(now: Double) {
        for (bundle, t) in lastEvent where now - t >= debounceDuration {
            interrupted.insert(bundle)
            lastEvent.removeValue(forKey: bundle)
        }
    }

    /// One-shot: if `bundleId`'s debounce has fired, clear it and return the
    /// warning; else nil. Runs `advance(now:)` first so a settled interruption is
    /// observed at check time (focus.py promotes via timer; we promote lazily).
    public mutating func consumeInterruption(bundleId: String, now: Double) -> String? {
        advance(now: now)
        guard interrupted.contains(bundleId) else { return nil }
        interrupted.remove(bundleId)
        return UserInteractionState.warningMessage(bundleId: bundleId)
    }

    /// Clear all pending state (focus.py `stop_monitoring` / `start_monitoring`).
    public mutating func reset() {
        lastEvent.removeAll()
        interrupted.removeAll()
    }

    /// Verbatim focus.py warning. App name = the segment after the last `.` in the
    /// bundle id (e.g. `com.apple.Safari` -> `Safari`), else the whole id.
    public static func warningMessage(bundleId: String) -> String {
        let appName: String
        if let dot = bundleId.lastIndex(of: ".") {
            appName = String(bundleId[bundleId.index(after: dot)...])
        } else {
            appName = bundleId
        }
        return "The user changed '\(appName)'. Re-query the latest state "
            + "with `get_app_state` before sending more actions."
    }
}
