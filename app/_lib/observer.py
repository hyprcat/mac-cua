"""AXObserver notification bindings, CFRunLoop thread, and debounce.

Architecture:
- AXRunLoopThread: dedicated daemon thread running a CFRunLoop
- AXNotificationObserver: wraps AXObserverCreate for a target PID
- NotificationBridge: routes AX notifications to Python handlers
- DebounceStateMachine: debounces rapid-fire events
- AXEnablementAssertion: coordinated AX access
"""

from __future__ import annotations

import logging
import threading
import time
from contextlib import contextmanager
from enum import Enum
from typing import Any, Callable

logger = logging.getLogger(__name__)

# Global registry: maps observer ID → callback callable.
# Used by the module-level C callback to dispatch to the right observer.
_observer_callbacks: dict[int, Callable[[Any, Any, str], None]] = {}
_observer_callbacks_lock = threading.Lock()


# ---------------------------------------------------------------------------
# AXRunLoopThread — dedicated CFRunLoop for AX notification delivery
# ---------------------------------------------------------------------------

class AXRunLoopThread:
    """Dedicated daemon thread running CFRunLoop for AX notification delivery.

    A single thread with its own CFRunLoop.
    All AXObserver instances attach to this single shared run loop.
    """

    def __init__(self) -> None:
        self._thread: threading.Thread | None = None
        self._run_loop: Any = None
        self._ready = threading.Event()
        self._stopped = False

    @property
    def run_loop(self) -> Any:
        return self._run_loop

    @property
    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        if self.is_running:
            return
        self._stopped = False
        self._ready.clear()
        self._thread = threading.Thread(
            target=self._run,
            daemon=True,
            name="AXRunLoop",
        )
        self._thread.start()
        self._ready.wait(timeout=5.0)

    def stop(self) -> None:
        self._stopped = True
        if self._run_loop is not None:
            try:
                from CoreFoundation import CFRunLoopStop
                CFRunLoopStop(self._run_loop)
            except Exception:
                logger.debug("[RunLoopTask] Failed to stop run loop")
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None
            self._run_loop = None

    def perform(self, block: Callable[[], None]) -> None:
        """Execute a block on the run loop thread.

        Schedules work on the dedicated AX thread via CFRunLoopPerformBlock.
        """
        if self._run_loop is None or not self.is_running:
            logger.debug("[RunLoopTask] Cannot perform — run loop not running")
            return
        try:
            from CoreFoundation import CFRunLoopPerformBlock, CFRunLoopWakeUp, kCFRunLoopDefaultMode
            CFRunLoopPerformBlock(self._run_loop, kCFRunLoopDefaultMode, block)
            CFRunLoopWakeUp(self._run_loop)
        except (ImportError, Exception) as e:
            logger.debug("[RunLoopTask] Failed to schedule block: %s", e)

    def _run(self) -> None:
        try:
            from CoreFoundation import CFRunLoopGetCurrent, CFRunLoopRun
            self._run_loop = CFRunLoopGetCurrent()
            self._ready.set()
            CFRunLoopRun()  # Blocks until stopped
        except ImportError:
            logger.warning("CoreFoundation not available — AX observer disabled")
            self._ready.set()
        except Exception as e:
            logger.error("AXRunLoopThread crashed: %s", e)
            self._ready.set()


# Global shared run loop thread
_shared_run_loop = AXRunLoopThread()


def get_shared_run_loop() -> AXRunLoopThread:
    """Get (and start if needed) the shared AX run loop thread."""
    if not _shared_run_loop.is_running:
        _shared_run_loop.start()
    return _shared_run_loop


# ---------------------------------------------------------------------------
# AXNotificationObserver — Python wrapper for macOS AXObserver API
# ---------------------------------------------------------------------------

# Supported AX notification names
AX_NOTIFICATION_ELEMENT_DESTROYED = "AXUIElementDestroyed"
AX_NOTIFICATION_CREATED = "AXCreated"
AX_NOTIFICATION_WINDOW_CREATED = "AXWindowCreated"
AX_NOTIFICATION_WINDOW_MOVED = "AXWindowMoved"
AX_NOTIFICATION_WINDOW_RESIZED = "AXWindowResized"
AX_NOTIFICATION_SELECTED_TEXT_CHANGED = "AXSelectedTextChanged"
AX_NOTIFICATION_FOCUSED_ELEMENT_CHANGED = "AXFocusedUIElementChanged"
AX_NOTIFICATION_MENU_OPENED = "AXMenuOpened"
AX_NOTIFICATION_MENU_CLOSED = "AXMenuClosed"
AX_NOTIFICATION_VALUE_CHANGED = "AXValueChanged"

