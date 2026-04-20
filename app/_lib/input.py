from __future__ import annotations

import time
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
_SCROLL_LINE_DELTA = 5
_MOUSE_EVENT_NUMBER = 0

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
    """Send a key press with discrete modifier events matching real keyboard behavior.

    For shift+cmd+s, emits:
      flagsChanged(shift_down, flags=shift)
      flagsChanged(cmd_down,   flags=shift|cmd)
      keyDown(s,               flags=shift|cmd)
      keyUp(s,                 flags=shift|cmd)
      flagsChanged(cmd_up,     flags=shift)
      flagsChanged(shift_up,   flags=0)
    """
    from app._lib.keys import decompose_modifier_sequence

    mod_sequence = decompose_modifier_sequence(modifiers)

    # Wind up: press each modifier in order
    for mod_keycode, cumulative_flags in mod_sequence:
        _post_key_event(pid, mod_keycode, True, cumulative_flags, source=source)
        time.sleep(_KEY_EVENT_DELAY)

    # Key down/up with full modifier mask
    _post_key_event(pid, keycode, True, modifiers, source=source)
    time.sleep(_KEY_HOLD_DELAY)
    _post_key_event(pid, keycode, False, modifiers, source=source)
    time.sleep(_KEY_EVENT_DELAY)

    # Unwind: release modifiers in reverse order
    for i, (mod_keycode, _) in enumerate(reversed(mod_sequence)):
        remaining_idx = len(mod_sequence) - 2 - i
        remaining_flags = mod_sequence[remaining_idx][1] if remaining_idx >= 0 else 0
        _post_key_event(pid, mod_keycode, False, remaining_flags, source=source)
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
    global _MOUSE_EVENT_NUMBER
    src = source if source is not None else _source

    # Move cursor to target first — background apps need this to register
    # the correct hit-test target before mouseDown arrives.
    move = CGEventCreateMouseEvent(src, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("cg_event_creation_failed: mouseMove")
    _MOUSE_EVENT_NUMBER += 1
    _decorate_mouse_event(move, window_id=window_id, pressure=0.0, event_number=_MOUSE_EVENT_NUMBER)
    CGEventPostToPid(pid, move)
    time.sleep(0.01)  # brief settle for hit-test registration

    for click_num in range(1, count + 1):
        if click_num > 1:
            time.sleep(_DOUBLE_CLICK_INTERVAL)

        down = CGEventCreateMouseEvent(src, down_type, point, btn)
        if down is None:
            raise CGEventError("cg_event_creation_failed: mouseDown")
        _MOUSE_EVENT_NUMBER += 1
        _decorate_mouse_event(
            down,
            window_id=window_id,
            pressure=_MOUSE_PRESSURE,
            click_state=click_num,
            event_number=_MOUSE_EVENT_NUMBER,
        )
        CGEventPostToPid(pid, down)

        time.sleep(0.005)  # brief hold between down and up

        up = CGEventCreateMouseEvent(src, up_type, point, btn)
        if up is None:
            raise CGEventError("cg_event_creation_failed: mouseUp")
        _MOUSE_EVENT_NUMBER += 1
        _decorate_mouse_event(
            up,
            window_id=window_id,
            pressure=0.0,
            click_state=click_num,
            event_number=_MOUSE_EVENT_NUMBER,
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

    move = CGEventCreateMouseEvent(src, kCGEventMouseMoved, from_point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("cg_event_creation_failed: mouseDragged move")
    _decorate_mouse_event(move, window_id=window_id, pressure=0.0)
    CGEventPostToPid(pid, move)
    time.sleep(0.01)

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
        return (_SCROLL_LINE_DELTA, 0)
    elif direction == "down":
        return (-_SCROLL_LINE_DELTA, 0)
    elif direction == "left":
        return (0, _SCROLL_LINE_DELTA)
    elif direction == "right":
        return (0, -_SCROLL_LINE_DELTA)
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
    from Quartz import CGEventCreateScrollWheelEvent, kCGScrollEventUnitLine

    point = CGPointMake(x, y)
    src = source if source is not None else _source

    # Move cursor within the app's event stream
    move = CGEventCreateMouseEvent(src, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
    _decorate_mouse_event(move, window_id=window_id, pressure=0.0)
    CGEventPostToPid(pid, move)
    time.sleep(0.01)

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
    from Quartz import (
        CGEventCreateScrollWheelEvent,
        kCGScrollEventUnitPixel,
        kCGScrollWheelEventPointDeltaAxis1,
        kCGScrollWheelEventPointDeltaAxis2,
    )

    point = CGPointMake(x, y)
    src = source if source is not None else _source
    move = CGEventCreateMouseEvent(src, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
    _decorate_mouse_event(move, window_id=window_id, pressure=0.0)
    CGEventPostToPid(pid, move)
    time.sleep(0.01)

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
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventPointDeltaAxis1, dy)
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventPointDeltaAxis2, dx)
    CGEventPostToPid(pid, scroll)


def scroll_system(x: float, y: float,
                  direction: str, clicks: int = 5) -> None:
    """Scroll via CGEventPost with cursor warp/restore.

    Warps cursor to target, posts scroll events to system event stream,
    warps cursor back. Works across all app types including browsers and
    Electron. Brief cursor teleport (~100ms).
    """
    from Quartz import (
        CGEventCreateScrollWheelEvent, kCGScrollEventUnitLine,
        CGEventPost, kCGHIDEventTap,
        CGEventCreate, CGEventGetLocation,
        CGWarpMouseCursorPosition,
    )

    point = CGPointMake(x, y)

    # Save current cursor position
    orig = CGEventGetLocation(CGEventCreate(None))

    # Warp cursor to scroll target
    CGWarpMouseCursorPosition(point)
    time.sleep(0.02)

    # Post scroll events to system event stream
    dy, dx = _scroll_deltas(direction)
    for i in range(clicks):
        scroll = CGEventCreateScrollWheelEvent(_source, kCGScrollEventUnitLine, 2, dy, dx)
        if scroll is None:
            raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
        CGEventPost(kCGHIDEventTap, scroll)
        if i < clicks - 1:
            time.sleep(_SCROLL_STEP_DELAY)

    time.sleep(0.05)

    # Restore cursor position
    CGWarpMouseCursorPosition(CGPointMake(orig.x, orig.y))


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
