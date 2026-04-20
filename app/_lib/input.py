from __future__ import annotations

import time
from typing import Any

from Quartz import (
    CGEventCreateMouseEvent,
    CGEventCreateKeyboardEvent,
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
    kCGMouseButtonLeft,
    kCGMouseButtonRight,
    kCGMouseButtonCenter,
)
from Quartz import CGPointMake

from app._lib import screenshot
from app._lib.errors import InputError, CGEventError
from app._lib.keys import modifier_keycodes, parse_key_combo


_source = CGEventSourceCreate(kCGEventSourceStatePrivate)

_BUTTON_MAP = {
    "left": (kCGMouseButtonLeft, kCGEventLeftMouseDown, kCGEventLeftMouseUp),
    "right": (kCGMouseButtonRight, kCGEventRightMouseDown, kCGEventRightMouseUp),
    "middle": (kCGMouseButtonCenter, kCGEventOtherMouseDown, kCGEventOtherMouseUp),
}

_DOUBLE_CLICK_INTERVAL = 0.1
_KEY_HOLD_DELAY = 0.008  # delay between key down and key up
_KEY_EVENT_DELAY = 0.003

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


def _post_key_event(pid: int, keycode: int, is_down: bool, flags: int) -> None:
    event = CGEventCreateKeyboardEvent(_source, keycode, is_down)
    if event is None:
        raise CGEventError(f"cg_event_creation_failed: keycode={keycode}, down={is_down}")
    CGEventSetFlags(event, flags)
    CGEventPostToPid(pid, event)


def _post_keycode_with_modifiers(pid: int, keycode: int, modifiers: int) -> None:
    active_modifiers = 0
    modifier_sequence = modifier_keycodes(modifiers)

    for modifier_keycode, modifier_flag in modifier_sequence:
        active_modifiers |= modifier_flag
        _post_key_event(pid, modifier_keycode, True, active_modifiers)
        time.sleep(_KEY_EVENT_DELAY)

    _post_key_event(pid, keycode, True, active_modifiers)
    time.sleep(_KEY_HOLD_DELAY)
    _post_key_event(pid, keycode, False, active_modifiers)
    time.sleep(_KEY_EVENT_DELAY)

    for modifier_keycode, modifier_flag in reversed(modifier_sequence):
        active_modifiers &= ~modifier_flag
        _post_key_event(pid, modifier_keycode, False, active_modifiers)
        time.sleep(_KEY_EVENT_DELAY)


def _post_unicode_char(pid: int, char: str) -> None:
    from Quartz import CGEventKeyboardSetUnicodeString

    down = CGEventCreateKeyboardEvent(_source, 0, True)
    CGEventSetFlags(down, 0)
    CGEventKeyboardSetUnicodeString(down, len(char), char)
    CGEventPostToPid(pid, down)

    time.sleep(_KEY_HOLD_DELAY)

    up = CGEventCreateKeyboardEvent(_source, 0, False)
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
            local_x = x * (width / shot_width)
            local_y = y * (height / shot_height)

    return (wx + local_x, wy + local_y)