# Notifications used for tree invalidation
TREE_INVALIDATION_NOTIFICATIONS = [
    AX_NOTIFICATION_ELEMENT_DESTROYED,
    AX_NOTIFICATION_CREATED,
    AX_NOTIFICATION_WINDOW_CREATED,
    AX_NOTIFICATION_WINDOW_MOVED,
    AX_NOTIFICATION_WINDOW_RESIZED,
]


def _ax_observer_callback(observer: Any, element: Any, notification: str, user_data: Any) -> None:
    """Module-level C callback for AXObserver.

    AXObserverCreate requires a C function pointer, so we use a module-level
    function and dispatch via the global _observer_callbacks registry keyed
    by observer ID.
    """
    notif_str = str(notification)
    obs_id = id(observer)
    with _observer_callbacks_lock:
        callback = _observer_callbacks.get(obs_id)
    if callback is not None:
        try:
            callback(observer, element, notif_str)
        except Exception as e:
            logger.debug("AX notification callback error: %s", e)


class AXNotificationObserver:
    """Python wrapper around macOS AXObserver API.

    Manages a set of (element, notification) pairs, installs on a CFRunLoop,
    and dispatches through a C callback bridge.
    """

    def __init__(self, pid: int, callback: Callable[[Any, Any, str], None] | None = None) -> None:
        self.pid = pid
        self._callback = callback
        self._observer: Any = None
        self._subscriptions: set[tuple[int, str]] = set()  # (id(element), notification)
        self._subscriptions_refs: dict[tuple[int, str], Any] = {}  # Keep element refs alive
        self._started = False
        self._lock = threading.Lock()

    def _ensure_observer(self) -> bool:
        """Create the AXObserver if not already created."""
        if self._observer is not None:
            return True
        try:
            from ApplicationServices import AXObserverCreate
            err, observer = AXObserverCreate(self.pid, _ax_observer_callback, None)
            if err != 0 or observer is None:
                logger.debug("failedToCreateAXObserver for pid %d: error %d", self.pid, err)
                return False
            self._observer = observer
            # Register in global callback dispatch table
            with _observer_callbacks_lock:
                _observer_callbacks[id(observer)] = self._dispatch_notification
            return True
        except ImportError:
            logger.warning("ApplicationServices not available — AXObserver disabled")
            return False
        except Exception as e:
            logger.debug("failedToCreateAXObserver for pid %d: %s", self.pid, e)
            return False

    def _dispatch_notification(self, observer: Any, element: Any, notification: str) -> None:
        """Internal dispatch — called from module-level C callback."""
        if self._callback is not None:
            self._callback(observer, element, notification)

    def add_notification(self, element: Any, notification: str) -> bool:
        """Subscribe to a notification on an element."""
        with self._lock:
            if not self._ensure_observer():
                return False
            target_key = (id(element), notification)
            if target_key in self._subscriptions:
                return True  # Already subscribed
            try:
                from ApplicationServices import AXObserverAddNotification
                err = AXObserverAddNotification(self._observer, element, notification, None)
                if err != 0:
                    logger.debug(
                        "AXObserverAddNotification failed for %s: error %d",
                        notification, err,
                    )
                    return False
                self._subscriptions.add(target_key)
                self._subscriptions_refs[target_key] = element
                return True
            except Exception as e:
                logger.debug("Failed to add notification %s: %s", notification, e)
                return False

    def remove_notification(self, element: Any, notification: str) -> None:
        """Unsubscribe from a notification."""
        with self._lock:
            if self._observer is None:
                return
            target_key = (id(element), notification)
            if target_key not in self._subscriptions:
                return
            try:
                from ApplicationServices import AXObserverRemoveNotification
                AXObserverRemoveNotification(self._observer, element, notification)
            except Exception as e:
                logger.debug("Failed to remove notification %s: %s", notification, e)
            self._subscriptions.discard(target_key)
            self._subscriptions_refs.pop(target_key, None)

    def start(self) -> bool:
        """Attach to the shared CFRunLoop and start receiving notifications."""
        with self._lock:
            if self._started:
                return True
            if self._observer is None:
                return False
            run_loop_thread = get_shared_run_loop()
            if run_loop_thread.run_loop is None:
                logger.warning("No run loop available — AXObserver cannot start")
                return False
            try:
                from ApplicationServices import AXObserverGetRunLoopSource
                from CoreFoundation import CFRunLoopAddSource, kCFRunLoopDefaultMode
                source = AXObserverGetRunLoopSource(self._observer)
                CFRunLoopAddSource(run_loop_thread.run_loop, source, kCFRunLoopDefaultMode)
                self._started = True
                return True
            except Exception as e:
                logger.debug("Failed to attach observer to run loop: %s", e)
                return False

    def stop(self) -> None:
        """Detach from CFRunLoop and clean up."""
        with self._lock:
            if not self._started or self._observer is None:
                return
            # Unregister from global callback dispatch
            with _observer_callbacks_lock:
                _observer_callbacks.pop(id(self._observer), None)
            run_loop_thread = _shared_run_loop
            if run_loop_thread.run_loop is not None:
                try:
                    from ApplicationServices import AXObserverGetRunLoopSource
                    from CoreFoundation import CFRunLoopRemoveSource, kCFRunLoopDefaultMode
                    source = AXObserverGetRunLoopSource(self._observer)
                    CFRunLoopRemoveSource(run_loop_thread.run_loop, source, kCFRunLoopDefaultMode)
                except Exception:
                    pass
            # Remove all subscriptions
            for (_, notification), element in list(self._subscriptions_refs.items()):
                try:
                    from ApplicationServices import AXObserverRemoveNotification
                    AXObserverRemoveNotification(self._observer, element, notification)
                except Exception:
                    pass
            self._subscriptions.clear()
            self._subscriptions_refs.clear()
            self._started = False


