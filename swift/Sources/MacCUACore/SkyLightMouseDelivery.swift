// SkyLight targeted-mouse-delivery field plan (US-030, C2) — PURE Core half.
//
// Targeted mouse delivery (background, no foregrounding) builds an NSEvent-backed
// CGEvent (`+[NSEvent mouseEventWithType:...windowNumber:...].CGEvent`) for proper
// window association, then STAMPS the event so the window server routes it to the
// target window/pid without the visible cursor ever moving:
//
//   • subtype field (7)               = 3   (`kCGMouseEventSubtype` tablet-proximity)
//   • windowUnderPointer (91)         = windowId
//   • windowUnderPointerThatCanHandle (92) = windowId
//   • window-local coordinates        via `CGEventSetWindowLocation` (Kit)
//   • target pid field (40)           via `SLEventSetIntegerValueField(e, 40, pid)` (Kit)
//   • post                            via `SLEventPostToPid(pid, e)` (Kit)
//
// The branch of *which* fields get *which* values — the load-bearing, drift-prone
// part — is pure here and unit-tested on Linux. The macOS NSEvent/CGEvent wiring
// and the dlsym'd `SLEvent*` calls live in `KitSkyLightProvider` behind
// `#if os(macOS)`.
//
// Prime-Invariant posture: this path delivers to a *background* pid via the
// per-PID SkyLight post; it never warps the cursor, never activates, never
// foregrounds. The 91/92 window hints + window-local coords are routing metadata,
// not a cursor move (Inv 1, 2).

/// A single integer field stamp `(field, value)` applied to a CGEvent. Two setters
/// exist: CoreGraphics' `CGEventSetIntegerValueField` (for the public 7/91/92
/// fields) and SkyLight's private `SLEventSetIntegerValueField` (for field 40 =
/// pid). The plan keeps them in separate lists so Kit applies each via the right
/// function.
public struct SkyLightFieldStamp: Equatable, Sendable {
    public let field: UInt32
    public let value: Int64
    public init(field: UInt32, value: Int64) {
        self.field = field
        self.value = value
    }
}

public enum SkyLightMouseDelivery {
    /// Stamps applied via the PUBLIC `CGEvent.setIntegerValueField` on the
    /// NSEvent-derived CGEvent: subtype=3 plus the two window-association hints.
    public static func cgStamps(windowId: Int) -> [SkyLightFieldStamp] {
        [
            SkyLightFieldStamp(
                field: CGEventFieldNumber.mouseEventSubtype,
                value: CGMouseEventSubtypeValue.tabletProximity),
            SkyLightFieldStamp(
                field: CGEventFieldNumber.mouseEventWindowUnderMousePointer,
                value: Int64(windowId)),
            SkyLightFieldStamp(
                field: CGEventFieldNumber.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                value: Int64(windowId)),
        ]
    }

    /// Stamps applied via the PRIVATE `SLEventSetIntegerValueField`: target pid in
    /// field 40 so the window server posts the event to that process.
    public static func skyStamps(pid: Int) -> [SkyLightFieldStamp] {
        [SkyLightFieldStamp(field: SkyLightEventField.pid, value: Int64(pid))]
    }
}
