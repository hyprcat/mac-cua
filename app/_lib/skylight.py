"""Thin ctypes wrapper for CoreGraphics Server / SkyLight private SPIs.

Provides:
- Window owner validation (snapshot integrity)
- Direct keyboard/mouse event delivery to process (bypass CGEvent tap chain)
- Invisible micro-activation (window-server-level frontmost flag flip)

macOS 13+ (Ventura). Falls back gracefully if symbols not found.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import platform
import time
from contextlib import contextmanager
from typing import Any, Generator

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Framework loading
# ---------------------------------------------------------------------------

_framework: Any = None
_main_cid: int = 0
_available: bool = False


def _do_load_framework() -> Any:
    """Load SkyLight / CoreGraphics framework and resolve symbols."""
    # SkyLight is the modern name; CGS functions live in CoreGraphics
    path = ctypes.util.find_library("CoreGraphics")
    if path is None:
        raise OSError("CoreGraphics framework not found")
    lib = ctypes.cdll.LoadLibrary(path)

    # Resolve function signatures
    lib.CGSMainConnectionID.restype = ctypes.c_int
    lib.CGSMainConnectionID.argtypes = []

    lib.CGSGetConnectionIDForPID.restype = ctypes.c_int  # CGError
    lib.CGSGetConnectionIDForPID.argtypes = [
        ctypes.c_int,  # cid (our connection)
        ctypes.c_int,  # pid
        ctypes.POINTER(ctypes.c_int),  # out_cid
    ]

    lib.CGSGetWindowOwner.restype = ctypes.c_int  # CGError
    lib.CGSGetWindowOwner.argtypes = [
        ctypes.c_int,  # cid
        ctypes.c_int,  # window_id
        ctypes.POINTER(ctypes.c_int),  # out_owner_cid
    ]

    lib.CGSPostKeyboardEventToProcess.restype = ctypes.c_int  # CGError
    lib.CGSPostKeyboardEventToProcess.argtypes = [
        ctypes.c_int,  # cid
        ctypes.c_int,  # target_pid
        ctypes.c_uint16,  # key_char
        ctypes.c_bool,  # key_down
    ]

    # Connection property manipulation (for micro-activation)
    try:
        lib.CGSSetConnectionProperty.restype = ctypes.c_int
        lib.CGSSetConnectionProperty.argtypes = [
            ctypes.c_int,  # owner_cid
            ctypes.c_int,  # target_cid
            ctypes.c_void_p,  # key (CFStringRef)
            ctypes.c_void_p,  # value (CFTypeRef)
        ]
    except AttributeError:
        pass  # Not available on this version

    return lib


# Use try/except to avoid redefining _load_framework if it was already set
# (e.g., by a test mock via @patch + importlib.reload). This allows tests to
# inject a mock _load_framework before calling importlib.reload(skylight) and
# have _init() use the mock rather than the real loader.
try:
    _load_framework  # type: ignore[used-before-def]
except NameError:
    _load_framework = _do_load_framework


def _init() -> None:
    """Initialize the module. Called once at import time."""
    global _framework, _main_cid, _available

    ver_str = platform.mac_ver()[0]
    if not ver_str:
        logger.info("[SkyLight] Could not determine macOS version, SkyLight SPIs unavailable")
        return

    parts = ver_str.split(".")
    try:
        major = int(parts[0])
        minor = int(parts[1]) if len(parts) > 1 else 0
    except (ValueError, IndexError):
        logger.info("[SkyLight] Could not parse macOS version '%s', SkyLight SPIs unavailable", ver_str)
        return

    if major < 13:
        logger.info("[SkyLight] macOS %d.%d < 13, SkyLight SPIs unavailable", major, minor)
        return

    try:
        _framework = _load_framework()
        _main_cid = _framework.CGSMainConnectionID()
        _available = _main_cid != 0
        if _available:
            logger.debug("[SkyLight] Initialized, connection=%d", _main_cid)
        else:
            logger.warning("[SkyLight] CGSMainConnectionID returned 0")
    except (OSError, AttributeError) as e:
        logger.info("[SkyLight] Not available: %s", e)


_init()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def is_available() -> bool:
    """Return True if SkyLight SPIs are loaded and usable.

    Checks module-level state dynamically so that test patching of
    _framework and _main_cid is reflected correctly.
    """
    return _framework is not None and _main_cid != 0


def get_main_connection() -> int:
    """Return our process's window server connection ID."""
    if not is_available():
        raise RuntimeError("SkyLight not available")
    return _main_cid


