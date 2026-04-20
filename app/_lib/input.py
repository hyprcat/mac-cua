from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Any

from Quartz import (
    CGEventCreateMouseEvent,
    CGEventCreateKeyboardEvent,
    CGEventSetDoubleValueField,
    CGEventSetFlags,
    CGEventSetIntegerValueField,
    CGEventSourceCreate,
    CGEventPostToPid,
    kCGEventSourceStatePrivate,
    kCGEventMouseMoved,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventLeftMouseDragged,
    kCGEventRightMouseDown,
    kCGEventRightMouseUp,
    kCGEventOtherMouseDown,
    kCGEventOtherMouseUp,
    kCGMouseEventClickState,
    kCGMouseEventPressure,
    kCGMouseEventWindowUnderMousePointer,
    kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
    kCGMouseButtonLeft,
    kCGMouseButtonRight,
    kCGMouseButtonCenter,
    kCGMouseEventNumber,
)
from Quartz import (
    CGEventCreateScrollWheelEvent,
    kCGScrollEventUnitLine,
    kCGScrollEventUnitPixel,
    kCGScrollWheelEventPointDeltaAxis1,
    kCGScrollWheelEventPointDeltaAxis2,
    kCGScrollWheelEventFixedPtDeltaAxis1,
    kCGScrollWheelEventFixedPtDeltaAxis2,
)
from Quartz import CGPointMake

from app._lib import screenshot
from app._lib.errors import InputError, CGEventError
from app._lib.keys import parse_key_combo


_source = CGEventSourceCreate(kCGEventSourceStatePrivate)


def create_event_source() -> Any:
    """Create a new private CGEventSource for session isolation."""
    return CGEventSourceCreate(kCGEventSourceStatePrivate)

_BUTTON_MAP = {
    "left": (kCGMouseButtonLeft, kCGEventLeftMouseDown, kCGEventLeftMouseUp),
    "right": (kCGMouseButtonRight, kCGEventRightMouseDown, kCGEventRightMouseUp),
    "middle": (kCGMouseButtonCenter, kCGEventOtherMouseDown, kCGEventOtherMouseUp),
}

_DOUBLE_CLICK_INTERVAL = 0.1
_KEY_HOLD_DELAY = 0.008  # delay between key down and key up
_KEY_EVENT_DELAY = 0.003
_MOUSE_PRESSURE = 1.0
SCROLL_PIXEL_QUANTUM = 80
_LINE_DELTA = 5
class _MouseEventCounter:
    """Thread-safe per-module mouse event counter.

    Replaces the global _MOUSE_EVENT_NUMBER to avoid cross-session leakage.
    Each event source should ideally have its own counter, but since CGEvent
    doesn't expose per-source numbering, we use a thread-local counter.
    """

    def __init__(self) -> None:
        self._local = threading.local()

    def next(self) -> int:
        val = getattr(self._local, "value", 0) + 1
        self._local.value = val
        return val


_mouse_counter = _MouseEventCounter()

_TEXT_KEY_ALIASES = {
    "apostrophe": "'",
    "asciitilde": "~",
    "backslash": "\\",
    "comma": ",",
    "equal": "=",
    "grave": "`",
    "minus": "-",
    "period": ".",
    "quote": "'",
    "semicolon": ";",
    "slash": "/",
}


def _coerce_text_key(key: str) -> str | None:
    if "+" in key:
        return None

    if len(key) == 1 and key.isprintable() and key not in {"\t", "\r", "\n"}:
        return key

    return _TEXT_KEY_ALIASES.get(key.strip().lower())


def _post_key_event(pid: int, keycode: int, is_down: bool, flags: int, *, source: Any = None) -> None:
    src = source if source is not None else _source
    event = CGEventCreateKeyboardEvent(src, keycode, is_down)
    if event is None:
        raise CGEventError(f"cg_event_creation_failed: keycode={keycode}, down={is_down}")
    CGEventSetFlags(event, flags)
    CGEventPostToPid(pid, event)