# ---------------------------------------------------------------------------
# NotificationBridge — routes AX notifications to Python handlers
# ---------------------------------------------------------------------------

class NotificationBridge:
    """Routes AX notifications to registered Python handlers.

    Thread-safe: callbacks arrive on the run loop thread, handlers may
    be registered from any thread.
    """

    def __init__(self) -> None:
        self._handlers: dict[str, list[Callable[[str], None]]] = {}
        self._lock = threading.Lock()
        self._event = threading.Event()
        self._last_notification: str | None = None

    def on_notification(self, observer: Any, element: Any, notification: str) -> None:
        """C callback → Python dispatch. Called on run loop thread."""
        with self._lock:
            self._last_notification = notification
            handlers = list(self._handlers.get(notification, []))
        for handler in handlers:
            try:
                handler(notification)
            except Exception as e:
                logger.debug("Notification handler error for %s: %s", notification, e)
        self._event.set()

    def subscribe(self, notification: str, handler: Callable[[str], None]) -> None:
        """Register handler for a notification type."""
        with self._lock:
            self._handlers.setdefault(notification, []).append(handler)

    def unsubscribe(self, notification: str, handler: Callable[[str], None]) -> None:
        """Unregister handler."""
        with self._lock:
            handlers = self._handlers.get(notification, [])
            try:
                handlers.remove(handler)
            except ValueError:
                pass

    def wait_for_any(self, notifications: list[str], timeout: float) -> str | None:
        """Block until any listed notification fires or timeout.

        Returns the notification name, or None on timeout.
        """
        self._event.clear()
        self._last_notification = None

        if self._event.wait(timeout=timeout):
            return self._last_notification
        return None

    def clear(self) -> None:
        """Clear all handlers."""
        with self._lock:
            self._handlers.clear()
        self._event.clear()
        self._last_notification = None


# ---------------------------------------------------------------------------
# DebounceStateMachine — debounces rapid-fire AX events
# ---------------------------------------------------------------------------

class SettleResult(Enum):
    """Outcome of wait_for_settle."""
    SETTLED = "settled"       # Quiet period elapsed — UI is stable
    TIMEOUT = "timeout"       # Max wait reached — UI may still be changing
    CANCELLED = "cancelled"   # Explicitly cancelled
    NO_CHANGE = "no_change"   # No events fired at all


