"""Per-session delivery confirmation via listen-only CGEventTap.

Watches for echoes of posted events matched by CGEventSource state ID.
Used by the delivery pipeline to confirm transport before proceeding.
"""

from __future__ import annotations

import logging
import threading
from typing import Any

from app._lib.event_tap import (
    EVENT_FLAGS_CHANGED,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_LEFT_MOUSE_DOWN,
    EVENT_LEFT_MOUSE_UP,
    EVENT_MOUSE_MOVED,
    EVENT_RIGHT_MOUSE_DOWN,
    EVENT_RIGHT_MOUSE_UP,
    EVENT_SCROLL_WHEEL,
    TAP_LOCATION_SESSION,
    TAP_OPTION_LISTEN_ONLY,
    EventTap,
    event_mask,
)

logger = logging.getLogger(__name__)

# CGEventField for source state ID
_kCGEventSourceStateID = 45

# Default transport confirmation timeout
TRANSPORT_TIMEOUT_S = 0.05

_ALL_INPUT_EVENTS = event_mask(
    EVENT_MOUSE_MOVED,
    EVENT_LEFT_MOUSE_DOWN,
    EVENT_LEFT_MOUSE_UP,
    EVENT_RIGHT_MOUSE_DOWN,
    EVENT_RIGHT_MOUSE_UP,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_FLAGS_CHANGED,
    EVENT_SCROLL_WHEEL,
)


def _load_cgevent_get_field() -> Any:
    """Load CGEventGetIntegerValueField once, cache for hot path."""
    from Quartz import CGEventGetIntegerValueField as _get
    return _get


# Cached reference — resolved once, called per event tap callback.
# Tests mock CGEventGetIntegerValueField at module level to override.
_cgevent_get_field = _load_cgevent_get_field()


def CGEventGetIntegerValueField(event: Any, field: int) -> int:
    """Wrapper around CGEventGetIntegerValueField. Uses cached reference."""
    return _cgevent_get_field(event, field)


class DeliveryConfirmationTap:
    """Listen-only event tap that confirms delivery of posted events.

    Each session creates one of these. It stays installed for the session
    lifetime. For each posted event, the caller resets the signal, posts
    the event, then waits on `transport_confirmed`.
    """

    def __init__(self, expected_source_state_id: int) -> None:
        self._expected_source_id = expected_source_state_id
        self.transport_confirmed = threading.Event()
        self._tap: EventTap | None = None
        self._listening = False  # Only process events when actively waiting

    def start(self) -> bool:
        """Pre-create the tap config. Actual tap is installed on-demand per action."""
        # Don't install the tap here — it stays off until reset() is called.
        # This avoids Python callback overhead on every system input event.
        return True

    def stop(self) -> None:
        """Remove the tap if active."""
        self._listening = False
        if self._tap is not None:
            self._tap.stop()
            self._tap = None

    def _ensure_tap(self) -> bool:
        """Install the tap on-demand. Fast no-op if already installed."""
        if self._tap is not None:
            return True
        tap = EventTap(
            event_types=_ALL_INPUT_EVENTS,
            location=TAP_LOCATION_SESSION,
            options=TAP_OPTION_LISTEN_ONLY,
        )
        tap.on_event_received = self._on_event
        if not tap.start():
            return False
        self._tap = tap
        return True

    def reset(self) -> None:
        """Clear the confirmed flag and activate listening (installs tap on first use)."""
        self.transport_confirmed.clear()
        self._listening = True
        self._ensure_tap()

    def wait(self, timeout: float = TRANSPORT_TIMEOUT_S) -> bool:
        """Wait for transport confirmation. Returns True if confirmed."""
        result = self.transport_confirmed.wait(timeout=timeout)
        self._listening = False  # Stop processing events between deliveries
        return result

    def deactivate(self) -> None:
        """Remove the tap until next action. Call after action completes."""
        self._listening = False
        if self._tap is not None:
            self._tap.stop()
            self._tap = None

    def _on_event(self, proxy: Any, event_type: int, event: Any) -> Any:
        """Event tap callback — check if this is our event. No-op unless listening."""
        if not self._listening:
            return event  # Fast exit — not waiting for confirmation
        try:
            source_id = CGEventGetIntegerValueField(event, _kCGEventSourceStateID)
            if source_id == self._expected_source_id:
                self.transport_confirmed.set()
        except Exception:
            pass  # Don't crash the tap callback
        return event
