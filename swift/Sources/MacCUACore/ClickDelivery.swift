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

    public init(phase: Phase, clickState: Int, pressure: Double) {
        self.phase = phase
        self.clickState = clickState
        self.pressure = pressure
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
}
