from __future__ import annotations

import logging
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable

from app._lib.event_tap import (
    EVENT_FLAGS_CHANGED,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_LEFT_MOUSE_DOWN,
    EVENT_LEFT_MOUSE_DRAGGED,
    EVENT_LEFT_MOUSE_UP,
    EVENT_MOUSE_MOVED,
    EVENT_RIGHT_MOUSE_DOWN,
    EVENT_RIGHT_MOUSE_DRAGGED,
    EVENT_RIGHT_MOUSE_UP,
    EVENT_SCROLL_WHEEL,
    EventTap,
    event_mask,
)

logger = logging.getLogger(__name__)

_ALL_CG_EVENT_MASK = event_mask(
    EVENT_MOUSE_MOVED,
    EVENT_LEFT_MOUSE_DOWN,
    EVENT_LEFT_MOUSE_UP,
    EVENT_RIGHT_MOUSE_DOWN,
    EVENT_RIGHT_MOUSE_UP,
    EVENT_LEFT_MOUSE_DRAGGED,
    EVENT_RIGHT_MOUSE_DRAGGED,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_FLAGS_CHANGED,
    EVENT_SCROLL_WHEEL,
)


class ActionVerificationResult(str, Enum):
    CONFIRMED = "confirmed"
    NO_EFFECT = "no_effect"
    GRAPH_CHANGED_WRONG_WAY = "graph_changed_wrong_way"
    TRANSIENT_OPENED = "transient_opened"
    TRANSIENT_CLOSED = "transient_closed"
    STALE = "stale"
    TIMEOUT = "timeout"


@dataclass(frozen=True)
class VerificationContract:
    expect_transient_open: bool = False
    expect_transient_close: bool = False
    allow_invalidation: bool = True
    allow_focus_change: bool = True
    allow_value_change: bool = True
    direct_verifier: Callable[[], bool] | None = None


@dataclass(frozen=True)
class CGEventSequenceExpectation:
    event_types: tuple[int, ...]
    ordered: bool = True
    minimum_matches: int | None = None

    def matches(self, events: list[int]) -> bool:
        if not self.event_types:
            return True
        if self.ordered:
            cursor = 0
            matches = 0
            for event in events:
                if event == self.event_types[cursor]:
                    cursor += 1
                    matches += 1
                    if cursor == len(self.event_types):
                        if self.minimum_matches is None:
                            return True
                        return matches >= self.minimum_matches
            return False
        required = self.minimum_matches or len(self.event_types)
        matches = sum(1 for event in events if event in self.event_types)
        return matches >= required


@dataclass(frozen=True)
class ObservedCGEvent:
    sequence: int
    event_type: int
    observed_at: float


class ActionOutcomeMonitor:
    def __init__(self, notification_bridge: Any, invalidation_monitor: Any, transient_tracker: Any) -> None:
        self._bridge = notification_bridge
        self._monitor = invalidation_monitor
        self._transient_tracker = transient_tracker

    def mark(self) -> tuple[int, int, int]:
        notification_mark = self._bridge.mark() if self._bridge is not None else 0
        invalidation_mark = getattr(self._monitor, "notification_count", 0)
        transient_mark = getattr(self._transient_tracker, "event_counter", 0)
        return (notification_mark, invalidation_mark, transient_mark)

    def verify(
        self,
        *,
        contract: VerificationContract,
        mark: tuple[int, int, int] | None = None,
        timeout: float = 0.35,
    ) -> ActionVerificationResult:
        if mark is None:
            mark = self.mark()
        notification_mark, invalidation_mark, transient_mark = mark
        deadline = time.monotonic() + timeout

        while time.monotonic() < deadline:
            if contract.expect_transient_open and self._transient_opened_since(transient_mark):
                return ActionVerificationResult.TRANSIENT_OPENED
            if contract.expect_transient_close and self._transient_closed_since(transient_mark):
                return ActionVerificationResult.TRANSIENT_CLOSED
            if contract.direct_verifier is not None:
                try:
                    if contract.direct_verifier():
                        return ActionVerificationResult.CONFIRMED
                except Exception:
                    logger.debug("Direct verifier raised", exc_info=True)
            if contract.allow_invalidation and self._invalidation_count() > invalidation_mark:
                return ActionVerificationResult.CONFIRMED
            if self._bridge is not None:
                events = self._bridge.events_since(notification_mark)
                if events:
                    notifications = {event.notification for event in events}
                    if contract.expect_transient_open and "AXMenuOpened" in notifications:
                        return ActionVerificationResult.TRANSIENT_OPENED
                    if contract.expect_transient_close and (
                        "AXMenuClosed" in notifications or "AXUIElementDestroyed" in notifications
                    ):
                        return ActionVerificationResult.TRANSIENT_CLOSED
                    if contract.allow_focus_change and "AXFocusedUIElementChanged" in notifications:
                        return ActionVerificationResult.CONFIRMED
                    if contract.allow_value_change and "AXValueChanged" in notifications:
                        return ActionVerificationResult.CONFIRMED
                    if contract.allow_invalidation:
                        return ActionVerificationResult.CONFIRMED
            time.sleep(0.01)

        if contract.expect_transient_open and self._transient_opened_since(transient_mark):
            return ActionVerificationResult.TRANSIENT_OPENED
        if contract.expect_transient_close and self._transient_closed_since(transient_mark):
            return ActionVerificationResult.TRANSIENT_CLOSED
        if contract.direct_verifier is not None:
            try:
                if contract.direct_verifier():
                    return ActionVerificationResult.CONFIRMED
            except Exception:
                logger.debug("Direct verifier raised", exc_info=True)
        if self._bridge is not None and self._bridge.events_since(notification_mark):
            return ActionVerificationResult.GRAPH_CHANGED_WRONG_WAY
        if self._invalidation_count() > invalidation_mark:
            return ActionVerificationResult.GRAPH_CHANGED_WRONG_WAY
        return ActionVerificationResult.TIMEOUT

    def _invalidation_count(self) -> int:
        return getattr(self._monitor, "notification_count", 0)

    def _transient_opened_since(self, mark: int) -> bool:
        tracker = self._transient_tracker
        if tracker is None:
            return False
        if getattr(tracker, "event_counter", 0) <= mark:
            return False
        return bool(getattr(tracker, "has_active_transient", False))

    def _transient_closed_since(self, mark: int) -> bool:
        tracker = self._transient_tracker
        if tracker is None:
            return False
        if getattr(tracker, "event_counter", 0) <= mark:
            return False
        return not bool(getattr(tracker, "has_active_transient", False))


