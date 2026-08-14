"""Resolve characters to keycodes using the *active* keyboard layout.

The static table in ``keys.py`` maps characters to the keycodes of a US ANSI
keyboard. macOS re-interprets a virtual keycode through whatever layout the
user has active, so on a non-US layout those keycodes produce the wrong
characters: on French AZERTY, ``a`` (keycode 0) types ``q``, and ``super+a``
becomes Cmd+Q, which quits the frontmost app.

This module asks Text Input Services for the layout that is actually active
and builds the inverse map character -> (keycode, modifier_mask). The Carbon
symbols are not exposed by pyobjc, so they are bound through ctypes.

Everything degrades gracefully: if the layout cannot be read, the caller keeps
the static US table, which is exactly the previous behaviour.
"""

from __future__ import annotations

import ctypes
import logging

logger = logging.getLogger(__name__)

# CGEventFlags, mirrored from keys.py (kept in sync by test_keyboard_layout).
_MASK_SHIFT = 1 << 17
_MASK_ALTERNATE = 1 << 19

# UCKeyTranslate constants.
_ACTION_DISPLAY = 3
_NO_DEAD_KEYS = 1 << 0

# modifierKeyState is the Carbon modifier word shifted right by 8.
_UC_SHIFT = 2   # shiftKey  (0x0200) >> 8
_UC_ALT = 8     # optionKey (0x0800) >> 8

# Ordered by preference: fewer modifiers wins when a character is reachable
# through several combinations.
_COMBINATIONS = (
    (0, 0),
    (_UC_SHIFT, _MASK_SHIFT),
    (_UC_ALT, _MASK_ALTERNATE),
    (_UC_SHIFT | _UC_ALT, _MASK_SHIFT | _MASK_ALTERNATE),
)

_MAX_KEYCODE = 128
_BUF_LEN = 8

_cached: dict[str, tuple[int, int]] | None = None
_cached_source_id: str | None = None


def _bind() -> tuple:
    """Bind the Carbon/CoreFoundation symbols. Raises OSError if unavailable."""
    carbon = ctypes.cdll.LoadLibrary(
        "/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon"
    )
    cf = ctypes.cdll.LoadLibrary(
        "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
    )

    carbon.TISCopyCurrentKeyboardLayoutInputSource.restype = ctypes.c_void_p
    carbon.TISGetInputSourceProperty.restype = ctypes.c_void_p
    carbon.TISGetInputSourceProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    carbon.LMGetKbdType.restype = ctypes.c_uint8
    carbon.UCKeyTranslate.restype = ctypes.c_int32
    carbon.UCKeyTranslate.argtypes = [
        ctypes.c_void_p,                        # keyLayoutPtr
        ctypes.c_uint16,                        # virtualKeyCode
        ctypes.c_uint16,                        # keyAction
        ctypes.c_uint32,                        # modifierKeyState
        ctypes.c_uint32,                        # keyboardType
        ctypes.c_uint32,                        # keyTranslateOptions
        ctypes.POINTER(ctypes.c_uint32),        # deadKeyState
        ctypes.c_ulong,                         # maxStringLength
        ctypes.POINTER(ctypes.c_ulong),         # actualStringLength
        ctypes.POINTER(ctypes.c_uint16 * _BUF_LEN),  # unicodeString
    ]

    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32
    ]

    return carbon, cf


def current_source_id() -> str | None:
    """Identifier of the active layout, e.g. ``com.apple.keylayout.French``.

    Used to notice that the user switched layouts mid-session; returns None
    when it cannot be read, which disables the cache invalidation rather than
    guessing.
    """
    try:
        carbon, cf = _bind()
    except OSError:
        return None

    source = None
    try:
        source = carbon.TISCopyCurrentKeyboardLayoutInputSource()
        if not source:
            return None
        prop = ctypes.c_void_p.in_dll(carbon, "kTISPropertyInputSourceID")
        ref = carbon.TISGetInputSourceProperty(source, prop)
        if not ref:
            return None
        buf = ctypes.create_string_buffer(256)
        if not cf.CFStringGetCString(ref, buf, 256, 0x08000100):  # kCFStringEncodingUTF8
            return None
        return buf.value.decode("utf-8", "replace")
    except (AttributeError, ValueError, OSError):
        return None
    finally:
        if source:
            try:
                cf.CFRelease(source)
            except Exception:  # pragma: no cover - release is best effort
                pass


