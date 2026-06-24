// KitInputProvider — the CGEvent base input path (US-028).
//
// This is the ALWAYS-AVAILABLE native delivery path, a faithful port of the
// base (non-confirmed) functions in `app/_lib/input.py`. It obeys the Prime
// Invariant by construction:
//
//   • Delivery is ONLY via `CGEvent.postToPid(_:)` — never `post(tap:)` / the
//     global `CGEventPost`. (Inv 1)
//   • The cursor is NEVER warped: there is no `CGWarpMouseCursorPosition` and no
//     `kCGEventMouseMoved` pre-positioning (a posted mouse-move would leak to the
//     visible cursor). The down/up events carry the target point directly; the
//     `windowUnderMousePointer` field hints handle hit-test routing. (Inv 2)
//   • Modifiers ride as flags on the key event (`CGEventSetFlags`), never as
//     discrete `flagsChanged` via postToPid (which would corrupt the user's live
//     modifier state). (Inv 3)
//   • Each session uses a private `CGEventSource(stateID: .privateState)`. (Inv 4)
//   • Scroll sets BOTH integer point deltas and fixed-point deltas so both
//     Chromium and native Cocoa scroll. (Inv 6 — refined further in US-035.)
//   • On failure these throw honestly; there is NO foregrounding fallback. (Inv 18)
//
// The branchy arithmetic (coordinate conversion, scroll deltas, button table,
// text-key coercion) is the pure `MacCUACore.InputCoords` / `KeyParser`, unit-
// tested on Linux. This file is the thin macOS CGEvent wiring.
//
// The SkyLight targeted-delivery path (US-030/031), the per-app delivery ordering
// (US-032), Unicode per-grapheme typing (US-033), press-key timing (US-034), and
// confirmed delivery (US-037) build on top of this base.

#if os(macOS)
import Foundation
import CoreGraphics
import MacCUACore

/// Real per-session synthetic-event source: a private `CGEventSource`
/// (`stateID == .privateState`, raw -1) so concurrent sessions never share HID
/// state and the events are tagged for the delivery-confirmation tap (C5).
public final class KitEventSource: EventSource {
    let source: CGEventSource?
    public init() {
        self.source = CGEventSource(stateID: .privateState)
    }
    init(source: CGEventSource?) {
        self.source = source
    }
}

public final class KitInputProvider: InputProvider {
    /// Module-level private source used when a call supplies no per-session
    /// source (mirrors input.py's module `_source`).
    private let defaultSource: CGEventSource?

    /// Mouse event-number counter (input.py `_MouseEventCounter`). A monotonic
    /// per-provider counter so down/up pairs carry increasing numbers; guarded by
    /// a lock since the spine may post from different threads.
    private let counterLock = NSLock()
    private var mouseEventNumber: Int64 = 0

    /// Optional SkyLight targeted-delivery path (US-030, C2). When present and the
    /// host resolves the SkyLight mouse symbols, a window-relative click is
    /// delivered window-stamped (better fidelity for Chromium/Electron, which
    /// hit-test against the window-server window) and falls through to the CGEvent
    /// base path on ANY failure (Inv 18 — never foregrounds). Absent on Linux/CI
    /// and on hosts where the symbols don't resolve, so the CGEvent path is the
    /// guaranteed transport.
    private let skyLight: KitSkyLightProvider?

    public init(skyLight: KitSkyLightProvider? = nil) {
        self.defaultSource = CGEventSource(stateID: .privateState)
        self.skyLight = skyLight
    }

    public func createEventSource() -> EventSource {
        KitEventSource()
    }

    private func resolveSource(_ source: EventSource?) -> CGEventSource? {
        if let kit = source as? KitEventSource { return kit.source }
        return defaultSource
    }

    private func nextEventNumber() -> Int64 {
        counterLock.lock()
        defer { counterLock.unlock() }
        mouseEventNumber += 1
        return mouseEventNumber
    }

    // MARK: - Field helpers

    private static func field(_ raw: UInt32) -> CGEventField {
        CGEventField(rawValue: raw)!
    }

    // MARK: - Coordinate conversion

    public func windowToScreenCoords(
        windowId: Int, x: Double, y: Double,
        screenshotSize: (width: Int, height: Int)?
    ) -> (x: Double, y: Double)? {
        guard let bounds = windowBounds(windowId: windowId) else { return nil }
        return InputCoords.windowToScreenCoords(
            windowBounds: bounds, x: x, y: y, screenshotSize: screenshotSize)
    }

