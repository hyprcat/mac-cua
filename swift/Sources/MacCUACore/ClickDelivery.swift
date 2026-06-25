// Click event-sequence plan (US-032, C1) — PURE Core half.
//
// A "real" background click is a down/up CGEvent pair (Inv 1: posted per-pid,
// never a global post or a cursor warp). For multi-click (double/triple) the
// pair repeats with an increasing `clickState` so the target app recognizes the
// gesture. This file is the load-bearing, drift-prone description of that
// sequence — which events, in which order, with which clickState/pressure — kept
// pure so it is unit-tested on Linux. Both the CGEvent base path (US-028) and the
// SkyLight targeted path (US-030/C2) in `KitInputProvider` consume it so the two
// transports stay byte-for-byte identical in their event shape; only the post
// mechanism differs.
//
// `eventNumber` is intentionally NOT part of the plan: it is a monotonic
// per-provider counter assigned by Kit at post time (one increment per emitted
// event), so down/up pairs carry strictly increasing numbers across a whole
// session, not just within one click.

/// One synthetic mouse event in a click gesture.
public struct ClickEventStep: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case down
        case up
    }

    public let phase: Phase
    /// 1-based click index within the gesture (1 = single, 2 = double, …). The
    /// window server reads this from `kCGMouseEventClickState`.
    public let clickState: Int
    /// Pressure rides on the event: full on down, zero on up.
    public let pressure: Double
    /// True for the off-screen Chromium user-activation *primer* pair (US-057):
    /// a throwaway decoy down/up posted before the real click to tick Chromium's
    /// user-activation gate. Kit reads this to post the step at the off-screen
    /// decoy coordinate (pid-scoped, no raise — Inv 18) instead of the real
    /// target point. False for every real click step.
    public let isPrimer: Bool

    /// `isPrimer` defaults to `false` so existing call sites and their event
    /// shape stay byte-identical (a real click is never a primer).
    public init(phase: Phase, clickState: Int, pressure: Double, isPrimer: Bool = false) {
        self.phase = phase
        self.clickState = clickState
        self.pressure = pressure
        self.isPrimer = isPrimer
    }
}

public enum ClickDelivery {
    public static let downPressure: Double = 1.0
    public static let upPressure: Double = 0.0

    /// The ordered down/up steps for an N-count click. `count` is clamped to at
    /// least 1 (a non-positive count still yields a single click). Each click is a
    /// down (pressure 1.0) followed by an up (pressure 0.0) carrying the same
    /// 1-based `clickState`.
    public static func sequence(count: Int) -> [ClickEventStep] {
        let n = max(1, count)
        var steps: [ClickEventStep] = []
        steps.reserveCapacity(n * 2)
        for clickNum in 1...n {
            steps.append(ClickEventStep(phase: .down, clickState: clickNum, pressure: downPressure))
            steps.append(ClickEventStep(phase: .up, clickState: clickNum, pressure: upPressure))
        }
        return steps
    }

    /// The off-screen Chromium user-activation primer pair (US-057): a single
    /// throwaway down/up that ticks Chromium's user-activation gate so the real
    /// click that follows is trusted. It is a *discard* gesture — it carries
    /// zero pressure on BOTH events (it is never meant to register as a real
    /// press) and `clickState` 1 (a lone single click). Kit posts it at an
    /// off-screen, pid-scoped coordinate, raising nothing (Inv 18).
    public static func primerPair() -> [ClickEventStep] {
        [
            ClickEventStep(phase: .down, clickState: 1, pressure: upPressure, isPrimer: true),
            ClickEventStep(phase: .up, clickState: 1, pressure: upPressure, isPrimer: true),
        ]
    }

    /// The ordered steps for an N-count click, optionally prefixed by the
    /// Chromium user-activation primer pair (US-057).
    ///
    /// When `includePrimer` is `true`, exactly ONE primer down/up pair
    /// (`isPrimer: true`, pressure 0.0 on both, `clickState` 1) is PREPENDED
    /// before the normal real-click steps from `sequence(count:)`. When it is
    /// `false`, the result is exactly `sequence(count:)` — the real steps are
    /// never altered, only preceded.
    public static func sequence(count: Int, includePrimer: Bool) -> [ClickEventStep] {
        let real = sequence(count: count)
        guard includePrimer else { return real }
        return primerPair() + real
    }
}
