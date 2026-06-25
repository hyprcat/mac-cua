// ClickPrimerPolicy.swift — Chromium "user-activation primer" decision (US-057),
// PURE Core tier.
//
// Modern Chromium-class web content (browsers and Electron apps) gates
// "trusted" pointer input behind a *user-activation* signal: a synthetic click
// that the engine has not seen preceded by a recent genuine-looking
// down/up gesture may be treated as untrusted, so behaviors that require user
// activation (focus, paste, popups, some `click` handlers) silently no-op. To
// tick that gate, the driver fires an off-screen *decoy* down/up pair
// immediately before the real pixel click — a throwaway gesture that lands
// nowhere (well outside any window's content) purely to advance Chromium's
// user-activation state machine. The real click that follows is then trusted.
//
// Invariant-safety (Inv 18 — Prime Invariant): the primer NEVER foregrounds,
// activates, or raises the target. It is posted per-pid (pid-scoped, like every
// other event in this codebase — Inv 1) at an off-screen coordinate, so it
// neither moves the user's cursor nor changes window order. It is a pure
// gate-tick, invisible and side-effect-free at the window-server level.
//
// This file holds ONLY the Linux-pure decision of *whether* to prime. The
// off-screen coordinate selection and the actual event posting live in
// MacCUAKit; the event-sequence *shape* (the extra down/up pair) lives in
// `ClickDelivery.sequence(count:includePrimer:)`. There is no Python reference
// for this — it is a Codex-parity / hardening feature.

// MARK: - Click kind

/// Whether a click is delivered as raw pixel/coordinate input or as an
/// accessibility action on a resolved element.
public enum ClickKind: Sendable, Equatable {
    /// A coordinate/pixel click — a real synthetic pointer down/up at an (x, y).
    /// This is the only kind that benefits from the user-activation primer,
    /// because it is the only one that flows through Chromium's pointer-input
    /// trust gate.
    case pixel
    /// An `element_index` AX-action click (e.g. `AXPress` on a resolved node).
    /// AX actions bypass the pointer pipeline entirely, so the primer is
    /// irrelevant to them.
    case axAction
}

// MARK: - Primer decision

public enum ClickPrimerPolicy {
    /// Whether the Chromium user-activation primer (US-057) should fire before a
    /// click.
    ///
    /// Returns `true` iff ALL of the following hold:
    ///   1. `flagEnabled` — the feature flag is on (the primer is opt-in; the
    ///      flag/spine wiring lives outside Core).
    ///   2. `surface` is a Chromium-class surface — a `.browser` or `.electron`
    ///      app (the same web-content family that `EnhancedUIPolicy.shouldEnable`
    ///      targets). These are the only surfaces with a Chromium
    ///      user-activation gate to tick.
    ///   3. `clickKind` is `.pixel` — a coordinate click that actually flows
    ///      through the pointer-input trust gate. An `.axAction` click bypasses
    ///      the pointer pipeline, so a primer would do nothing for it.
    ///
    /// Everywhere else the primer is a deliberate no-op: native Cocoa / Java / Qt
    /// apps have no Chromium gate (and we must not perturb them), AX-action
    /// clicks never reach the gate, and a non-Chromium surface would simply
    /// discard the decoy gesture. Off-screen, pid-scoped, and raising nothing,
    /// the primer is invariant-safe under Inv 18 (never foreground/activate/raise).
    public static func shouldPrime(surface: AppType, clickKind: ClickKind, flagEnabled: Bool) -> Bool {
        guard flagEnabled else { return false }
        guard clickKind == .pixel else { return false }
        switch surface {
        case .browser, .electron:
            return true
        case .nativeCocoa, .java, .qt, .unknown:
            return false
        }
    }
}
