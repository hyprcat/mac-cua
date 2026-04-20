"""CGEventTap wrapper for monitoring user input and focus changes.

- Wraps CGEventTapCreate with configurable event types, location, placement, options
- Auto-reenable on tapDisabledByTimeout / tapDisabledByUserInput
- Runs on the shared AX run loop thread via CFMachPort + CFRunLoopSource
"""

from __future__ import annotations

import logging
import threading
from typing import Any, Callable

logger = logging.getLogger(__name__)

# CGEventTapLocation constants
TAP_LOCATION_HID = 0  # kCGHIDEventTap — before any app sees events
TAP_LOCATION_SESSION = 1  # kCGSessionEventTap — session-level tap

# CGEventTapPlacement constants
TAP_PLACEMENT_HEAD = 0  # kCGHeadInsertEventTap

# CGEventTapOptions constants
TAP_OPTION_DEFAULT = 0x00000000  # kCGEventTapOptionDefault — active (can modify/suppress)
TAP_OPTION_LISTEN_ONLY = 0x00000001  # kCGEventTapOptionListenOnly — passive

# CGEventType constants for building masks
EVENT_NULL = 0
EVENT_LEFT_MOUSE_DOWN = 1
EVENT_LEFT_MOUSE_UP = 2
EVENT_RIGHT_MOUSE_DOWN = 3
EVENT_RIGHT_MOUSE_UP = 4
EVENT_MOUSE_MOVED = 5
EVENT_LEFT_MOUSE_DRAGGED = 6
EVENT_RIGHT_MOUSE_DRAGGED = 7
EVENT_KEY_DOWN = 10
EVENT_KEY_UP = 11
EVENT_FLAGS_CHANGED = 12
EVENT_SCROLL_WHEEL = 22
EVENT_TAP_DISABLED_BY_TIMEOUT = 0xFFFFFFFE
EVENT_TAP_DISABLED_BY_USER_INPUT = 0xFFFFFFFF


def event_mask(*event_types: int) -> int:
    """Build a CGEventMask from event type constants."""
    mask = 0
    for et in event_types:
        mask |= (1 << et)
    return mask


class EventTap:
    """Read-only or active event tap for monitoring user input and focus changes.

    - CGEventTapCreate wrapper with Mach port and run loop source
    - Auto-reenable on tapDisabledByTimeout
    - Callback receives CGEvent, returns CGEvent (or None to suppress in active mode)
    """

    def __init__(
        self,
        event_types: int,
        location: int = TAP_LOCATION_HID,
        placement: int = TAP_PLACEMENT_HEAD,
        options: int = TAP_OPTION_LISTEN_ONLY,
        should_autoreenable: bool = True,
    ) -> None:
        self._event_types = event_types
        self._location = location
        self._placement = placement
        self._options = options
        self._should_autoreenable = should_autoreenable
        self._mach_port: Any = None
        self._run_loop_source: Any = None
        self._started = False
        self._lock = threading.Lock()

        # User callback: receives CGEvent proxy, event type, event.
        # Return the event to pass through, None to suppress (active taps only).
        self.on_event_received: Callable[[Any, int, Any], Any] | None = None

    @property
    def is_enabled(self) -> bool:
        if self._mach_port is None:
            return False
        try:
            from Quartz import CGEventTapIsEnabled
            return CGEventTapIsEnabled(self._mach_port)
        except Exception:
            return False

    def start(self) -> bool:
        """Create the event tap and add to the shared run loop."""
        with self._lock:
            if self._started:
                return True
            try:
                from Quartz import (
                    CGEventTapCreate,
                    CGEventTapEnable,
                )
                from CoreFoundation import (
                    CFMachPortCreateRunLoopSource,
                    CFRunLoopAddSource,
                    kCFRunLoopDefaultMode,
                )
                from app._lib.observer import get_shared_run_loop

                # Create the tap with a Python callback
                tap = CGEventTapCreate(
                    self._location,
                    self._placement,
                    self._options,
                    self._event_types,
                    self._tap_callback,
                    None,  # userInfo
                )
                if tap is None:
                    logger.warning("[EventTap] Failed to create event tap — accessibility permission required")
                    return False

                self._mach_port = tap
                self._run_loop_source = CFMachPortCreateRunLoopSource(None, tap, 0)

                run_loop_thread = get_shared_run_loop()
                if run_loop_thread.run_loop is None:
                    logger.warning("[EventTap] No run loop available")
                    return False

                CFRunLoopAddSource(
                    run_loop_thread.run_loop,
                    self._run_loop_source,
                    kCFRunLoopDefaultMode,
                )
                CGEventTapEnable(tap, True)
                self._started = True
                logger.debug("[EventTap] Started (mask=0x%x, options=%d)", self._event_types, self._options)
                return True

            except ImportError:
                logger.warning("[EventTap] Quartz/CoreFoundation not available")
                return False
            except Exception as e:
                logger.warning("[EventTap] Failed to start: %s", e)
                return False

    def stop(self) -> None:
        """Disable the tap and remove from run loop."""
        with self._lock:
            if not self._started:
                return
            try:
                from Quartz import CGEventTapEnable
                from CoreFoundation import CFRunLoopRemoveSource, kCFRunLoopDefaultMode
                from app._lib.observer import _shared_run_loop

                if self._mach_port is not None:
                    CGEventTapEnable(self._mach_port, False)

                if self._run_loop_source is not None and _shared_run_loop.run_loop is not None:
                    CFRunLoopRemoveSource(
                        _shared_run_loop.run_loop,
                        self._run_loop_source,
                        kCFRunLoopDefaultMode,
                    )
            except Exception as e:
                logger.debug("[EventTap] Error during stop: %s", e)
            finally:
                self._mach_port = None
                self._run_loop_source = None
                self._started = False
                logger.debug("[EventTap] Stopped")

    def _tap_callback(self, proxy: Any, event_type: int, event: Any, refcon: Any) -> Any:
        """C callback invoked by CGEventTap.

        Handles tapDisabledByTimeout / tapDisabledByUserInput auto-reenable.
        """
        # Handle system disable events
        if event_type == EVENT_TAP_DISABLED_BY_TIMEOUT:
            if self._should_autoreenable and self._mach_port is not None:
                try:
                    from Quartz import CGEventTapEnable
                    CGEventTapEnable(self._mach_port, True)
                    logger.debug("[EventTap] Re-enabled after tapDisabledByTimeout")
                except Exception:
                    pass
            return event

        if event_type == EVENT_TAP_DISABLED_BY_USER_INPUT:
            if self._should_autoreenable and self._mach_port is not None:
                try:
                    from Quartz import CGEventTapEnable
                    CGEventTapEnable(self._mach_port, True)
                    logger.debug("[EventTap] Re-enabled after tapDisabledByUserInput")
                except Exception:
                    pass
            return event

        # Dispatch to user callback
        callback = self.on_event_received
        if callback is not None:
            try:
                result = callback(proxy, event_type, event)
                return result  # None suppresses event in active mode
            except Exception as e:
                logger.debug("[EventTap] Callback error: %s", e)

        return event  # Pass through by default