class DebounceStateMachine:
    """Debounce rapid-fire events, settle after quiet period.

    Usage::

        debounce = DebounceStateMachine(quiet_period=0.15, max_wait=2.0)

        # On each AX notification:
        debounce.signal()

        # After action:
        result = debounce.wait_for_settle()
    """

    def __init__(self, quiet_period: float, max_wait: float) -> None:
        self._quiet_period = quiet_period
        self._max_wait = max_wait
        self._last_signal_time: float | None = None
        self._signal_count = 0
        self._cancelled = False
        self._lock = threading.Lock()
        self._signal_event = threading.Event()

    def signal(self) -> None:
        """An event occurred. Reset quiet period timer."""
        with self._lock:
            self._last_signal_time = time.monotonic()
            self._signal_count += 1
        self._signal_event.set()

    def wait_for_settle(self) -> SettleResult:
        """Block until settled or timeout. Returns reason."""
        start = time.monotonic()
        deadline = start + self._max_wait

        # Wait for first signal or timeout
        first_wait = min(self._quiet_period, self._max_wait)
        if not self._signal_event.wait(timeout=first_wait):
            # No events fired at all within quiet period
            with self._lock:
                if self._cancelled:
                    return SettleResult.CANCELLED
                if self._signal_count == 0:
                    return SettleResult.NO_CHANGE
                # Signal arrived between check and wait
                return SettleResult.SETTLED

        # Events are firing — wait for quiet period
        while time.monotonic() < deadline:
            with self._lock:
                if self._cancelled:
                    return SettleResult.CANCELLED
                last = self._last_signal_time
                if last is not None and (time.monotonic() - last) >= self._quiet_period:
                    return SettleResult.SETTLED

            self._signal_event.clear()
            remaining = deadline - time.monotonic()
            wait_time = min(self._quiet_period, remaining)
            if wait_time <= 0:
                break
            self._signal_event.wait(timeout=wait_time)

        with self._lock:
            if self._cancelled:
                return SettleResult.CANCELLED
        return SettleResult.TIMEOUT

    def cancel(self) -> None:
        """Cancel waiting."""
        with self._lock:
            self._cancelled = True
        self._signal_event.set()

    def reset(self) -> None:
        """Reset state for next use."""
        with self._lock:
            self._last_signal_time = None
            self._signal_count = 0
            self._cancelled = False
        self._signal_event.clear()


# ---------------------------------------------------------------------------
# AXEnablementAssertion — coordinated AX access
# ---------------------------------------------------------------------------

class AXEnablementKind(Enum):
    """Types of AX access that can be asserted."""
    READ_ATTRIBUTES = "read_attributes"
    WRITE_ATTRIBUTES = "write_attributes"
    PERFORM_ACTIONS = "perform_actions"
    OBSERVE_NOTIFICATIONS = "observe_notifications"


class AssertionTracker:
    """Tracks active AX assertions per kind per PID.

    When all assertions for a kind are released, that AX capability
    can be disabled. Prevents resource leaks.
    """

    _lock = threading.Lock()
    _counts: dict[tuple[int, AXEnablementKind], int] = {}
    _initialized_pids: set[int] = set()

    @classmethod
    def acquire(cls, pid: int, kind: AXEnablementKind) -> None:
        with cls._lock:
            key = (pid, kind)
            cls._counts[key] = cls._counts.get(key, 0) + 1
            cls._initialized_pids.add(pid)

    @classmethod
    def release(cls, pid: int, kind: AXEnablementKind) -> None:
        with cls._lock:
            key = (pid, kind)
            count = cls._counts.get(key, 0)
            if count <= 1:
                cls._counts.pop(key, None)
            else:
                cls._counts[key] = count - 1

    @classmethod
    def is_active(cls, pid: int, kind: AXEnablementKind) -> bool:
        with cls._lock:
            return cls._counts.get((pid, kind), 0) > 0

    @classmethod
    def active_count(cls, pid: int, kind: AXEnablementKind) -> int:
        with cls._lock:
            return cls._counts.get((pid, kind), 0)

    @classmethod
    def release_all(cls, pid: int) -> None:
        """Release all assertions for a PID (cleanup on session end)."""
        with cls._lock:
            keys_to_remove = [k for k in cls._counts if k[0] == pid]
            for key in keys_to_remove:
                del cls._counts[key]
            cls._initialized_pids.discard(pid)

    @classmethod
    def reset(cls) -> None:
        """Reset all state (for testing)."""
        with cls._lock:
            cls._counts.clear()
            cls._initialized_pids.clear()


class AXEnablementAssertion:
    """Context manager for coordinated AX access.

    Usage::

        with AXEnablementAssertion(pid, AXEnablementKind.READ_ATTRIBUTES):
            attrs = read_attributes(element)
    """

    def __init__(self, pid: int, kind: AXEnablementKind) -> None:
        self.pid = pid
        self.kind = kind

    def __enter__(self) -> AXEnablementAssertion:
        AssertionTracker.acquire(self.pid, self.kind)
        return self

    def __exit__(self, *exc: Any) -> None:
        AssertionTracker.release(self.pid, self.kind)


@contextmanager
def ax_assertion(pid: int, kind: AXEnablementKind):
    """Functional wrapper for AXEnablementAssertion."""
    AssertionTracker.acquire(pid, kind)
    try:
        yield
    finally:
        AssertionTracker.release(pid, kind)


# ---------------------------------------------------------------------------
# TreeInvalidationMonitor — watches AX tree for structural changes
# ---------------------------------------------------------------------------