    /// Read-only window-bounds lookup via `CGWindowListCopyWindowInfo`. Never
    /// foregrounds (Inv 7/13) — it only reads the window-server snapshot.
    private func windowBounds(windowId: Int) -> Rect? {
        guard let cgWindowId = CGWindowID(exactly: windowId) else { return nil }
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], cgWindowId) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return Rect(x: Double(rect.origin.x), y: Double(rect.origin.y),
                    w: Double(rect.size.width), h: Double(rect.size.height))
    }

    // MARK: - Mouse decoration

    private func decorateMouseEvent(
        _ event: CGEvent, windowId: Int?, pressure: Double,
        clickState: Int64? = nil, eventNumber: Int64? = nil
    ) {
        if let clickState {
            event.setIntegerValueField(
                Self.field(CGEventFieldNumber.mouseEventClickState), value: clickState)
        }
        if let eventNumber {
            event.setIntegerValueField(
                Self.field(CGEventFieldNumber.mouseEventNumber), value: eventNumber)
        }
        event.setDoubleValueField(
            Self.field(CGEventFieldNumber.mouseEventPressure), value: pressure)
        if let windowId {
            // Target = windowUnderMousePointer (+ ThatCanHandle) hint, NOT a warp.
            event.setIntegerValueField(
                Self.field(CGEventFieldNumber.mouseEventWindowUnderMousePointer),
                value: Int64(windowId))
            event.setIntegerValueField(
                Self.field(CGEventFieldNumber.mouseEventWindowUnderMousePointerThatCanHandleThisEvent),
                value: Int64(windowId))
        }
    }

    private static let mousePressure: Double = 1.0

    private func mouseEventTypes(for button: MouseButton) -> (down: CGEventType, up: CGEventType) {
        switch button {
        case .left: return (.leftMouseDown, .leftMouseUp)
        case .right: return (.rightMouseDown, .rightMouseUp)
        case .middle: return (.otherMouseDown, .otherMouseUp)
        }
    }

    // MARK: - Click

    private func postClick(
        pid: Int, point: CGPoint, button: MouseButton, count: Int,
        windowId: Int?, source: CGEventSource?
    ) throws {
        let (downType, upType) = mouseEventTypes(for: button)
        let btn = CGMouseButton(rawValue: button.buttonNumber)!

        // The down/up sequence (incl. multi-click clickState) is the pure
        // `ClickDelivery` plan — shared with the SkyLight path so both transports
        // emit byte-identical event shapes.
        for step in ClickDelivery.sequence(count: count) {
            switch step.phase {
            case .down:
                if step.clickState > 1 { Thread.sleep(forTimeInterval: 0.1) }
                guard let down = CGEvent(
                    mouseEventSource: source, mouseType: downType,
                    mouseCursorPosition: point, mouseButton: btn) else {
                    throw AutomationError.cgEvent("\(CGEventError.failedToCreate): mouseDown")
                }
                decorateMouseEvent(down, windowId: windowId, pressure: step.pressure,
                                   clickState: Int64(step.clickState), eventNumber: nextEventNumber())
                down.postToPid(pid_t(pid))
                Thread.sleep(forTimeInterval: 0.005)
            case .up:
                guard let up = CGEvent(
                    mouseEventSource: source, mouseType: upType,
                    mouseCursorPosition: point, mouseButton: btn) else {
                    throw AutomationError.cgEvent("\(CGEventError.failedToCreate): mouseUp")
                }
                decorateMouseEvent(up, windowId: windowId, pressure: step.pressure,
                                   clickState: Int64(step.clickState), eventNumber: nextEventNumber())
                up.postToPid(pid_t(pid))
            }
        }
    }

    /// Attempt the SkyLight targeted (window-stamped) click for a window-relative
    /// click. Returns `false` on ANY failure so the caller falls through to the
    /// guaranteed CGEvent base path — NEVER foregrounds (Inv 18). The down/up
    /// sequence is the same pure `ClickDelivery` plan as the CGEvent path.
    private func trySkyLightClick(
        pid: Int, windowId: Int, windowLocalPoint: CGPoint,
        button: MouseButton, count: Int
    ) -> Bool {
        guard let sky = skyLight, sky.capabilities.canDeliverMouse else { return false }
        let (downType, upType) = mouseEventTypes(for: button)
        let btn = CGMouseButton(rawValue: button.buttonNumber)!

        for step in ClickDelivery.sequence(count: count) {
            let type = step.phase == .down ? downType : upType
            if step.phase == .down, step.clickState > 1 { Thread.sleep(forTimeInterval: 0.1) }
            let delivered = sky.deliverMouse(
                pid: pid, windowId: windowId, windowLocalPoint: windowLocalPoint,
                type: type, button: btn, clickCount: step.clickState,
                pressure: step.pressure, eventNumber: Int(nextEventNumber()))
            if !delivered { return false }
            if step.phase == .down { Thread.sleep(forTimeInterval: 0.005) }
        }
        return true
    }

    public func clickAt(
        pid: Int, windowId: Int, x: Double, y: Double,
        button: String, count: Int,
        screenshotSize: (width: Int, height: Int)?, source: EventSource?
    ) throws {
        guard let mb = MouseButton(name: button) else {
            throw AutomationError.input("Unknown mouse button: \(button)")
        }
        guard let bounds = windowBounds(windowId: windowId) else {
            throw AutomationError.input("Cannot resolve window \(windowId)")
        }
        // Fidelity-first: try the window-stamped SkyLight path (C2); it routes to
        // the window server's hit-test, which Chromium/Electron honor. Falls
        // through to the CGEvent base path on any failure (no foregrounding).
        let local = InputCoords.windowLocalPoint(
            windowBounds: bounds, x: x, y: y, screenshotSize: screenshotSize)
        if trySkyLightClick(
            pid: pid, windowId: windowId,
            windowLocalPoint: CGPoint(x: local.x, y: local.y),
            button: mb, count: count) {
            return
        }
        let screen = InputCoords.windowToScreenCoords(
            windowBounds: bounds, x: x, y: y, screenshotSize: screenshotSize)
        try postClick(pid: pid, point: CGPoint(x: screen.x, y: screen.y),
                      button: mb, count: count, windowId: windowId,
                      source: resolveSource(source))
    }

    public func clickAtScreenPoint(
        pid: Int, x: Double, y: Double, button: String, count: Int,
        windowId: Int?, source: EventSource?
    ) throws {
        guard let mb = MouseButton(name: button) else {
            throw AutomationError.input("Unknown mouse button: \(button)")
        }
        try postClick(pid: pid, point: CGPoint(x: x, y: y),
                      button: mb, count: count, windowId: windowId,
                      source: resolveSource(source))
    }

    // MARK: - Drag

    public func drag(
        pid: Int, windowId: Int,
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        screenshotSize: (width: Int, height: Int)?, source: EventSource?
    ) throws {
        guard let from = windowToScreenCoords(
                windowId: windowId, x: fromX, y: fromY, screenshotSize: screenshotSize),
              let to = windowToScreenCoords(
                windowId: windowId, x: toX, y: toY, screenshotSize: screenshotSize) else {
            throw AutomationError.input("Cannot resolve window \(windowId)")
        }
        let src = resolveSource(source)
        let btn = CGMouseButton.left

        guard let down = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: from.x, y: from.y), mouseButton: btn) else {
            throw AutomationError.cgEvent("\(CGEventError.failedToCreate): mouseDragged down")
        }
        decorateMouseEvent(down, windowId: windowId, pressure: Self.mousePressure)
        down.postToPid(pid_t(pid))

        Thread.sleep(forTimeInterval: 0.02)

        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let ix = from.x + (to.x - from.x) * t
            let iy = from.y + (to.y - from.y) * t
            if let dragEvent = CGEvent(
                mouseEventSource: src, mouseType: .leftMouseDragged,
                mouseCursorPosition: CGPoint(x: ix, y: iy), mouseButton: btn) {
                decorateMouseEvent(dragEvent, windowId: windowId, pressure: Self.mousePressure)
                dragEvent.postToPid(pid_t(pid))
            }
            Thread.sleep(forTimeInterval: 0.005)
        }

        guard let up = CGEvent(
            mouseEventSource: src, mouseType: .leftMouseUp,
            mouseCursorPosition: CGPoint(x: to.x, y: to.y), mouseButton: btn) else {
            throw AutomationError.cgEvent("\(CGEventError.failedToCreate): mouseDragged up")
        }
        decorateMouseEvent(up, windowId: windowId, pressure: 0.0)
        up.postToPid(pid_t(pid))
    }

    // MARK: - Keyboard

    private static let keyHoldDelay = 0.008
    private static let keyEventDelay = 0.003

    private func postKeyEvent(
        pid: Int, keycode: Int, isDown: Bool, flags: UInt64, source: CGEventSource?
    ) throws {
        guard let event = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(keycode), keyDown: isDown) else {
            throw AutomationError.cgEvent(
                "\(CGEventError.failedToCreate): keycode=\(keycode), down=\(isDown)")
        }
        event.flags = CGEventFlags(rawValue: flags)
        event.postToPid(pid_t(pid))
    }

    /// Send a keycode as compound keyDown/keyUp with modifiers embedded in the
    /// flags — the safe postToPid path (Inv 3). Discrete `flagsChanged` is only
    /// used on the SkyLight path (US-031).
    private func postKeycodeWithModifiers(
        pid: Int, keycode: Int, modifiers: Int, source: CGEventSource?
    ) throws {
        try postKeyEvent(pid: pid, keycode: keycode, isDown: true,
                         flags: UInt64(modifiers), source: source)
        Thread.sleep(forTimeInterval: Self.keyHoldDelay)
        try postKeyEvent(pid: pid, keycode: keycode, isDown: false,
                         flags: UInt64(modifiers), source: source)
        Thread.sleep(forTimeInterval: Self.keyEventDelay)
    }

    private func postUnicodeChar(pid: Int, char: String, source: CGEventSource?) throws {
        var utf16 = Array(char.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            throw AutomationError.cgEvent("\(CGEventError.failedToCreate): unicode down")
        }
        down.flags = []
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.postToPid(pid_t(pid))

        Thread.sleep(forTimeInterval: Self.keyHoldDelay)

        guard let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw AutomationError.cgEvent("\(CGEventError.failedToCreate): unicode up")
        }
        up.flags = []
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.postToPid(pid_t(pid))

        Thread.sleep(forTimeInterval: Self.keyEventDelay)
    }

    public func pressKey(pid: Int, key: String, source: EventSource?) throws {
        // Pure plan (US-034): per-key down/up + inter-key interval timing, with
        // modifiers riding as flags — never discrete flagsChanged on postToPid
        // (Invariant 3). Timing is replayed faithfully so chords and held keys
        // both register.
        let plan: [TimedKeyEvent]
        do {
            plan = try PressKeyPlan.plan(for: key)
        } catch {
            throw AutomationError.input(String(describing: error))
        }
        let src = resolveSource(source)
        for step in plan {
            switch step.transition {
            case let .down(keycode, flags):
                try postKeyEvent(pid: pid, keycode: keycode, isDown: true,
                                 flags: UInt64(flags), source: src)
            case let .up(keycode, flags):
                try postKeyEvent(pid: pid, keycode: keycode, isDown: false,
                                 flags: UInt64(flags), source: src)
            }
            Thread.sleep(forTimeInterval: step.delayAfter)
        }
    }

    public func typeText(pid: Int, text: String, source: EventSource?) throws {
        let src = resolveSource(source)
        // Pure, per-grapheme plan (US-033): multi-scalar emoji / accented text
        // stays one Unicode keystroke; plain keys take the keycode path.
        for step in TypeTextPlan.plan(for: text) {
            switch step {
            case let .keycode(keycode, modifiers):
                try postKeycodeWithModifiers(pid: pid, keycode: keycode,
                                             modifiers: modifiers, source: src)
            case let .unicode(grapheme):
                try postUnicodeChar(pid: pid, char: grapheme, source: src)
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    // MARK: - Scroll

    private static let scrollStepDelay = 0.015

    public func scrollPid(
        pid: Int, x: Double, y: Double, direction: String, clicks: Int,
        windowId: Int?, source: EventSource?
    ) throws {
        let src = resolveSource(source)
        let (dy, dx) = InputCoords.lineScrollDeltas(direction: direction)
        let n = max(1, clicks)
        for i in 0..<n {
            guard let scroll = CGEvent(
                scrollWheelEvent2Source: src, units: .line, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else {
                throw AutomationError.cgEvent("CGEvent(scrollWheelEvent2Source:) returned NULL")
            }
            scroll.postToPid(pid_t(pid))
            if i < n - 1 { Thread.sleep(forTimeInterval: Self.scrollStepDelay) }
        }
    }

    public func scrollPidPixel(
        pid: Int, x: Double, y: Double, direction: String, pixels: Int,
        windowId: Int?, source: EventSource?
    ) throws {
        let src = resolveSource(source)
        // Pure field plan (US-035): sets EVERY delta axis so both Chromium
        // (point delta) and native Cocoa (fixedPt) scroll, plus coarse line
        // clicks for discrete-wheel apps — never integer-only (Inv 6 / M4).
        let f = InputCoords.pixelScrollFields(direction: direction, pixels: pixels)
        guard let scroll = CGEvent(
            scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2,
            wheel1: Int32(f.pointDy), wheel2: Int32(f.pointDx), wheel3: 0) else {
            throw AutomationError.cgEvent("CGEvent(scrollWheelEvent2Source:) returned NULL")
        }
        // Mark as a continuous (pixel) scroll.
        scroll.setIntegerValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventIsContinuous), value: Int64(f.isContinuous))
        // Line-click deltas — read by native Cocoa apps that only honor discrete wheel clicks.
        scroll.setIntegerValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventDeltaAxis1), value: Int64(f.lineDy))
        scroll.setIntegerValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventDeltaAxis2), value: Int64(f.lineDx))
        // Integer point deltas — read by Chromium-based apps.
        scroll.setIntegerValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventPointDeltaAxis1), value: Int64(f.pointDy))
        scroll.setIntegerValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventPointDeltaAxis2), value: Int64(f.pointDx))
        // Fixed-point deltas — read by native Cocoa apps.
        scroll.setDoubleValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis1), value: f.fixedDy)
        scroll.setDoubleValueField(
            Self.field(CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis2), value: f.fixedDx)
        scroll.postToPid(pid_t(pid))
    }
}
#endif
