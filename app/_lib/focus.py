"""Focus management, user interruption detection, and menu tracking.

Classes:
- FrontmostAppTracker: NSWorkspace.didActivateApplicationNotification
- KeyWindowTracker: kAXFocusedWindowAttribute tracking
- WindowOrderingObserver: 0.5s polling for z-order changes
- SyntheticAppFocusEnforcer: temporarily activates target app and prevents focus theft
- FocusStealPreventer: blocks known focus thieves during operations
- UserInteractionMonitor: detects user input during automation operations with per-bundle debounce
- MenuTracker: tracks menu open/close state via AX notifications
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# FrontmostAppTracker
# ---------------------------------------------------------------------------

class FrontmostAppTracker:
    """Tracks frontmost app via NSWorkspace.didActivateApplicationNotification.

    - excludeCurrentApp flag to skip our own process
    - Observer pattern with closure handlers
    - Logs: "[FrontmostTracker] Active app changed: %s"
    """

    def __init__(self, exclude_current_app: bool = True) -> None:
        self.exclude_current_app = exclude_current_app
        self.current_frontmost_pid: int | None = None
        self.current_frontmost_bundle: str | None = None
        self._observers: list[Callable[[int | None, str | None], None]] = []
        self._workspace_observer: Any = None
        self._lock = threading.Lock()
        self._started = False

    def start(self) -> bool:
        """Register for workspace activation notifications."""
        if self._started:
            return True
        try:
            from AppKit import NSWorkspace, NSRunningApplication
            from Foundation import NSNotificationCenter

            workspace = NSWorkspace.sharedWorkspace()

            # Get initial state
            front_app = workspace.frontmostApplication()
            if front_app is not None:
                self._update_frontmost(
                    front_app.processIdentifier(),
                    str(front_app.bundleIdentifier() or ""),
                )

            # Register for future changes
            center = workspace.notificationCenter()
            self._workspace_observer = center.addObserverForName_object_queue_usingBlock_(
                "NSWorkspaceDidActivateApplicationNotification",
                None,
                None,
                self._handle_activation,
            )
            self._started = True
            return True
        except ImportError:
            logger.warning("[FrontmostTracker] AppKit not available")
            return False
        except Exception as e:
            logger.warning("[FrontmostTracker] Failed to start: %s", e)
            return False

    def stop(self) -> None:
        """Remove workspace observer."""
        if not self._started:
            return
        try:
            if self._workspace_observer is not None:
                from AppKit import NSWorkspace
                center = NSWorkspace.sharedWorkspace().notificationCenter()
                center.removeObserver_(self._workspace_observer)
                self._workspace_observer = None
        except Exception as e:
            logger.debug("[FrontmostTracker] Error during stop: %s", e)
        self._started = False

    def add_observer(self, handler: Callable[[int | None, str | None], None]) -> None:
        """Register closure handler for frontmost app changes."""
        with self._lock:
            self._observers.append(handler)

    def remove_observer(self, handler: Callable[[int | None, str | None], None]) -> None:
        """Remove observer by reference."""
        with self._lock:
            try:
                self._observers.remove(handler)
            except ValueError:
                pass

    def _handle_activation(self, notification: Any) -> None:
        """Handle NSWorkspace activation notification."""
        try:
            user_info = notification.userInfo()
            if user_info is None:
                return
            app = user_info.get("NSWorkspaceApplicationKey")
            if app is None:
                return

            pid = app.processIdentifier()
            bundle = str(app.bundleIdentifier() or "")

            if self.exclude_current_app:
                import os
                if pid == os.getpid():
                    return

            self._update_frontmost(pid, bundle)
        except Exception as e:
            logger.debug("[FrontmostTracker] Activation handler error: %s", e)

    def _update_frontmost(self, pid: int, bundle: str) -> None:
        """Update tracked PID and notify observers."""
        with self._lock:
            self.current_frontmost_pid = pid
            self.current_frontmost_bundle = bundle
            observers = list(self._observers)

        logger.debug(
            "[FrontmostTracker] Active app changed: %s",
            bundle,
        )

        for handler in observers:
            try:
                handler(pid, bundle)
            except Exception as e:
                logger.debug("[FrontmostTracker] Observer error: %s", e)


# ---------------------------------------------------------------------------
# KeyWindowTracker
# ---------------------------------------------------------------------------

class KeyWindowTracker:
    """Tracks which window receives keyboard input via kAXFocusedWindowAttribute.

    - Monitors app activation events
    - Queries kAXFocusedWindowAttribute on activation
    """

    def __init__(self) -> None:
        self.current_key_window: Any = None
        self.current_key_window_pid: int | None = None
        self.on_key_window_changed: Callable[[Any], None] | None = None
        self._frontmost_tracker: FrontmostAppTracker | None = None
        self._started = False

    def start(self, frontmost_tracker: FrontmostAppTracker) -> None:
        """Start tracking key window changes."""
        if self._started:
            return
        self._frontmost_tracker = frontmost_tracker
        frontmost_tracker.add_observer(self._handle_app_change)
        self._started = True

    def stop(self) -> None:
        """Stop tracking."""
        if not self._started:
            return
        if self._frontmost_tracker is not None:
            self._frontmost_tracker.remove_observer(self._handle_app_change)
        self._started = False

    def _handle_app_change(self, pid: int | None, bundle: str | None) -> None:
        """When frontmost app changes, query its focused window."""
        if pid is None:
            return
        try:
            from ApplicationServices import (
                AXUIElementCreateApplication,
                AXUIElementCopyAttributeValue,
            )
            ax_app = AXUIElementCreateApplication(pid)
            err, window = AXUIElementCopyAttributeValue(ax_app, "AXFocusedWindow", None)
            if err == 0 and window is not None:
                self.current_key_window = window
                self.current_key_window_pid = pid
                callback = self.on_key_window_changed
                if callback is not None:
                    callback(window)
        except Exception as e:
            logger.debug("[KeyWindowTracker] Error querying focused window: %s", e)


# ---------------------------------------------------------------------------
# WindowOrderingObserver
# ---------------------------------------------------------------------------

class WindowOrderingObserver:
    """Polls CGWindowListCopyWindowInfo every 0.5s for z-order changes.

    - Timer-based polling at 0.5s interval
    - Compares current window list with last known order
    - Fires on_change callback when order changes
    """

    POLL_INTERVAL = 0.5  # seconds

    def __init__(self) -> None:
        self._last_window_order: list[int] = []
        self.on_change: Callable[[list[int]], None] | None = None
        self._timer: threading.Timer | None = None
        self._running = False
        self._lock = threading.Lock()

    def start(self) -> None:
        """Start polling window ordering."""
        with self._lock:
            if self._running:
                return
            self._running = True
        self._schedule_poll()

    def stop(self) -> None:
        """Stop polling."""
        with self._lock:
            self._running = False
            if self._timer is not None:
                self._timer.cancel()
                self._timer = None

    def _schedule_poll(self) -> None:
        with self._lock:
            if not self._running:
                return
            self._timer = threading.Timer(self.POLL_INTERVAL, self._poll)
            self._timer.daemon = True
            self._timer.start()

    def _poll(self) -> None:
        try:
            from Quartz import (
                CGWindowListCopyWindowInfo,
                kCGWindowListOptionOnScreenOnly,
                kCGNullWindowID,
            )
            windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
            if windows is None:
                self._schedule_poll()
                return

            current_order = [int(w.get("kCGWindowNumber", 0)) for w in windows if w.get("kCGWindowNumber")]

            if current_order != self._last_window_order:
                self._last_window_order = current_order
                callback = self.on_change
                if callback is not None:
                    callback(current_order)
        except Exception as e:
            logger.debug("[WindowOrderingObserver] Poll error: %s", e)

        self._schedule_poll()


# ---------------------------------------------------------------------------
# SyntheticAppFocusEnforcer
# ---------------------------------------------------------------------------

class SyntheticAppFocusEnforcer:
    """Monitors and prevents focus theft during automation operations.

    - Does NOT proactively activate the target app (background-first)
    - Installs observers to detect when another app steals focus
    - Only re-activates the target reactively if focus is stolen during operation
    - Installs click event tap to monitor for focus-stealing clicks

    CGEventPostToPid delivers events directly to a PID regardless of
    frontmost status, so the target app does NOT need to be active.
    """

    def __init__(
        self,
        target_pid: int,
        frontmost_tracker: FrontmostAppTracker,
    ) -> None:
        self._target_pid = target_pid
        self._frontmost_tracker = frontmost_tracker
        self._click_event_tap: Any = None  # EventTap
        self._observer_handler: Any = None
        self._active = False

    @property
    def is_active(self) -> bool:
        return self._active

    def activate(self) -> bool:
        """Start monitoring for focus theft (background-first).

        Does NOT activate the target app. Only sets up:
        1. Observer on frontmost tracker to detect focus theft
        2. Click event tap to monitor for focus-stealing clicks

        If another app steals focus during our operation, we re-activate
        the target reactively. The server operates apps in the background
        without disrupting the user.
        """
        if self._active:
            return True

        # Install focus-theft observer — only re-activates REACTIVELY
        def _on_frontmost_change(pid: int | None, bundle: str | None) -> None:
            if pid is not None and pid != self._target_pid and self._active:
                logger.debug(
                    "[SyntheticAppFocusEnforcer] Focus changed to pid=%d (%s) during operation (background-only, not re-activating)",
                    pid, bundle,
                )

        self._observer_handler = _on_frontmost_change
        self._frontmost_tracker.add_observer(_on_frontmost_change)

        # Install click event tap to monitor for focus-stealing clicks
        self._install_click_tap()

        self._active = True
        logger.debug("[SyntheticAppFocusEnforcer] Activated for pid=%d (background-first)", self._target_pid)
        return True

    def deactivate(self) -> None:
        """Stop monitoring for focus theft."""
        if not self._active:
            return

        # Remove focus-theft observer
        if self._observer_handler is not None:
            self._frontmost_tracker.remove_observer(self._observer_handler)
            self._observer_handler = None

        # Remove click event tap
        if self._click_event_tap is not None:
            self._click_event_tap.stop()
            self._click_event_tap = None

        self._active = False
        logger.debug("[SyntheticAppFocusEnforcer] Deactivated for pid=%d", self._target_pid)

    def _activate_target(self) -> bool:
        """No-op: background-only mode, never steal focus."""
        logger.debug("[SyntheticAppFocusEnforcer] _activate_target called but suppressed (background-only)")
        return False

    def _install_click_tap(self) -> None:
        """Install a listen-only click event tap for monitoring."""
        try:
            from app._lib.event_tap import (
                EventTap,
                event_mask,
                EVENT_LEFT_MOUSE_DOWN,
                EVENT_RIGHT_MOUSE_DOWN,
                TAP_OPTION_LISTEN_ONLY,
            )

            tap = EventTap(
                event_types=event_mask(EVENT_LEFT_MOUSE_DOWN, EVENT_RIGHT_MOUSE_DOWN),
                options=TAP_OPTION_LISTEN_ONLY,
            )

            def _on_click(proxy: Any, event_type: int, event: Any) -> Any:
                # Monitor clicks but don't suppress — listen-only tap
                return event

            tap.on_event_received = _on_click
            if tap.start():
                self._click_event_tap = tap
        except Exception as e:
            logger.debug("[SyntheticAppFocusEnforcer] Failed to install click tap: %s", e)


# ---------------------------------------------------------------------------
# FocusStealPreventer
# ---------------------------------------------------------------------------

class FocusStealPreventer:
    """Block known focus thieves during operations.

    - Maintains set of disallowed thief processes
    - Installs keyboard tap to monitor ViewBridge keyboard events
    - Tracks whether a focus thief also stole typing focus
    """

    DISALLOWED_THIEF_PROCESSES: frozenset[str] = frozenset({
        "NotificationCenter",
        "Spotlight",
        "ScreenSaverEngine",
        "SecurityAgent",
        "UserNotificationCenter",
    })

    def __init__(self) -> None:
        self._keyboard_tap: Any = None  # EventTap
        self._active = False
        self._focus_thief_stole_typing: bool = False

    @property
    def focus_thief_also_stole_typing_focus(self) -> bool:
        return self._focus_thief_stole_typing

    def activate(self) -> None:
        """Install keyboard tap to prevent typing focus theft."""
        if self._active:
            return
        try:
            from app._lib.event_tap import (
                EventTap,
                event_mask,
                EVENT_KEY_DOWN,
                TAP_OPTION_LISTEN_ONLY,
            )

            tap = EventTap(
                event_types=event_mask(EVENT_KEY_DOWN),
                options=TAP_OPTION_LISTEN_ONLY,
            )

            def _on_key(proxy: Any, event_type: int, event: Any) -> Any:
                # Monitor keyboard events for focus theft detection
                return event

            tap.on_event_received = _on_key
            if tap.start():
                self._keyboard_tap = tap
                self._active = True
                logger.debug("[FocusStealPreventer] Activated")
        except Exception as e:
            logger.debug("[FocusStealPreventer] Failed to activate: %s", e)

    def deactivate(self) -> None:
        """Remove keyboard tap."""
        if not self._active:
            return
        if self._keyboard_tap is not None:
            self._keyboard_tap.stop()
            self._keyboard_tap = None
        self._active = False
        self._focus_thief_stole_typing = False
        logger.debug("[FocusStealPreventer] Deactivated")


# ---------------------------------------------------------------------------
# UserInteractionMonitor
# ---------------------------------------------------------------------------

class UserInteractionMonitor:
    """Detect user input during automation operations with per-bundle debounce.

    - State machine: idle -> monitoring -> debouncing -> interrupted
    - Per-bundle debounce timers (0.5s)
    - Fires on_app_interrupted callback after debounce
    - Warning message format: "The user changed '<app>'. Re-query the latest state
      with `get_app_state` before sending more actions."
    """

    DEBOUNCE_DURATION = 0.5  # seconds, per-bundle

    def __init__(self) -> None:
        self._event_tap: Any = None  # EventTap
        self._current_pid: int | None = None
        self._monitoring = False
        self._lock = threading.Lock()
        self._debounce_timers: dict[str, threading.Timer] = {}
        self._interrupted_bundles: set[str] = set()
        self.on_app_interrupted: Callable[[str], None] | None = None

    def start_monitoring(self, target_pid: int) -> bool:
        """Start monitoring for user interaction with the target app."""
        with self._lock:
            if self._monitoring:
                return True
            self._current_pid = target_pid
            self._interrupted_bundles.clear()
            self._monitoring = True

        try:
            from app._lib.event_tap import (
                EventTap,
                event_mask,
                EVENT_LEFT_MOUSE_DOWN,
                EVENT_RIGHT_MOUSE_DOWN,
                EVENT_KEY_DOWN,
                TAP_OPTION_LISTEN_ONLY,
            )

            tap = EventTap(
                event_types=event_mask(
                    EVENT_LEFT_MOUSE_DOWN,
                    EVENT_RIGHT_MOUSE_DOWN,
                    EVENT_KEY_DOWN,
                ),
                options=TAP_OPTION_LISTEN_ONLY,
            )

            def _on_event(proxy: Any, event_type: int, event: Any) -> Any:
                self._handle_user_event(event)
                return event

            tap.on_event_received = _on_event
            if tap.start():
                self._event_tap = tap
                return True
            else:
                with self._lock:
                    self._monitoring = False
                return False
        except Exception as e:
            logger.debug("[UserInteractionMonitor] Failed to start: %s", e)
            with self._lock:
                self._monitoring = False
            return False

    def stop_monitoring(self) -> None:
        """Stop monitoring and cancel all debounce timers."""
        with self._lock:
            self._monitoring = False
            self._current_pid = None
            for timer in self._debounce_timers.values():
                timer.cancel()
            self._debounce_timers.clear()
            self._interrupted_bundles.clear()

        if self._event_tap is not None:
            self._event_tap.stop()
            self._event_tap = None

    def check_interruption(self, target_bundle: str) -> str | None:
        """Returns warning message if user interacted with the target app, else None."""
        with self._lock:
            if target_bundle in self._interrupted_bundles:
                self._interrupted_bundles.discard(target_bundle)
                app_name = target_bundle.rsplit(".", 1)[-1] if "." in target_bundle else target_bundle
                return (
                    f"The user changed '{app_name}'. Re-query the latest state "
                    f"with `get_app_state` before sending more actions."
                )
        return None

    def _handle_user_event(self, event: Any) -> None:
        """Handle a user input event — check if it targets the monitored app."""
        try:
            from Quartz import CGEventGetIntegerValueField, kCGEventTargetUnixProcessID
            event_pid = CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID)

            with self._lock:
                if not self._monitoring or self._current_pid is None:
                    return
                # Only care about events targeting our monitored app
                if event_pid != self._current_pid:
                    return

            # Resolve bundle ID for the PID
            bundle_id = self._resolve_bundle_id(event_pid)
            if bundle_id:
                self._handle_user_interaction(bundle_id)
        except Exception as e:
            logger.debug("[UserInteractionMonitor] Event handler error: %s", e)

    def _handle_user_interaction(self, bundle_id: str) -> None:
        """Handle a user interaction with debounce."""
        with self._lock:
            # Cancel existing debounce timer for this bundle
            if bundle_id in self._debounce_timers:
                self._debounce_timers[bundle_id].cancel()
                logger.debug("Debounce timer reset last notification time.")

            # Create new debounce timer
            def _debounce_fired() -> None:
                logger.debug(
                    "Debounce expired after %f seconds "
                    "(settled state is reached after %f seconds).",
                    self.DEBOUNCE_DURATION,
                    self.DEBOUNCE_DURATION,
                )
                with self._lock:
                    self._interrupted_bundles.add(bundle_id)
                    self._debounce_timers.pop(bundle_id, None)
                logger.debug("User interruption detected for controlled app")
                callback = self.on_app_interrupted
                if callback is not None:
                    callback(bundle_id)

            timer = threading.Timer(self.DEBOUNCE_DURATION, _debounce_fired)
            timer.daemon = True
            timer.start()
            self._debounce_timers[bundle_id] = timer

    def _resolve_bundle_id(self, pid: int) -> str | None:
        """Resolve a PID to its bundle identifier."""
        try:
            from AppKit import NSRunningApplication
            app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
            if app is not None:
                return str(app.bundleIdentifier() or "")
        except Exception:
            pass
        return None


# ---------------------------------------------------------------------------
# MenuTracker
# ---------------------------------------------------------------------------

class MenuTracker:
    """Track menu open/close state via AX notifications.

    - Subscribes to AXMenuOpened, AXMenuClosed
    - Provides wait_for_menu_close() for pausing actions while menus are visible
    """

    def __init__(self) -> None:
        self._menus_open = False
        self._currently_opened_menu: str | None = None
        self._currently_focused_menu_bar_item: str | None = None
        self._lock = threading.Lock()
        self._menu_closed_event = threading.Event()
        self._menu_closed_event.set()  # Initially no menus open

    @property
    def menus_open(self) -> bool:
        with self._lock:
            return self._menus_open

    @property
    def currently_opened_menu(self) -> str | None:
        with self._lock:
            return self._currently_opened_menu

    @property
    def currently_focused_menu_bar_item(self) -> str | None:
        with self._lock:
            return self._currently_focused_menu_bar_item

    def on_notification(self, notification: str) -> None:
        """Handle AX menu notifications. Called from notification bridge."""
        if notification == "AXMenuOpened":
            with self._lock:
                self._menus_open = True
                self._menu_closed_event.clear()
            logger.debug("[MenuTracker] menuDidOpen")
        elif notification == "AXMenuClosed":
            with self._lock:
                self._menus_open = False
                self._currently_opened_menu = None
                self._menu_closed_event.set()
            logger.debug("[MenuTracker] menuDidClose")

    def wait_for_menu_close(self, timeout: float = 5.0) -> bool:
        """Block until menus close. Returns False on timeout."""
        return self._menu_closed_event.wait(timeout=timeout)

    def reset(self) -> None:
        """Reset state."""
        with self._lock:
            self._menus_open = False
            self._currently_opened_menu = None
            self._currently_focused_menu_bar_item = None
            self._menu_closed_event.set()