def _post_keycode_with_modifiers(pid: int, keycode: int, modifiers: int, *, source: Any = None) -> None:
    """Send a key press as compound events (modifiers embedded in flags).

    This is the safe CGEventPostToPid path — modifier flags are set on the
    keyDown/keyUp events directly, NOT as separate flagsChanged events.
    Separate flagsChanged via CGEventPostToPid leak to the global modifier
    state and corrupt the user's keyboard.

    Discrete modifier sequences are only used in deliver_key_events()
    via the SkyLight path where they don't leak.
    """
    _post_key_event(pid, keycode, True, modifiers, source=source)
    time.sleep(_KEY_HOLD_DELAY)
    _post_key_event(pid, keycode, False, modifiers, source=source)
    time.sleep(_KEY_EVENT_DELAY)


def _post_unicode_char(pid: int, char: str, *, source: Any = None) -> None:
    from Quartz import CGEventKeyboardSetUnicodeString

    src = source if source is not None else _source
    down = CGEventCreateKeyboardEvent(src, 0, True)
    CGEventSetFlags(down, 0)
    CGEventKeyboardSetUnicodeString(down, len(char), char)
    CGEventPostToPid(pid, down)

    time.sleep(_KEY_HOLD_DELAY)

    up = CGEventCreateKeyboardEvent(src, 0, False)
    CGEventSetFlags(up, 0)
    CGEventKeyboardSetUnicodeString(up, len(char), char)
    CGEventPostToPid(pid, up)

    time.sleep(_KEY_EVENT_DELAY)



def window_to_screen_coords(
    window_id: int,
    x: float,
    y: float,
    screenshot_size: tuple[int, int] | None = None,
) -> tuple[float, float]:
    """Convert screenshot-pixel coords to screen-global points."""
    bounds = screenshot.get_window_bounds(window_id)
    if bounds is None:
        raise InputError(f"Cannot resolve window {window_id}")
    wx, wy, width, height = bounds

    local_x = x
    local_y = y
    if screenshot_size is not None:
        shot_width, shot_height = screenshot_size
        if shot_width > 0 and shot_height > 0:
            local_x = max(0.0, min(float(x), float(shot_width - 1)))
            local_y = max(0.0, min(float(y), float(shot_height - 1)))
            local_x = local_x * (width / shot_width)
            local_y = local_y * (height / shot_height)

    return (wx + local_x, wy + local_y)


def _decorate_mouse_event(
    event: Any,
    *,
    window_id: int | None,
    pressure: float,
    click_state: int | None = None,
    event_number: int | None = None,
) -> None:
    if click_state is not None:
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_state)
    if event_number is not None:
        CGEventSetIntegerValueField(event, kCGMouseEventNumber, event_number)
    CGEventSetDoubleValueField(event, kCGMouseEventPressure, pressure)
    if window_id is not None:
        CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, window_id)
        CGEventSetIntegerValueField(
            event,
            kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            window_id,
        )


def _post_click(
    pid: int,
    point: Any,
    button: str,
    count: int,
    *,
    window_id: int | None = None,
    source: Any = None,
) -> None:
    if button not in _BUTTON_MAP:
        raise InputError(f"Unknown mouse button: {button}")

    btn, down_type, up_type = _BUTTON_MAP[button]
    src = source if source is not None else _source

    # No mouse-move pre-positioning — CGEventPostToPid kCGEventMouseMoved
    # leaks to the visible cursor. The down/up events already carry the
    # target point; window_id hints handle hit-test routing.

    for click_num in range(1, count + 1):
        if click_num > 1:
            time.sleep(_DOUBLE_CLICK_INTERVAL)

        down = CGEventCreateMouseEvent(src, down_type, point, btn)
        if down is None:
            raise CGEventError("cg_event_creation_failed: mouseDown")
        _decorate_mouse_event(
            down,
            window_id=window_id,
            pressure=_MOUSE_PRESSURE,
            click_state=click_num,
            event_number=_mouse_counter.next(),
        )
        CGEventPostToPid(pid, down)

        time.sleep(0.005)  # brief hold between down and up

        up = CGEventCreateMouseEvent(src, up_type, point, btn)
        if up is None:
            raise CGEventError("cg_event_creation_failed: mouseUp")
        _decorate_mouse_event(
            up,
            window_id=window_id,
            pressure=0.0,
            click_state=click_num,
            event_number=_mouse_counter.next(),
        )
        CGEventPostToPid(pid, up)


