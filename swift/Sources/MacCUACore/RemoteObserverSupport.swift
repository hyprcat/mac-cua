// Remote-aware AX observer registration decision (US-059).
//
// Chromium / Electron (Blink) apps short-circuit AX notification delivery while
// their window is OCCLUDED: the public `AXObserverAddNotification` registration
// stops the app pushing change notifications when nothing is on-screen. The
// private HIServices SPI `_AXObserverAddNotificationAndCheckRemote` marks the
// observer "remote-aware" so those apps keep firing notifications even when
// occluded.
//
// IMPORTANT — this is an OPTIMIZATION, not a correctness fix. The AX tree
// re-walk is always the source of truth, so a missed notification never produces
// a wrong tree; it only delays the moment we learn the tree settled. Adopting
// the remote-aware registration improves occluded-Electron notification liveness
// and makes settle timing (the "wait until quiet" poll) reliable for those apps.
//
// The private symbol is resolved INDIVIDUALLY at runtime in Kit (dlsym via the
// shim's `csky_resolve_symbol`) and is NEVER a hard link dependency (Invariant
// 17). Its absence must degrade silently: the caller would fall back to the
// public `AXObserverAddNotification`, which is always available. This file holds
// the PURE, Linux-testable half — the decision of WHICH registration API to use,
// modelled (like `SkyLightSymbols.swift`) as a function of two injected facts:
// "did the private symbol resolve?" and "is the feature flag on?".
//
// DORMANT (no active caller). mac-cua's settle/staleness system is POLLING-based
// by design (§5.3): it deliberately removed the AXObserver correctness path in
// favour of `SettlePoller` + liveness-probe re-walk (see `Observer.swift`,
// `AXStaleness.swift`, `KitRunLoop.swift`). There is therefore NO
// `AXObserverAddNotification` registration in the codebase to upgrade — the
// occluded-Electron notification-pause problem this SPI solves does not arise
// when you never depend on notifications. This decision + the shim typedef +
// the `electron_remote_observer` kill-switch flag are kept as documented,
// tested, parity-complete capability: if a future optional observer-driven
// settle *accelerator* is ever layered on top of polling, this is the
// invariant-safe chooser it would use. Until then it is intentionally unwired.

/// Which AX-observer registration API to use (US-059). Pure so it's Linux-testable.
public enum AXObserverRegistration: String, Sendable, Equatable {
    /// `_AXObserverAddNotificationAndCheckRemote` — keeps occluded Electron AX live.
    case remoteAware
    /// `AXObserverAddNotification` — the always-available public fallback.
    case publicAPI
}

/// Pure chooser for the AX-observer registration API (US-059).
///
/// Correctness is unaffected either way: the AX tree re-walk is the source of
/// truth, so this decision only governs notification *liveness* (and therefore
/// settle timing) for occluded Chromium/Electron windows. Choosing
/// `remoteAware` requires BOTH that the private SPI actually resolved on this
/// host AND that the feature flag is enabled. In every other case — flag off, or
/// the symbol absent/removed — we choose `publicAPI`. Because the private symbol
/// is never required (Invariant 17), a host where it is missing simply degrades
/// to `publicAPI`; an enabled flag can never force a dependency on an absent
/// symbol.
public enum RemoteObserverSupport {
    /// Choose the registration API. Returns `remoteAware` iff the private symbol
    /// resolved AND the feature flag is enabled; otherwise `publicAPI`.
    ///
    /// - Parameters:
    ///   - remoteSymbolResolved: whether
    ///     `_AXObserverAddNotificationAndCheckRemote` resolved at runtime. When
    ///     `false` (absent/removed) the result is always `publicAPI`, so the
    ///     private symbol is never a hard dependency (Invariant 17).
    ///   - flagEnabled: whether the US-059 feature flag is on. When `false` we
    ///     use the public API even if the symbol is present.
    /// - Returns: the registration API the Kit observer should use.
    public static func registration(remoteSymbolResolved: Bool, flagEnabled: Bool) -> AXObserverRegistration {
        (remoteSymbolResolved && flagEnabled) ? .remoteAware : .publicAPI
    }
}
