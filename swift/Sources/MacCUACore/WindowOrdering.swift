// US-045 — Window-ordering observer (pure state machine).
//
// Ports the load-bearing pure logic of `focus.py`'s `WindowOrderingObserver`:
// detect a z-order change by comparing the freshly-sampled on-screen window-number
// list against the last known order. The macOS `CGWindowListCopyWindowInfo` poll
// that feeds this lives in `MacCUAKit.KitWindowOrderingObserver` (no AXObserver —
// polling is the correctness gate, §5.3); this type is the pure, Linux-testable
// state, exactly like `DebounceStateMachine` (US-002) / `UserInteractionState`
// (US-044).
//
// Semantics (matching focus.py `_poll`):
//   - The observer holds the last-seen ordered list of CGWindowNumbers.
//   - On each sample, if the new order differs from the last (order-sensitive,
//     element-wise), the order is updated and the change is reported once.
//   - An identical sample (including identical order) reports no change.
//   - A nil/empty sample from the OS is ignored (focus.py returns early on None)
//     and does NOT clobber the last-known order.

import Foundation

/// Pure window z-order change detector. No clock/OS calls inside — the Kit
/// observer samples `CGWindowListCopyWindowInfo` and feeds the window-number list
/// here. Not thread-safe by itself; the Kit wrapper owns the lock/timer (mirrors
/// the UserInteractionState split).
public struct WindowOrderingState {
    /// Last-seen on-screen window order (CGWindowNumbers, front-to-back as the OS
    /// reports them). Empty until the first non-empty sample.
    private(set) public var lastOrder: [Int] = []

    public init() {}

    /// Feed a freshly-sampled window-number list. Returns `true` (and updates
    /// `lastOrder`) iff the order changed vs. the last sample. A `nil` or empty
    /// sample is ignored (returns `false`, leaves `lastOrder` untouched) — matches
    /// focus.py returning early when `CGWindowListCopyWindowInfo` yields None.
    public mutating func sample(_ order: [Int]?) -> Bool {
        guard let order, !order.isEmpty else { return false }
        guard order != lastOrder else { return false }
        lastOrder = order
        return true
    }

    /// Clear state (focus.py `stop`/`start` reset `_last_window_order`).
    public mutating func reset() {
        lastOrder.removeAll()
    }
}