def click_at(
    pid: int,
    window_id: int,
    x: float,
    y: float,
    button: str = "left",
    count: int = 1,
    screenshot_size: tuple[int, int] | None = None,
    *,
    source: Any = None,
) -> None:
    """Click at screenshot-pixel coordinates."""
    sx, sy = window_to_screen_coords(window_id, x, y, screenshot_size)
    _post_click(pid, CGPointMake(sx, sy), button, count, window_id=window_id, source=source)


def click_at_screen_point(
    pid: int,
    x: float,
    y: float,
    button: str = "left",
    count: int = 1,
    *,
    window_id: int | None = None,
    source: Any = None,
) -> None:
    """Click at screen-point coordinates (from AXPosition)."""
    _post_click(pid, CGPointMake(x, y), button, count, window_id=window_id, source=source)


def drag(
    pid: int,
    window_id: int,
    from_x: float,
    from_y: float,
    to_x: float,
    to_y: float,
    screenshot_size: tuple[int, int] | None = None,
    *,
    source: Any = None,
) -> None:
    sx1, sy1 = window_to_screen_coords(window_id, from_x, from_y, screenshot_size)
    sx2, sy2 = window_to_screen_coords(window_id, to_x, to_y, screenshot_size)

    from_point = CGPointMake(sx1, sy1)
    to_point = CGPointMake(sx2, sy2)
    src = source if source is not None else _source

    # No mouse-move pre-positioning — leaks to visible cursor.
    down = CGEventCreateMouseEvent(src, kCGEventLeftMouseDown, from_point, kCGMouseButtonLeft)
    if down is None:
        raise CGEventError("cg_event_creation_failed: mouseDragged down")
    _decorate_mouse_event(down, window_id=window_id, pressure=_MOUSE_PRESSURE)
    CGEventPostToPid(pid, down)

    time.sleep(0.02)

    steps = 10
    for i in range(1, steps + 1):
        t = i / steps
        ix = sx1 + (sx2 - sx1) * t
        iy = sy1 + (sy2 - sy1) * t
        drag_event = CGEventCreateMouseEvent(src, kCGEventLeftMouseDragged, CGPointMake(ix, iy), kCGMouseButtonLeft)
        if drag_event is not None:
            _decorate_mouse_event(
                drag_event,
                window_id=window_id,
                pressure=_MOUSE_PRESSURE,
            )
            CGEventPostToPid(pid, drag_event)
        time.sleep(0.005)

    up = CGEventCreateMouseEvent(src, kCGEventLeftMouseUp, to_point, kCGMouseButtonLeft)
    if up is None:
        raise CGEventError("cg_event_creation_failed: mouseDragged up")
    _decorate_mouse_event(up, window_id=window_id, pressure=0.0)
    CGEventPostToPid(pid, up)


def press_key(pid: int, key: str, *, source: Any = None) -> None:
    resolved_key = _coerce_text_key(key)
    if resolved_key == " ":
        resolved_key = "space"
    if resolved_key is None:
        resolved_key = key

    try:
        keycode, modifiers = parse_key_combo(resolved_key)
    except ValueError as exc:
        raise InputError(str(exc)) from exc

    _post_keycode_with_modifiers(pid, keycode, modifiers, source=source)


_SCROLL_STEP_DELAY = 0.015  # delay between individual scroll events