def build_layout_map() -> dict[str, tuple[int, int]]:
    """Return ``{character: (keycode, modifier_mask)}`` for the active layout.

    Returns an empty dict when the layout cannot be read, so callers can fall
    back to the static table without special-casing failures.
    """
    try:
        carbon, cf = _bind()
    except OSError as exc:
        logger.debug("keyboard layout unavailable: %s", exc)
        return {}

    source = None
    try:
        source = carbon.TISCopyCurrentKeyboardLayoutInputSource()
        if not source:
            return {}
        prop = ctypes.c_void_p.in_dll(carbon, "kTISPropertyUnicodeKeyLayoutData")
        data = carbon.TISGetInputSourceProperty(source, prop)
        if not data:
            # Non-Unicode layouts (some IMEs) expose no uchr data.
            return {}
        layout_ptr = cf.CFDataGetBytePtr(data)
        if not layout_ptr:
            return {}
        kbd_type = carbon.LMGetKbdType()

        mapping: dict[str, tuple[int, int]] = {}
        for uc_mods, cg_mask in _COMBINATIONS:
            for keycode in range(_MAX_KEYCODE):
                char = _translate(carbon, layout_ptr, keycode, uc_mods, kbd_type)
                if char is None or char in mapping:
                    continue
                mapping[char] = (keycode, cg_mask)
        return mapping
    except (AttributeError, ValueError, OSError) as exc:
        logger.debug("keyboard layout probe failed: %s", exc)
        return {}
    finally:
        if source:
            try:
                cf.CFRelease(source)
            except Exception:  # pragma: no cover - release is best effort
                pass


def _translate(
    carbon, layout_ptr: int, keycode: int, uc_mods: int, kbd_type: int
) -> str | None:
    """Translate one keycode+modifier pair to the character it produces."""
    dead = ctypes.c_uint32(0)
    length = ctypes.c_ulong(0)
    buf = (ctypes.c_uint16 * _BUF_LEN)()
    status = carbon.UCKeyTranslate(
        layout_ptr, keycode, _ACTION_DISPLAY, uc_mods, kbd_type,
        _NO_DEAD_KEYS, ctypes.byref(dead), _BUF_LEN,
        ctypes.byref(length), ctypes.byref(buf),
    )
    if status != 0 or length.value != 1:
        # Multi-character output means a dead key sequence; not a single press.
        return None
    char = chr(buf[0])
    # Control characters (return, tab, escape...) already have explicit,
    # layout-independent names in the static table.
    return char if char.isprintable() and not char.isspace() else None


def active_layout_map() -> dict[str, tuple[int, int]]:
    """Cached :func:`build_layout_map`, rebuilt when the user switches layout."""
    global _cached, _cached_source_id
    source_id = current_source_id()
    if _cached is not None and source_id == _cached_source_id:
        return _cached

    _cached = build_layout_map()
    _cached_source_id = source_id
    if _cached:
        logger.info(
            "keyboard layout %s: %d characters mapped",
            source_id or "<unknown>", len(_cached),
        )
    else:
        logger.warning(
            "keyboard layout unreadable; falling back to the US ANSI table "
            "(typing may be wrong on non-US layouts)"
        )
    return _cached


def refresh() -> None:
    """Re-read the active layout and install it into the key parser."""
    from app._lib.keys import install_layout_map

    install_layout_map(active_layout_map())
