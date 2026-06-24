import Foundation

// US-006: CGEvent field-constant table (Core).
//
// Every CGEvent field number, flag mask, source-state id, mouse button, and the
// SkyLight integer field used by the Mac input layer, declared once as named Core
// constants so the macOS `InputProvider`/`CSkyLightShim` impl cannot transpose a
// magic number. Values are verified against docs/CODEX_PARITY_CHANGES.md Appendix.
//
// These are PURE integer constants — no CoreGraphics import — so Core/Server stay
// Linux-green. The Mac impl maps these onto `CGEventField(rawValue:)` etc.

/// `CGEventField` raw values (CoreGraphics public header, some "advanced").
public enum CGEventFieldNumber {
    // Mouse
    public static let mouseEventNumber: UInt32 = 0
    public static let mouseEventClickState: UInt32 = 1
    public static let mouseEventPressure: UInt32 = 2
    public static let mouseEventButtonNumber: UInt32 = 3
    public static let mouseEventDeltaX: UInt32 = 4
    public static let mouseEventDeltaY: UInt32 = 5
    public static let mouseEventSubtype: UInt32 = 7

    // Keyboard
    public static let keyboardEventKeycode: UInt32 = 9

    // Scroll — line/integer deltas
    public static let scrollWheelEventDeltaAxis1: UInt32 = 11
    public static let scrollWheelEventDeltaAxis2: UInt32 = 12
    public static let scrollWheelEventDeltaAxis3: UInt32 = 13

    // Scroll — fixed-point deltas (double, native Cocoa)
    public static let scrollWheelEventFixedPtDeltaAxis1: UInt32 = 93
    public static let scrollWheelEventFixedPtDeltaAxis2: UInt32 = 94
    public static let scrollWheelEventFixedPtDeltaAxis3: UInt32 = 95

    // Scroll — point deltas (integer px, Chromium/Electron)
    public static let scrollWheelEventPointDeltaAxis1: UInt32 = 96
    public static let scrollWheelEventPointDeltaAxis2: UInt32 = 97
    public static let scrollWheelEventPointDeltaAxis3: UInt32 = 98

    // Scroll — phase/continuity
    public static let scrollWheelEventIsContinuous: UInt32 = 88
    public static let scrollWheelEventScrollPhase: UInt32 = 99

    // Window association (mouse)
    public static let mouseEventWindowUnderMousePointer: UInt32 = 91
    public static let mouseEventWindowUnderMousePointerThatCanHandleThisEvent: UInt32 = 92

    // Source-state id field (echo-match for delivery-tap confirmation, C5)
    public static let eventSourceStateID: UInt32 = 45
}

/// SkyLight `SLEventSetIntegerValueField` field numbers.
public enum SkyLightEventField {
    /// Field 40 = target pid (`SLEventSetIntegerValueField(e, 40, pid)`).
    public static let pid: UInt32 = 40
}

/// `CGEventSourceStateID` raw values. We use `private` (-1) for the per-session source.
public enum CGEventSourceStateIDValue {
    public static let privateState: Int32 = -1
    public static let combinedSessionState: Int32 = 0
    public static let hidSystemState: Int32 = 1
}

/// `CGMouseButton` raw values.
public enum CGMouseButtonNumber {
    public static let left: UInt32 = 0
    public static let right: UInt32 = 1
    public static let center: UInt32 = 2
}

/// Mouse subtype value stamped on SkyLight-routed mouse events
/// (`kCGMouseEventSubtype(7) = 3`).
public enum CGMouseEventSubtypeValue {
    public static let tabletProximity: Int64 = 3
}

/// `CGEventFlags` masks (modifier keys). Values match CoreGraphics' public masks.
public enum CGEventFlagMask {
    public static let shift: UInt64 = 0x20000
    public static let control: UInt64 = 0x40000
    public static let alternate: UInt64 = 0x80000
    public static let command: UInt64 = 0x100000
}