def _scroll_deltas(direction: str) -> tuple[int, int]:
    """Return (dy, dx) unit delta for a scroll direction."""
    if direction == "up":
        return (_LINE_DELTA, 0)
    elif direction == "down":
        return (-_LINE_DELTA, 0)
    elif direction == "left":
        return (0, _LINE_DELTA)
    elif direction == "right":
        return (0, -_LINE_DELTA)
    return (0, 0)


def scroll_pid(
    pid: int,
    x: float,
    y: float,
    direction: str,
    clicks: int = 5,
    *,
    window_id: int | None = None,
    source: Any = None,
) -> None:
    """Scroll via CGEventPostToPid — truly background, no cursor movement.

    Works for native Cocoa apps but silently ignored by browsers/Electron.
    """
    src = source if source is not None else _source

    dy, dx = _scroll_deltas(direction)
    for i in range(clicks):
        scroll = CGEventCreateScrollWheelEvent(src, kCGScrollEventUnitLine, 2, dy, dx)
        if scroll is None:
            raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
        CGEventPostToPid(pid, scroll)
        if i < clicks - 1:
            time.sleep(_SCROLL_STEP_DELAY)


def scroll_pid_pixel(
    pid: int,
    x: float,
    y: float,
    direction: str,
    pixels: int,
    *,
    window_id: int | None = None,
    source: Any = None,
) -> None:
    """Scroll via pixel deltas for better cross-app background delivery."""
    src = source if source is not None else _source

    dy = dx = 0
    if direction == "up":
        dy = pixels
    elif direction == "down":
        dy = -pixels
    elif direction == "left":
        dx = pixels
    elif direction == "right":
        dx = -pixels

    scroll = CGEventCreateScrollWheelEvent(src, kCGScrollEventUnitPixel, 2, dy, dx)
    if scroll is None:
        raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
    # Integer deltas — read by Chromium-based apps
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventPointDeltaAxis1, dy)
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventPointDeltaAxis2, dx)
    # Fixed-point deltas — read by native Cocoa apps
    CGEventSetDoubleValueField(scroll, kCGScrollWheelEventFixedPtDeltaAxis1, float(dy))
    CGEventSetDoubleValueField(scroll, kCGScrollWheelEventFixedPtDeltaAxis2, float(dx))
    CGEventPostToPid(pid, scroll)


def type_text(pid: int, text: str, *, source: Any = None) -> None:
    for char in text:
        key_name = char
        if char == " ":
            key_name = "space"
        elif char in {"\n", "\r"}:
            key_name = "return"
        elif char == "\t":
            key_name = "tab"

        try:
            keycode, modifiers = parse_key_combo(key_name)
        except ValueError:
            _post_unicode_char(pid, char, source=source)
        else:
            _post_keycode_with_modifiers(pid, keycode, modifiers, source=source)
        time.sleep(0.005)


@dataclass(frozen=True)
class DeliveryResult:
    transport_confirmed: bool
    fallback_used: bool
    micro_activated: bool