class TreeInvalidationMonitor:
    """Watches AX notifications and tracks whether the tree is invalidated.

    - is_invalidated flag with on_invalidation callback
    - Watches 5 notifications: AXUIElementDestroyed, AXCreated, AXWindowCreated,
      AXWindowMoved, AXWindowResized
    - Sets is_invalidated = True on first notification, invokes callback
    - Client calls reset() after refetching the tree

    Reuses the session's existing observer infrastructure.
    """

    def __init__(self) -> None:
        self._is_invalidated = False
        self._lock = threading.Lock()
        self._invalidation_event = threading.Event()

    @property
    def is_invalidated(self) -> bool:
        with self._lock:
            return self._is_invalidated

    def on_notification(self, notification: str) -> None:
        """Called when a tree-invalidating AX notification fires."""
        with self._lock:
            if self._is_invalidated:
                return  # Already invalidated
            self._is_invalidated = True
        self._invalidation_event.set()

    def reset(self) -> None:
        """Reset the invalidation flag (after refetching the tree)."""
        with self._lock:
            self._is_invalidated = False
        self._invalidation_event.clear()

    def wait_for_invalidation(self, timeout: float) -> bool:
        """Block until invalidated or timeout. Returns True if invalidated."""
        return self._invalidation_event.wait(timeout=timeout)


# ---------------------------------------------------------------------------
# wait_for_settle — event-driven settling
# ---------------------------------------------------------------------------

# Per-tool settle timeouts (seconds). get_app_state has no settle.
SETTLE_TIMEOUTS: dict[str, float] = {
    "get_app_state": 0.0,
    "click": 0.8,
    "type_text": 0.3,
    "set_value": 0.3,
    "press_key": 0.5,
    "scroll": 0.5,
    "drag": 1.0,
    "perform_secondary_action": 0.8,
}

# Quiet period: no notifications for this duration = settled
SETTLE_QUIET_PERIOD = 0.10  # 100ms


def wait_for_settle(
    monitor: TreeInvalidationMonitor | None,
    context: str,
    timeout: float = 2.0,
    quiet_period: float = SETTLE_QUIET_PERIOD,
) -> SettleResult:
    """Event-driven settling. Replaces time.sleep(SETTLE_DELAY_MS).

    If monitor is None (observer setup failed), falls back to fixed delay.
    """
    if timeout <= 0:
        return SettleResult.NO_CHANGE

    # Fallback: no monitor available — use fixed delay
    if monitor is None:
        logger.debug(
            "Sleep for %f seconds, waiting for UI to settle (%s).",
            quiet_period, context,
        )
        time.sleep(quiet_period)
        return SettleResult.SETTLED

    logger.debug("Waiting for UI to stabilize (%s).", context)

    # Reset monitor for this settle cycle
    monitor.reset()

    start = time.monotonic()
    deadline = start + timeout

    # Wait for first invalidation or quiet period (no change)
    if not monitor.wait_for_invalidation(timeout=quiet_period):
        # No notifications at all within quiet period — UI didn't change
        if not monitor.is_invalidated:
            logger.debug(
                "UI stabilized, refreshing tree (%s).",
                context,
            )
            return SettleResult.NO_CHANGE

    # Notifications are firing — debounce until quiet
    debounce = DebounceStateMachine(quiet_period=quiet_period, max_wait=timeout)
    debounce.signal()  # Count the first invalidation

    # Bridge future invalidations to the debounce machine
    original_handler = monitor.on_notification

    def _debounce_bridge(notification: str) -> None:
        debounce.signal()

    monitor.on_notification = _debounce_bridge  # type: ignore[assignment]

    try:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            logger.debug(
                "UI settle timeout reached after %f seconds (%s).",
                timeout, context,
            )
            return SettleResult.TIMEOUT

        result = debounce.wait_for_settle()

        elapsed = time.monotonic() - start
        if result == SettleResult.SETTLED or result == SettleResult.NO_CHANGE:
            logger.debug(
                "Debounce elapsed after %f seconds (stable after %f seconds).",
                elapsed, quiet_period,
            )
            logger.debug(
                "UI stabilized, refreshing tree (%s).",
                context,
            )
            return SettleResult.SETTLED
        elif result == SettleResult.TIMEOUT:
            logger.debug(
                "UI settle timeout reached after %f seconds (%s).",
                timeout, context,
            )
            return SettleResult.TIMEOUT
        elif result == SettleResult.CANCELLED:
            logger.debug(
                "UI settle wait cancelled (%s).",
                context,
            )
            return SettleResult.CANCELLED
        return result
    finally:
        # Restore the original handler
        monitor.on_notification = original_handler  # type: ignore[assignment]
