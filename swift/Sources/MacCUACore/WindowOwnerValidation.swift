// validate_window_owner — dual-strategy owner check with assume-valid fallback
// (US-029b; Invariant 19, §5.7). Pure, Linux-testable port of
// `app/_lib/skylight.py::validate_window_owner`.
//
// A bound `(windowId, expectedPid)` pair can go stale when a window is recycled
// or a PID is reused. Before trusting a stale binding we re-confirm the window
// still belongs to the expected process. TWO strategies, because the SPIs differ
// across OS versions:
//   • Strategy 1 (pre-26): PID → owner connection id via CGSGetConnectionIDForPID,
//     then compare connection ids.
//   • Strategy 2 (26+):     owner connection id → PID via CGSConnectionGetPID,
//     then compare PIDs directly. (CGSGetConnectionIDForPID is REMOVED in 26.)
//
// The Prime-Invariant-aligned rule (Invariant 19): validation must NEVER block an
// action on something it cannot perform. When the framework is unavailable, the
// owner lookup errors, or NEITHER strategy can run, we ASSUME VALID (return true)
// and let the action proceed — only a CONFIRMED mismatch returns false. This file
// is the pure decision tier: the live SkyLight lookups are injected via
// `WindowOwnerLookups`, faked on Linux and dlsym-backed in Kit (US-029).

/// The owner-lookup operations the validator needs. Each returns `nil` when the
/// underlying SPI is absent or errored (the "cannot perform" signal that drives
/// assume-valid); a non-nil value is a confirmed result.
public protocol WindowOwnerLookups {
    /// Port of `skylight.is_available()`: framework loaded AND main connection != 0.
    /// When false the validator short-circuits to assume-valid.
    var isAvailable: Bool { get }

    /// `CGSGetWindowOwner(mainCid, windowId)` → owner connection id, or `nil` on
    /// CGS error / missing symbol (assume-valid — do not trigger a re-resolve).
    func windowOwnerConnectionId(windowId: UInt32) -> UInt32?

    /// Strategy 1 (pre-26): `CGSGetConnectionIDForPID(mainCid, pid)` → that PID's
    /// connection id, or `nil` when the symbol is absent (removed in macOS 26) or
    /// the call failed.
    func connectionId(forPid pid: Int32) -> UInt32?

    /// Strategy 2 (26+): `CGSConnectionGetPID(ownerCid)` → owning PID, or `nil`
    /// when the symbol is absent or the call failed.
    func pid(forConnectionId connectionId: UInt32) -> Int32?
}

public enum WindowOwnerValidator {
    /// Returns `true` if the window still belongs to `expectedPid` OR validation
    /// could not be performed (assume-valid); `false` only on a CONFIRMED mismatch.
    public static func validate(
        windowId: UInt32,
        expectedPid: Int32,
        lookups: WindowOwnerLookups
    ) -> Bool {
        // Framework / connection unavailable — can't validate, assume correct.
        guard lookups.isAvailable else { return true }

        // Owner lookup itself failed (CGS error or symbol absent) — assume correct;
        // do NOT trigger an expensive re-resolve on an unperformable check.
        guard let ownerCid = lookups.windowOwnerConnectionId(windowId: windowId) else {
            return true
        }

        // Strategy 1: compare connection ids (pre-26 path).
        if let expectedCid = lookups.connectionId(forPid: expectedPid) {
            return ownerCid == expectedCid
        }

        // Strategy 2: reverse-lookup the owner connection id → PID, compare PIDs.
        if let ownerPid = lookups.pid(forConnectionId: ownerCid) {
            return ownerPid == expectedPid
        }

        // Neither strategy could run — assume valid, never block.
        return true
    }
}