def deliver_key_events(
    *,
    pid: int,
    keycode: int,
    modifiers: int,
    source: Any,
    delivery_method: Any,  # DeliveryMethod
    confirmation_tap: Any,  # DeliveryConfirmationTap
    activation_policy: Any,  # ActivationPolicy
) -> DeliveryResult:
    """Deliver a key press through the confirmed delivery pipeline.

    Tries primary pipeline with discrete modifier sequences, confirms
    via tap echo, falls back to alternate pipeline on timeout, and
    optionally retries with micro-activation for qualified actions.
    """
    from app._lib import skylight
    from app._lib.keys import decompose_modifier_sequence
    from app._lib.virtual_cursor import DeliveryMethod, ActivationPolicy

    mod_sequence = decompose_modifier_sequence(modifiers)

    def _try_cgevent(src: Any) -> bool:
        """Attempt delivery via CGEventPostToPid with discrete modifiers."""
        for mod_keycode, cumulative_flags in mod_sequence:
            confirmation_tap.reset()
            _post_key_event(pid, mod_keycode, True, cumulative_flags, source=src)
            if not confirmation_tap.wait():
                return False

        confirmation_tap.reset()
        _post_key_event(pid, keycode, True, modifiers, source=src)
        if not confirmation_tap.wait():
            return False

        confirmation_tap.reset()
        _post_key_event(pid, keycode, False, modifiers, source=src)
        if not confirmation_tap.wait():
            return False

        for i, (mod_keycode, _) in enumerate(reversed(mod_sequence)):
            remaining_idx = len(mod_sequence) - 2 - i
            remaining_flags = mod_sequence[remaining_idx][1] if remaining_idx >= 0 else 0
            confirmation_tap.reset()
            _post_key_event(pid, mod_keycode, False, remaining_flags, source=src)
            if not confirmation_tap.wait():
                return False

        return True

    def _try_skylight() -> bool:
        """Attempt delivery via SkyLight SPI."""
        if not skylight.is_available():
            return False

        for mod_keycode, _ in mod_sequence:
            if not skylight.post_keyboard_event(pid, mod_keycode, True):
                return False

        if not skylight.post_keyboard_event(pid, keycode, True):
            return False
        if not skylight.post_keyboard_event(pid, keycode, False):
            return False

        for mod_keycode, _ in reversed(mod_sequence):
            if not skylight.post_keyboard_event(pid, mod_keycode, False):
                return False

        return True

    # Attempt 1: Primary pipeline
    if delivery_method == DeliveryMethod.CGEVENT_PID:
        if _try_cgevent(source):
            return DeliveryResult(transport_confirmed=True, fallback_used=False, micro_activated=False)
        # Fallback to SkyLight
        if _try_skylight():
            return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=False)
    else:  # SKYLIGHT_SPI primary
        if _try_skylight():
            return DeliveryResult(transport_confirmed=True, fallback_used=False, micro_activated=False)
        # Fallback to CGEvent
        if _try_cgevent(source):
            return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=False)

    # Attempt 2: Retry with micro-activation if policy allows
    if activation_policy == ActivationPolicy.RETRY_ONLY:
        with skylight.micro_activate(target_pid=pid):
            if delivery_method == DeliveryMethod.CGEVENT_PID:
                if _try_cgevent(source):
                    return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=True)
            else:
                if _try_skylight():
                    return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=True)

    return DeliveryResult(transport_confirmed=False, fallback_used=True, micro_activated=False)


def deliver_type_text(
    *,
    pid: int,
    text: str,
    source: Any,
    confirmation_tap: Any,
    check_interrupted: Any = None,
) -> DeliveryResult:
    """Type text through the confirmed delivery pipeline, one character at a time.

    Each character is posted via the source-filtered event source and confirmed
    via the delivery tap. If check_interrupted is provided and returns True,
    typing stops immediately (mid-stream interruption).
    """
    any_failed = False
    for char in text:
        if check_interrupted is not None and check_interrupted():
            break

        key_name = char
        if char == " ":
            key_name = "space"
        elif char in {"\n", "\r"}:
            key_name = "return"
        elif char == "\t":
            key_name = "tab"

        try:
            keycode, modifiers = parse_key_combo(key_name)
        except ValueError:
            # Unicode fallback — no confirmation available
            _post_unicode_char(pid, char, source=source)
            time.sleep(0.005)
            continue

        # Post with confirmation
        confirmation_tap.reset()
        _post_key_event(pid, keycode, True, modifiers, source=source)
        confirmed = confirmation_tap.wait()
        _post_key_event(pid, keycode, False, modifiers, source=source)
        if not confirmed:
            any_failed = True

    return DeliveryResult(
        transport_confirmed=not any_failed,
        fallback_used=False,
        micro_activated=False,
    )
