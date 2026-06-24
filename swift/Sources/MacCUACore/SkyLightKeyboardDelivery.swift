// SkyLight targeted-keyboard-delivery plan (US-031, C3) — PURE Core half.
//
// Authenticated background keyboard delivery (no foregrounding, no corruption of
// the user's live modifier state) builds a CGEvent keyboard event, sets the
// modifiers as FLAGS on that event (never discrete `flagsChanged`), authenticates
// it via the ObjC `SLSEventAuthenticationMessage`, and delivers it on TWO routes:
//
//   1. authenticated SkyLight post to the target pid:
//        SLSEventAuthenticationMessage(+messageWithEventRecord:pid:version:)
//          -> SLEventSetAuthenticationMessage(e, msg) -> SLEventPostToPid(pid, e)
//   2. a secondary `CGEventPostToPSN(psn, e)` to the window OWNER, whose PSN is
//      resolved via SLSGetWindowOwner -> SLSGetConnectionPSN.
//
// The drift-prone, load-bearing part that is pure here: the modifier-mask ->
// CGEventFlags translation (C6 / Invariant 3 — modifiers ride as flags, NOT as
// discrete `flagsChanged` posted via postToPid, which would leak into and corrupt
// the user's physical-keyboard modifier state) and the catalogue of delivery
// routes. The macOS CGEvent construction, the ObjC auth-message call, the PSN
// resolution, and the dlsym'd SkyLight/CoreGraphics calls all live in
// `KitSkyLightProvider` behind `#if os(macOS)`.
//
// Prime-Invariant posture: every route targets a *background* pid/PSN via the
// per-PID / per-PSN post; nothing warps the cursor, activates, raises, or
// foregrounds. When the SkyLight keyboard capability is unavailable the Kit caller
// returns `false` and falls through to the CGEvent base path (US-028) — it NEVER
// foregrounds (Invariant 18).

/// The two delivery routes a single authenticated key event travels (C3). Modeled
/// as pure data so the dual-route contract is unit-testable on Linux.
public enum SkyLightKeyDeliveryRoute: Equatable, Sendable, CaseIterable {
    /// Authenticated SkyLight post to the target process id.
    case skyLightAuthenticatedPostToPid
    /// Secondary `CGEventPostToPSN` to the window owner's ProcessSerialNumber.
    case cgEventPostToOwnerPSN
}

public enum SkyLightKeyboardDelivery {
    /// Authenticated keyboard delivery always uses BOTH routes (C3): the
    /// authenticated SkyLight post to the pid PLUS the secondary post to the
    /// owner PSN.
    public static let deliveryRoutes: [SkyLightKeyDeliveryRoute] = [
        .skyLightAuthenticatedPostToPid,
        .cgEventPostToOwnerPSN,
    ]

    /// Translate a `KeyParser` modifier mask into the `CGEventFlags` raw value to
    /// apply via `CGEventSetFlags`. This is the C6 / Invariant 3 chokepoint:
    /// modifiers become FLAGS on the key event, never discrete `flagsChanged`
    /// events posted to the pid. The named `CGEventFlagMask` constants are used so
    /// the Mac impl cannot transpose a magic flag value.
    public static func cgEventFlags(modifierMask: Int) -> UInt64 {
        var flags: UInt64 = 0
        if modifierMask & KeyParser.maskShift != 0 { flags |= CGEventFlagMask.shift }
        if modifierMask & KeyParser.maskControl != 0 { flags |= CGEventFlagMask.control }
        if modifierMask & KeyParser.maskAlternate != 0 { flags |= CGEventFlagMask.alternate }
        if modifierMask & KeyParser.maskCommand != 0 { flags |= CGEventFlagMask.command }
        return flags
    }
}