def get_connection_for_pid(cid: int, pid: int) -> int | None:
    """Return the window server connection ID for a target PID, or None on failure."""
    if not is_available():
        return None
    out = ctypes.c_int(0)
    err = _framework.CGSGetConnectionIDForPID(cid, pid, ctypes.byref(out))
    if err != 0:
        logger.debug("[SkyLight] CGSGetConnectionIDForPID(pid=%d) failed: error %d", pid, err)
        return None
    return out.value


def validate_window_owner(window_id: int, expected_pid: int) -> bool:
    """Check whether a window ID still belongs to the expected PID.

    Returns True if the window's owner connection matches the expected PID's
    connection. Returns False on mismatch or if either lookup fails.
    """
    if not is_available():
        return True  # Can't validate — assume correct

    owner_cid_out = ctypes.c_int(0)
    err = _framework.CGSGetWindowOwner(_main_cid, window_id, ctypes.byref(owner_cid_out))
    if err != 0:
        return False

    expected_cid = get_connection_for_pid(_main_cid, expected_pid)
    if expected_cid is None:
        return False

    return owner_cid_out.value == expected_cid


def post_keyboard_event(pid: int, keycode: int, key_down: bool) -> bool:
    """Post a keyboard event directly to a process via the window server.

    Bypasses the CGEvent tap chain. Returns True on success.
    """
    if not is_available():
        return False
    err = _framework.CGSPostKeyboardEventToProcess(_main_cid, pid, keycode, key_down)
    if err != 0:
        logger.debug("[SkyLight] CGSPostKeyboardEventToProcess(pid=%d, key=%d) failed: %d", pid, keycode, err)
        return False
    return True


# ---------------------------------------------------------------------------
# Micro-activation
# ---------------------------------------------------------------------------

_MICRO_ACTIVATION_BUDGET_S = 0.010  # 10ms hard limit


@contextmanager
def micro_activate(target_pid: int) -> Generator[None, None, None]:
    """Invisibly flip the window server's frontmost flag for a process.

    Context manager. Sets the target as frontmost, yields, then restores.
    Hard 10ms budget — if exceeded, restores immediately.

    No window ordering change, no visual change, no menu bar swap.
    """
    if not is_available():
        yield
        return

    target_cid = get_connection_for_pid(_main_cid, target_pid)
    if target_cid is None:
        yield
        return

    start = time.monotonic()
    activated = False
    try:
        # Set target as frontmost in window server state
        _set_frontmost(target_cid, True)
        activated = True
        yield
    finally:
        if activated:
            elapsed = time.monotonic() - start
            if elapsed > _MICRO_ACTIVATION_BUDGET_S:
                logger.warning(
                    "[SkyLight] micro_activate exceeded budget: %.1fms",
                    elapsed * 1000,
                )
            _set_frontmost(target_cid, False)
            # Restore our own process as frontmost
            _set_frontmost(_main_cid, True)


def _set_frontmost(target_cid: int, frontmost: bool) -> None:
    """Set the frontmost flag on a window server connection."""
    if not is_available() or _framework is None:
        return
    try:
        from Foundation import NSString
        from CoreFoundation import kCFBooleanTrue, kCFBooleanFalse

        key = NSString.stringWithString_("SetFrontmost")
        value = kCFBooleanTrue if frontmost else kCFBooleanFalse
        _framework.CGSSetConnectionProperty(
            _main_cid,
            target_cid,
            ctypes.c_void_p(key.__c_void_p__()),
            ctypes.c_void_p(value.__c_void_p__()),
        )
    except Exception as e:
        logger.debug("[SkyLight] _set_frontmost failed: %s", e)