def _post_click(pid: int, point: Any, button: str, count: int) -> None:
    if button not in _BUTTON_MAP:
        raise InputError(f"Unknown mouse button: {button}")

    btn, down_type, up_type = _BUTTON_MAP[button]

    # Move cursor to target first — background apps need this to register
    # the correct hit-test target before mouseDown arrives.
    move = CGEventCreateMouseEvent(_source, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("cg_event_creation_failed: mouseMove")
    CGEventPostToPid(pid, move)
    time.sleep(0.01)  # brief settle for hit-test registration

    for click_num in range(1, count + 1):
        if click_num > 1:
            time.sleep(_DOUBLE_CLICK_INTERVAL)

        down = CGEventCreateMouseEvent(_source, down_type, point, btn)
        if down is None:
            raise CGEventError("cg_event_creation_failed: mouseDown")
        CGEventSetIntegerValueField(down, kCGMouseEventClickState, click_num)
        CGEventPostToPid(pid, down)

        time.sleep(0.005)  # brief hold between down and up

        up = CGEventCreateMouseEvent(_source, up_type, point, btn)
        if up is None:
            raise CGEventError("cg_event_creation_failed: mouseUp")
        CGEventSetIntegerValueField(up, kCGMouseEventClickState, click_num)
        CGEventPostToPid(pid, up)


def click_at(
    pid: int,
    window_id: int,
    x: float,
    y: float,
    button: str = "left",
    count: int = 1,
    screenshot_size: tuple[int, int] | None = None,
) -> None:
    """Click at screenshot-pixel coordinates."""
    sx, sy = window_to_screen_coords(window_id, x, y, screenshot_size)
    _post_click(pid, CGPointMake(sx, sy), button, count)


def click_at_screen_point(pid: int, x: float, y: float,
                          button: str = "left", count: int = 1) -> None:
    """Click at screen-point coordinates (from AXPosition)."""
    _post_click(pid, CGPointMake(x, y), button, count)


def drag(
    pid: int,
    window_id: int,
    from_x: float,
    from_y: float,
    to_x: float,
    to_y: float,
    screenshot_size: tuple[int, int] | None = None,
) -> None:
    sx1, sy1 = window_to_screen_coords(window_id, from_x, from_y, screenshot_size)
    sx2, sy2 = window_to_screen_coords(window_id, to_x, to_y, screenshot_size)

    from_point = CGPointMake(sx1, sy1)
    to_point = CGPointMake(sx2, sy2)

    move = CGEventCreateMouseEvent(_source, kCGEventMouseMoved, from_point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("cg_event_creation_failed: mouseDragged move")
    CGEventPostToPid(pid, move)
    time.sleep(0.01)

    down = CGEventCreateMouseEvent(_source, kCGEventLeftMouseDown, from_point, kCGMouseButtonLeft)
    if down is None:
        raise CGEventError("cg_event_creation_failed: mouseDragged down")
    CGEventPostToPid(pid, down)

    time.sleep(0.02)

    steps = 10
    for i in range(1, steps + 1):
        t = i / steps
        ix = sx1 + (sx2 - sx1) * t
        iy = sy1 + (sy2 - sy1) * t
        drag_event = CGEventCreateMouseEvent(_source, kCGEventLeftMouseDragged, CGPointMake(ix, iy), kCGMouseButtonLeft)
        if drag_event is not None:
            CGEventPostToPid(pid, drag_event)
        time.sleep(0.005)

    up = CGEventCreateMouseEvent(_source, kCGEventLeftMouseUp, to_point, kCGMouseButtonLeft)
    if up is None:
        raise CGEventError("cg_event_creation_failed: mouseDragged up")
    CGEventPostToPid(pid, up)


def press_key(pid: int, key: str) -> None:
    resolved_key = _coerce_text_key(key)
    if resolved_key == " ":
        resolved_key = "space"
    if resolved_key is None:
        resolved_key = key

    try:
        keycode, modifiers = parse_key_combo(resolved_key)
    except ValueError as exc:
        raise InputError(str(exc)) from exc

    _post_keycode_with_modifiers(pid, keycode, modifiers)


_SCROLL_STEP_DELAY = 0.015  # delay between individual scroll events


def _scroll_deltas(direction: str) -> tuple[int, int]:
    """Return (dy, dx) unit delta for a scroll direction."""
    if direction == "up":
        return (1, 0)
    elif direction == "down":
        return (-1, 0)
    elif direction == "left":
        return (0, 1)
    elif direction == "right":
        return (0, -1)
    return (0, 0)


def scroll_pid(pid: int, x: float, y: float,
               direction: str, clicks: int = 5) -> None:
    """Scroll via CGEventPostToPid — truly background, no cursor movement.

    Works for native Cocoa apps but silently ignored by browsers/Electron.
    """
    from Quartz import CGEventCreateScrollWheelEvent, kCGScrollEventUnitLine

    point = CGPointMake(x, y)

    # Move cursor within the app's event stream
    move = CGEventCreateMouseEvent(_source, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
    CGEventPostToPid(pid, move)
    time.sleep(0.01)

    dy, dx = _scroll_deltas(direction)
    for i in range(clicks):
        scroll = CGEventCreateScrollWheelEvent(_source, kCGScrollEventUnitLine, 2, dy, dx)
        if scroll is None:
            raise CGEventError("CGEventCreateScrollWheelEvent returned NULL")
        CGEventPostToPid(pid, scroll)
        if i < clicks - 1:
            time.sleep(_SCROLL_STEP_DELAY)


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


def type_text(pid: int, text: str) -> None:
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
            _post_unicode_char(pid, char)
        else:
            _post_keycode_with_modifiers(pid, keycode, modifiers)
        time.sleep(0.005)