class CGEventOutcomeMonitor:
    _kCGEventSourceStateID = 45

    def __init__(self, *, history_limit: int = 256, source_state_id: int | None = None) -> None:
        self._history_limit = history_limit
        self._source_state_id = source_state_id
        self._lock = threading.Lock()
        self._events: deque[ObservedCGEvent] = deque(maxlen=history_limit)
        self._sequence = 0
        self._tap: EventTap | None = None
        self._started = False
        # Cache the Quartz function reference for hot-path callback
        self._cg_get_field: Any = None
        try:
            from Quartz import CGEventGetIntegerValueField
            self._cg_get_field = CGEventGetIntegerValueField
        except ImportError:
            pass

    def _get_source_id(self, event: Any) -> int:
        if self._cg_get_field is None:
            return 0
        return self._cg_get_field(event, self._kCGEventSourceStateID)

    @property
    def is_started(self) -> bool:
        return self._started

    def start(self) -> bool:
        if self._started:
            return True
        tap = EventTap(_ALL_CG_EVENT_MASK)
        tap.on_event_received = self._on_event
        if not tap.start():
            logger.debug("[CGEventOutcomeMonitor] passive event tap unavailable")
            return False
        self._tap = tap
        self._started = True
        return True

    def stop(self) -> None:
        if self._tap is not None:
            self._tap.stop()
        self._tap = None
        self._started = False
        with self._lock:
            self._events.clear()
            self._sequence = 0

    def begin_action(self) -> tuple[str, int]:
        return (uuid.uuid4().hex, self.mark())

    def mark(self) -> int:
        with self._lock:
            return self._sequence

    def events_since(self, sequence: int) -> list[ObservedCGEvent]:
        with self._lock:
            return [event for event in self._events if event.sequence > sequence]

    def verify_transport(
        self,
        *,
        start_sequence: int,
        expectation: CGEventSequenceExpectation,
        timeout: float = 0.3,
    ) -> bool:
        if not self._started:
            return False
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            events = [event.event_type for event in self.events_since(start_sequence)]
            if expectation.matches(events):
                return True
            time.sleep(0.005)
        events = [event.event_type for event in self.events_since(start_sequence)]
        return expectation.matches(events)

    def _on_event(self, proxy: Any, event_type: int, event: Any) -> Any:
        # Filter by source_state_id to distinguish automation from user input
        if self._source_state_id is not None:
            try:
                event_source_id = self._get_source_id(event)
                if event_source_id != self._source_state_id:
                    return event  # Not our event — skip
            except Exception:
                pass  # Can't filter — record anyway
        with self._lock:
            self._sequence += 1
            self._events.append(
                ObservedCGEvent(
                    sequence=self._sequence,
                    event_type=event_type,
                    observed_at=time.monotonic(),
                )
            )
        return event


def expectation_for_click(button: str, count: int) -> CGEventSequenceExpectation:
    down = EVENT_RIGHT_MOUSE_DOWN if button == "right" else EVENT_LEFT_MOUSE_DOWN
    up = EVENT_RIGHT_MOUSE_UP if button == "right" else EVENT_LEFT_MOUSE_UP
    event_types: list[int] = []
    for _ in range(max(1, count)):
        event_types.extend([down, up])
    return CGEventSequenceExpectation(tuple(event_types), ordered=True)


def expectation_for_drag() -> CGEventSequenceExpectation:
    return CGEventSequenceExpectation(
        (EVENT_LEFT_MOUSE_DOWN, EVENT_LEFT_MOUSE_DRAGGED, EVENT_LEFT_MOUSE_UP),
        ordered=True,
    )


def expectation_for_keypress() -> CGEventSequenceExpectation:
    return CGEventSequenceExpectation((EVENT_KEY_DOWN, EVENT_KEY_UP), ordered=True)


def expectation_for_typing() -> CGEventSequenceExpectation:
    return CGEventSequenceExpectation((EVENT_KEY_DOWN, EVENT_KEY_UP), ordered=False, minimum_matches=2)


def expectation_for_scroll() -> CGEventSequenceExpectation:
    return CGEventSequenceExpectation((EVENT_SCROLL_WHEEL,), ordered=True)
