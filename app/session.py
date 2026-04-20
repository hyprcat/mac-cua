from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from PIL import Image

from app.response import AppState, Node, Point, Rect, Size, ToolResponse
from app._lib.errors import (
    AppBlockedError,
    AutomationError,
    BadIndexError,
    InputError,
    RefetchError,
    ScreenshotError,
    StaleReferenceError,
    StepLimitError,
)
from app._lib import apps, accessibility, screenshot, input as cg_input
from app._lib.tree import serialize, make_header
from app._lib.tracing import controller_tracer
from app._lib.flags import feature_flags, workaround_flags
from app._lib.safety import SafetyBlocklist
from app._lib.analytics import analytics
from app._lib.elicitation import AppApprovalStore
from app._lib.lifecycle import SessionLifecycle
from app._lib.refetchable_tree import RefetchableTree, RefetchErrorCode
from app._lib.screen_capture import (
    get_screen_capture_worker,
    get_screenshot_classifier,
    is_sck_available,
)
from app._lib.retry import RetryPolicy, with_retry, SCREENSHOT_RETRY_POLICY
from app._lib.screenshot import ApplicationWindow
from app._lib.observer import (
    AXNotificationObserver,
    AX_NOTIFICATION_MENU_OPENED,
    AX_NOTIFICATION_MENU_CLOSED,
    NotificationBridge,
    TreeInvalidationMonitor,
    TREE_INVALIDATION_NOTIFICATIONS,
    SETTLE_TIMEOUTS,
    SETTLE_QUIET_PERIOD,
    SettleResult,
    wait_for_settle,
    AssertionTracker,
    AXEnablementKind,
    get_shared_run_loop,
)
from app._lib.focus import (
    FrontmostAppTracker,
    KeyWindowTracker,
    WindowOrderingObserver,
    SyntheticAppFocusEnforcer,
    UserInteractionMonitor,
    MenuTracker,
)
from app._lib.virtual_cursor import (
    AppType,
    BackgroundCursor,
    InputStrategy,
    VirtualKeyPress,
    WindowUIElement,
    detect_app_type,
)
from app._lib.selection import (
    SelectionClient,
    SelectionExtractor,
    format_selection,
)
from app._lib.accessibility import (
    EditableTextObject,
    extract_web_area_text,
    extract_text_area_content,
    get_web_url,
)

logger = logging.getLogger(__name__)

WINDOW_RETRY_DELAY_S = 0.15
SCREENSHOT_RETRY_DELAY_S = 0.1
SCROLL_CLICKS_PER_PAGE = 6

# Maximum serialized tree size in bytes. If the tree_text exceeds this after
# pruning, the oldest lines are dropped until it fits. Prevents oversized
# responses from web-heavy apps (e.g. Safari on claude.ai).
TREE_BYTE_BUDGET = 30_000

GUIDANCE_DIR = Path(__file__).parent / "guidance"

# Threshold below which the AX tree is considered too sparse for reliable
# element-indexed interaction.  The model should prefer coordinate-based
# clicks when the tree has fewer actionable elements than this.
AX_POOR_THRESHOLD = 5

_AX_POOR_GUIDANCE = (
    "This app has limited accessibility support — the element tree is sparse or empty. "
    "Prefer coordinate-based interactions (click with x/y from the screenshot) over element indices. "
    "press_key and type_text still work normally."
)

# Mapping from key names to AX actions for element-targeted key presses.
# These AX actions work reliably in background apps without CGEvents.
_KEY_TO_AX_ACTION: dict[str, str] = {
    "return": "AXConfirm",
    "enter": "AXConfirm",
    "escape": "AXCancel",
}

_WEB_CONTAINER_ROLES = frozenset({"web area"})
_POINTER_PREFERRED_ROLES = frozenset({
    "button",
    "check box",
    "combo box",
    "link",
    "menu item",
    "pop up button",
    "radio button",
    "row",
    "slider",
    "tab",
    "text area",
    "text field",
})


@dataclass
class AppTarget:
    bundle_id: str
    pid: int
    window_id: int
    window_pid: int
    ax_app: Any
    ax_window: Any


@dataclass
class AppSession:
    target: AppTarget
    snapshot_id: int = 0
    tree_nodes: list[Node] = field(default_factory=list)
    guidance: str | None = None
    screenshot_size: tuple[int, int] | None = None
    # Observer infrastructure — created per-session for tree invalidation
    observer: AXNotificationObserver | None = field(default=None, repr=False)
    notification_bridge: NotificationBridge | None = field(default=None, repr=False)
    # Tree invalidation monitor — event-driven settling
    invalidation_monitor: TreeInvalidationMonitor | None = field(default=None, repr=False)
    # Refetchable tree — cached tree with element refetch
    refetchable_tree: RefetchableTree | None = field(default=None, repr=False)
    guidance_delivered: bool = False  # Once-per-session delivery
    # Focus, input strategy, menu tracking
    focus_enforcer: SyntheticAppFocusEnforcer | None = field(default=None, repr=False)
    input_strategy: InputStrategy | None = field(default=None, repr=False)
    menu_tracker: MenuTracker | None = field(default=None, repr=False)
    app_type: AppType = field(default=AppType.NATIVE_COCOA, repr=False)
    cursor: BackgroundCursor | None = field(default=None, repr=False)
    # Selection tracking
    selection_client: SelectionClient | None = field(default=None, repr=False)
    # ApplicationWindow bridge (permanent CG+AX association)
    application_window: ApplicationWindow | None = field(default=None, repr=False)
    # Scroll: cached working method per session (None = not yet determined)
    # Values: "ax", "pid", "system", None
    scroll_method: str | None = field(default=None, repr=False)


class SessionManager:
    def __init__(self) -> None:
        self._sessions: dict[int, AppSession] = {}
        self._bundle_to_window: dict[str, int] = {}
        self._guidance_cache: dict[str, str | None] = {}
        # Global trackers (shared across all sessions)
        self._frontmost_tracker = FrontmostAppTracker(exclude_current_app=True)
        self._key_window_tracker = KeyWindowTracker()
        self._window_ordering_observer = WindowOrderingObserver()
        self._user_interaction_monitor = UserInteractionMonitor()
        self._trackers_started = False
        # Safety, approvals, lifecycle
        self._safety = SafetyBlocklist(
            allow_forbidden=feature_flags.allow_forbidden_targets,
        )
        self._approval_store = AppApprovalStore()
        self._lifecycle = SessionLifecycle(step_limit=workaround_flags.loop_step_limit)

    def _ensure_trackers_started(self) -> None:
        """Start global trackers on first use (lazy init)."""
        if self._trackers_started:
            return
        if feature_flags.focus_enforcement:
            self._frontmost_tracker.start()
            self._key_window_tracker.start(self._frontmost_tracker)
        if feature_flags.user_interruption_detection:
            # User interaction monitor starts per-session via start_monitoring()
            pass
        self._trackers_started = True

    def _check_safety(self, bundle_id: str) -> None:
        """Pipeline step 2-3: Check app blocklist."""
        block_reason = self._safety.check_app(bundle_id)
        if block_reason is not None:
            raise AppBlockedError(
                f"Automation is not allowed to use the app "
                f"'{bundle_id}' for safety reasons."
            )

    def _check_approval(self, bundle_id: str) -> None:
        """Pipeline step 2: Check app approval status."""
        if not self._approval_store.is_approved(bundle_id):
            self._approval_store.approve_for_session(bundle_id)
            analytics.mcp_app_approval_resolved(bundle_id, approved=True)
            logger.debug("Auto-approved app: %s", bundle_id)

    def _drop_session(self, window_id: int) -> None:
        session = self._sessions.pop(window_id, None)
        if session is None:
            return
        # Clean up observer infrastructure
        self._teardown_observer(session)
        # Release all AX assertions for this session's PID
        AssertionTracker.release_all(session.target.pid)
        bundle_id = session.target.bundle_id
        if self._bundle_to_window.get(bundle_id) == window_id:
            del self._bundle_to_window[bundle_id]

    def _setup_observer(self, session: AppSession) -> None:
        """Create and start AXNotificationObserver for a session.

        Subscribes to tree invalidation notifications on the session's window
        element. Creates a TreeInvalidationMonitor that bridges AX notifications
        to event-driven settling.
        """
        if session.observer is not None:
            return  # Already set up
        if session.target.ax_window is None:
            return

        # Create invalidation monitor and bridge notifications to it
        invalidation_monitor = TreeInvalidationMonitor()
        bridge = NotificationBridge()

        # Route tree invalidation notifications to the monitor
        for notification in TREE_INVALIDATION_NOTIFICATIONS:
            bridge.subscribe(notification, invalidation_monitor.on_notification)

        observer = AXNotificationObserver(session.target.pid, callback=bridge.on_notification)

        # Subscribe to tree invalidation notifications on the window element
        for notification in TREE_INVALIDATION_NOTIFICATIONS:
            if not observer.add_notification(session.target.ax_window, notification):
                logger.debug(
                    "Failed to subscribe to %s for %s",
                    notification, session.target.bundle_id,
                )

        # Set up menu tracking via AX notifications
        menu_tracker = None
        if feature_flags.menu_tracking:
            menu_tracker = MenuTracker()
            bridge.subscribe(AX_NOTIFICATION_MENU_OPENED, menu_tracker.on_notification)
            bridge.subscribe(AX_NOTIFICATION_MENU_CLOSED, menu_tracker.on_notification)
            # Subscribe to menu notifications on the window element
            observer.add_notification(session.target.ax_window, AX_NOTIFICATION_MENU_OPENED)
            observer.add_notification(session.target.ax_window, AX_NOTIFICATION_MENU_CLOSED)

        if observer.start():
            session.observer = observer
            session.notification_bridge = bridge
            session.invalidation_monitor = invalidation_monitor
            session.menu_tracker = menu_tracker
            logger.debug(
                "AXObserver started for %s (pid %d) with %d notifications",
                session.target.bundle_id,
                session.target.pid,
                len(TREE_INVALIDATION_NOTIFICATIONS),
            )
        else:
            logger.debug(
                "AXObserver failed to start for %s — falling back to fixed delay",
                session.target.bundle_id,
            )
            observer.stop()

        # Set up selection tracking client
        if feature_flags.system_selection and session.selection_client is None:
            sel_client = SelectionClient()
            sel_client.start_observing(session.target.pid, session.target.bundle_id)
            session.selection_client = sel_client
            logger.debug(
                "Selection client started for %s (pid %d)",
                session.target.bundle_id, session.target.pid,
            )

        # Set up input strategy based on app type detection
        if session.input_strategy is None:
            session.app_type = detect_app_type(session.target.bundle_id, session.target.pid)
            session.input_strategy = InputStrategy(
                session.app_type,
                force_simulate=feature_flags.always_simulate_click,
            )
            logger.debug(
                "Input strategy for %s: app_type=%s",
                session.target.bundle_id, session.app_type.value,
            )

    def _teardown_observer(self, session: AppSession) -> None:
        """Stop and clean up the observer for a session."""
        if session.observer is not None:
            session.observer.stop()
            session.observer = None
        if session.notification_bridge is not None:
            session.notification_bridge.clear()
            session.notification_bridge = None
        session.invalidation_monitor = None
        # Clean up selection client
        if session.selection_client is not None:
            session.selection_client.stop_observing()
            session.selection_client = None
        # Clean up focus and menu resources
        if session.focus_enforcer is not None:
            session.focus_enforcer.deactivate()
            session.focus_enforcer = None
        if session.menu_tracker is not None:
            session.menu_tracker.reset()
            session.menu_tracker = None

    def _activate_focus_enforcement(self, session: AppSession) -> None:
        """Step 6: Temporarily activate target app for reliable input delivery.

        Creates a SyntheticAppFocusEnforcer that:
        1. Records current frontmost app
        2. Activates target app
        3. Monitors for focus theft and re-activates
        """
        if session.focus_enforcer is not None and session.focus_enforcer.is_active:
            return  # Already enforcing
        enforcer = SyntheticAppFocusEnforcer(
            target_pid=session.target.pid,
            frontmost_tracker=self._frontmost_tracker,
        )
        if enforcer.activate():
            session.focus_enforcer = enforcer
        else:
            logger.debug(
                "Focus enforcement failed for %s — proceeding without",
                session.target.bundle_id,
            )

    def _deactivate_focus_enforcement(self, session: AppSession) -> None:
        """Step 11: Restore previous frontmost app after action completes."""
        if session.focus_enforcer is not None:
            session.focus_enforcer.deactivate()
            session.focus_enforcer = None

    def _cleanup_after_action(self, session: AppSession | None) -> None:
        """Clean up focus/input resources after action (success or error)."""
        if session is None:
            return
        if feature_flags.focus_enforcement:
            self._deactivate_focus_enforcement(session)
        if feature_flags.user_interruption_detection:
            self._user_interaction_monitor.stop_monitoring()

    def _track_session(self, session: AppSession, previous_window_id: int | None = None) -> None:
        if previous_window_id is not None and previous_window_id != session.target.window_id:
            self._drop_session(previous_window_id)
        displaced = self._sessions.get(session.target.window_id)
        if displaced is not None and displaced is not session:
            self._teardown_observer(displaced)
            displaced_bundle_id = displaced.target.bundle_id
            if self._bundle_to_window.get(displaced_bundle_id) == session.target.window_id:
                del self._bundle_to_window[displaced_bundle_id]
        self._sessions[session.target.window_id] = session
        self._bundle_to_window[session.target.bundle_id] = session.target.window_id
        # Set up observer for tree invalidation
        self._setup_observer(session)

    def execute(self, tool: str, params: dict) -> ToolResponse:
        """Execute a tool call following the action pipeline.

        Pipeline steps:
        1. Log tool call
        2. Check app approval
        3. Check URL blocklist
        4. Ensure permissions
        5. Resolve element
        6. Enforce focus
        7. Execute action
        8. Wait for settle (event-driven)
        9. Check user interruption
        10. Capture snapshot
        11. Deactivate focus enforcement
        12. Return response
        """
        # Step 1: Log tool call
        logger.info("Tool call: %s", tool)

        if tool == "list_apps":
            return self._handle_list_apps()

        session = None
        interruption_msg = None
        with controller_tracer.interval(f"Action:{tool}") as span:
            try:
                with controller_tracer.interval("Resolve Session"):
                    self._ensure_trackers_started()
                    session = self._resolve_session(tool, params)
                # Step 1b: Analytics
                analytics.mcp_tool_called(tool)
                # Step 2: Check safety blocklist
                self._check_safety(session.target.bundle_id)
                # Step 2b: Check app approval
                self._check_approval(session.target.bundle_id)
                # Step 3: Track lifecycle
                self._lifecycle.track_app_used(session.target.bundle_id)
                self._lifecycle.increment_step()
                if self._lifecycle.check_step_limit():
                    raise StepLimitError(
                        f"Step limit reached ({workaround_flags.loop_step_limit}). "
                        f"End your current loop and summarize progress."
                    )
                # Step 6: Enforce focus
                if (
                    feature_flags.focus_enforcement
                    and tool not in ("get_app_state", "list_apps")
                ):
                    self._activate_focus_enforcement(session)
                # Step 6b: Wait for menus to close before acting
                if (
                    feature_flags.menu_tracking
                    and session.menu_tracker is not None
                    and session.menu_tracker.menus_open
                    and tool not in ("get_app_state", "list_apps")
                ):
                    logger.debug("Waiting for menus to close before %s", tool)
                    session.menu_tracker.wait_for_menu_close(timeout=3.0)
                # Step 6c: Start user interaction monitoring
                if (
                    feature_flags.user_interruption_detection
                    and tool not in ("get_app_state", "list_apps")
                ):
                    self._user_interaction_monitor.start_monitoring(session.target.pid)
                # Steps 5-7: Element resolution + execute action
                with controller_tracer.interval(f"Execute:{tool}"):
                    result = self._dispatch(tool, session, params)
                # Step 8: Wait for settle (event-driven via TreeInvalidationMonitor)
                settle_timeout = SETTLE_TIMEOUTS.get(tool, 1.0)
                if settle_timeout > 0:
                    with controller_tracer.interval("Wait for Settle"):
                        wait_for_settle(
                            session.invalidation_monitor,
                            context=tool,
                            timeout=settle_timeout,
                            quiet_period=SETTLE_QUIET_PERIOD,
                        )
                # Step 9: User interruption check
                if feature_flags.user_interruption_detection:
                    interruption_msg = self._user_interaction_monitor.check_interruption(
                        session.target.bundle_id,
                    )
                    if interruption_msg is not None:
                        logger.info("userInterruptedControlledApp: %s", interruption_msg)
                    self._user_interaction_monitor.stop_monitoring()
                # Step 10: Capture snapshot
                with controller_tracer.interval("Capture Snapshot"):
                    # Skip redundant window refresh — session was just
                    # validated in _resolve_session and action just executed
                    response = self.take_snapshot(session, skip_refresh=True)
                response.result = result
                analytics.service_result(tool, success=True, duration_ms=0.0)
                # Attach interruption warning to response if detected
                if feature_flags.user_interruption_detection and interruption_msg is not None:
                    response.result = f"{result}\n\n⚠️ {interruption_msg}" if result else interruption_msg
                if tool == "get_app_state":
                    if not session.guidance_delivered:
                        guidance = self._load_guidance(session.target.bundle_id)
                        # Detect AX-poor apps and inject coordinate-mode guidance
                        interactive = sum(
                            1 for n in response.tree_nodes
                            if n.role in _POINTER_PREFERRED_ROLES
                        )
                        if interactive < AX_POOR_THRESHOLD:
                            ax_poor_hint = _AX_POOR_GUIDANCE
                            guidance = f"{guidance}\n\n{ax_poor_hint}" if guidance else ax_poor_hint
                            logger.info(
                                "AX-poor app detected: %s (%d interactive elements, threshold %d)",
                                session.target.bundle_id, interactive, AX_POOR_THRESHOLD,
                            )
                        response.guidance = guidance
                        session.guidance_delivered = True
                # Step 11: Deactivate focus enforcement
                if feature_flags.focus_enforcement:
                    self._deactivate_focus_enforcement(session)
                # Step 12: Return response
                return response
            except StaleReferenceError as e:
                self._cleanup_after_action(session)
                if session:
                    response = self.take_snapshot(session)
                    response.error = f"Element reference became stale: {e}. Tree refreshed."
                    return response
                return self._error_only(str(e))
            except AutomationError as e:
                self._cleanup_after_action(session)
                if session:
                    return self._try_snapshot_or_error(session, e)
                return self._error_only(str(e))

    def _resolve_session(self, tool: str, params: dict) -> AppSession:
        window_id = params.get("window_id")
        if window_id is not None:
            return self.get_or_create_session_for_window(int(window_id))

        app = params.get("app")
        if app is None:
            raise AutomationError(
                f"{tool} requires window_id or app. Prefer window_id from the latest get_app_state."
            )

        return self.get_or_create_session(app)

    def _app_hint_matches_bundle(self, app_hint: str, bundle_id: str) -> bool:
        hint = app_hint.strip().casefold()
        if not hint:
            return False
        normalized_bundle = bundle_id.casefold()
        if hint == normalized_bundle:
            return True
        return hint == normalized_bundle.rsplit(".", 1)[-1]

    def _find_cached_session_for_app(self, app_hint: str) -> AppSession | None:
        for bundle_id, window_id in list(self._bundle_to_window.items()):
            if not self._app_hint_matches_bundle(app_hint, bundle_id):
                continue
            session = self._sessions.get(window_id)
            if session is not None:
                return session
            del self._bundle_to_window[bundle_id]

        for session in self._sessions.values():
            if self._app_hint_matches_bundle(app_hint, session.target.bundle_id):
                return session

        return None

    def _fallback_window_id_for_pid(self, pid: int) -> int | None:
        candidates = screenshot.list_windows(owner_pid=pid)
        if not candidates:
            return None
        best = max(
            candidates,
            key=lambda w: (
                bool(w.title and w.title.strip()),
                w.onscreen,
                w.width * w.height,
            ),
        )
        return best.window_id

    def get_or_create_session(self, app: str) -> AppSession:
        cached = self._find_cached_session_for_app(app)
        if cached is not None:
            # Fast path: just check that the window's PID is still alive.
            # Skip the expensive AX window re-matching unless the PID is gone.
            window_pid = screenshot.get_window_pid(cached.target.window_id)
            if window_pid is not None:
                cached.target.window_pid = window_pid
                self._track_session(cached)
                return cached
            # Window gone — try full refresh before dropping
            self._refresh_window(cached)
            if cached.target.ax_window is not None:
                self._track_session(cached)
                return cached
            self._drop_session(cached.target.window_id)

        info = apps.resolve_app(app)
        bundle_id = info.bundle_id

        previous_window_id = self._bundle_to_window.get(bundle_id)
        if previous_window_id is not None:
            existing = self._sessions.get(previous_window_id)
            if existing is None:
                del self._bundle_to_window[bundle_id]
            elif info.pid is not None and existing.target.pid != info.pid:
                apps.invalidate_caches_for_pid(existing.target.pid)
                self._drop_session(previous_window_id)
            elif info.pid is not None:
                try:
                    existing.target.ax_app, existing.target.pid = apps.get_ax_app_for_bundle(
                        bundle_id,
                        known_pid=info.pid,
                    )
                except AutomationError:
                    self._drop_session(previous_window_id)
                else:
                    self._refresh_window(existing)
                    if existing.target.ax_window is not None:
                        self._track_session(existing, previous_window_id)
                        return existing
                    self._drop_session(previous_window_id)
            else:
                self._drop_session(previous_window_id)

        # Save frontmost app so we can restore focus if the target
        # self-activates despite activates=False.
        previous_frontmost = apps.get_frontmost_app()

        # Launch if not running
        if info.pid is None:
            pid = apps.launch_app(bundle_id)
        else:
            pid = info.pid

        # Pass known PID so get_ax_app_for_bundle skips re-resolving
        ax_app, pid = apps.get_ax_app_for_bundle(bundle_id, known_pid=pid)
        ax_window = accessibility.get_key_window(ax_app)
        if ax_window is None:
            # App running but no key window — send reopen event
            logger.info(
                "App %s has no key window — sending reopen event (background)",
                bundle_id,
            )
            apps.reopen_app_background(bundle_id)
            # Brief pause to let the reopen event deliver a window
            time.sleep(WINDOW_RETRY_DELAY_S)
            ax_window = accessibility.get_key_window(ax_app)

        # Restore focus if the target app stole it during launch/reopen
        apps.restore_frontmost(previous_frontmost)

        window_id = screenshot.find_window_id_for_ax_window(pid, ax_window)
        if window_id is None:
            # Retry once — window list can lag behind AX on slow machines
            time.sleep(WINDOW_RETRY_DELAY_S)
            window_id = screenshot.find_window_id_for_ax_window(pid, ax_window)
        if window_id is None:
            window_id = self._fallback_window_id_for_pid(pid)
        if window_id is None:
            from app._lib.errors import ScreenshotError
            raise ScreenshotError(f"Cannot resolve window ID for {bundle_id}")

        window_pid = screenshot.get_window_pid(window_id) or pid

        existing = self._sessions.get(window_id)
        if existing is not None and existing.target.bundle_id == bundle_id and existing.target.pid == pid:
            existing.target.ax_app = ax_app
            existing.target.ax_window = ax_window
            existing.target.window_pid = window_pid
            self._track_session(existing, previous_window_id)
            return existing

        target = AppTarget(
            bundle_id=bundle_id,
            pid=pid,
            window_id=window_id,
            window_pid=window_pid,
            ax_app=ax_app,
            ax_window=ax_window,
        )
        session = AppSession(target=target)
        self._track_session(session, previous_window_id)
        return session

    def get_or_create_session_for_window(self, window_id: int) -> AppSession:
        window_pid = screenshot.get_window_pid(window_id)
        if window_pid is None:
            self._drop_session(window_id)
            raise AutomationError(
                f"Window {window_id} is not available. Call list_apps or get_app_state to refresh."
            )

        existing = self._sessions.get(window_id)
        if existing is not None:
            existing.target.window_pid = window_pid
            return existing

        info = apps.resolve_running_app_by_pid(window_pid)
        bundle_id = info.bundle_id if info is not None else f"pid.{window_pid}"
        ax_app, pid = apps.get_ax_app_for_pid(window_pid, bundle_id=info.bundle_id if info else None)
        ax_window = self._find_ax_window_for_window_id(ax_app, pid, window_id)
        if ax_window is None:
            fallback = self._find_window_across_running_apps(window_id, skip_pids={pid})
            if fallback is None:
                raise ScreenshotError(
                    f"Cannot resolve accessibility window for window_id={window_id} (pid {window_pid})"
                )
            bundle_id, pid, ax_app, ax_window = fallback

        target = AppTarget(
            bundle_id=bundle_id,
            pid=pid,
            window_id=window_id,
            window_pid=window_pid,
            ax_app=ax_app,
            ax_window=ax_window,
        )
        session = AppSession(target=target)
        self._track_session(session)
        return session


    def _find_ax_window_for_window_id(self, ax_app: Any, pid: int, window_id: int) -> Any | None:
        for ax_window in accessibility.get_windows(ax_app):
            matched_window_id = screenshot.find_window_id_for_ax_window(pid, ax_window)
            if matched_window_id == window_id:
                return ax_window
        return None

    def _find_window_across_running_apps(
        self,
        window_id: int,
        *,
        skip_pids: set[int] | None = None,
    ) -> tuple[str, int, Any, Any] | None:
        skipped = skip_pids or set()
        for app in apps.list_running_apps():
            if app.pid is None or app.pid in skipped:
                continue
            try:
                ax_app, pid = apps.get_ax_app_for_pid(app.pid, bundle_id=app.bundle_id)
            except AutomationError:
                continue
            ax_window = self._find_ax_window_for_window_id(ax_app, pid, window_id)
            if ax_window is not None:
                return (app.bundle_id, pid, ax_app, ax_window)
        return None

    def _refresh_window(self, session: AppSession) -> None:
        window_id = session.target.window_id
        window_pid = screenshot.get_window_pid(window_id)
        if window_pid is None:
            self._drop_session(window_id)
            session.target.ax_window = None
            return

        session.target.window_pid = window_pid

        ax_window = self._find_ax_window_for_window_id(
            session.target.ax_app,
            session.target.pid,
            window_id,
        )
        if ax_window is not None:
            session.target.ax_window = ax_window
            return

        if window_pid != session.target.pid:
            info = apps.resolve_running_app_by_pid(window_pid)
            bundle_id = info.bundle_id if info is not None else None
            try:
                ax_app, pid = apps.get_ax_app_for_pid(window_pid, bundle_id=bundle_id)
            except AutomationError:
                session.target.ax_window = None
                return

            ax_window = self._find_ax_window_for_window_id(ax_app, pid, window_id)
            if ax_window is not None:
                session.target.ax_app = ax_app
                session.target.ax_window = ax_window
                session.target.pid = pid
                if bundle_id:
                    session.target.bundle_id = bundle_id
                self._track_session(session)
                return

        fallback = self._find_window_across_running_apps(
            window_id,
            skip_pids={session.target.pid, window_pid},
        )
        if fallback is not None:
            bundle_id, pid, ax_app, ax_window = fallback
            session.target.bundle_id = bundle_id
            session.target.pid = pid
            session.target.ax_app = ax_app
            session.target.ax_window = ax_window
            self._track_session(session)
            return

        session.target.ax_window = None

    def _background_click_node(
        self,
        session: AppSession,
        node: Node,
        *,
        button: str = "left",
        count: int = 1,
    ) -> bool:
        sx, sy = accessibility.get_element_position(node)
        if sx is None or sy is None:
            return False
        try:
            cg_input.click_at_screen_point(
                session.target.window_pid,
                sx,
                sy,
                button=button,
                count=count,
            )
            return True
        except InputError as exc:
            logger.debug("Background click fallback failed: %s", exc)
            return False

    def _has_web_ancestor(self, nodes: list[Node], idx: int) -> bool:
        node = nodes[idx]
        ancestor_depth = node.depth

        for prev_idx in range(idx - 1, -1, -1):
            prev = nodes[prev_idx]
            if prev.depth >= ancestor_depth:
                continue
            if prev.role in _WEB_CONTAINER_ROLES:
                return True
            ancestor_depth = prev.depth
        return False

    def _should_prefer_pointer_input(self, session: AppSession, node: Node) -> bool:
        if node.role not in _POINTER_PREFERRED_ROLES:
            return False
        if node.index >= len(session.tree_nodes):
            return False
        return self._has_web_ancestor(session.tree_nodes, node.index)

    def _focus_node_for_keyboard_input(self, session: AppSession, node: Node) -> bool:
        """Focus an element for keyboard input WITHOUT activating the app.

        Uses CGEventPostToPid click (background) as the primary method.
        AXPress is avoided because it causes many apps to self-activate,
        stealing focus from the user's current app.
        """
        # Primary: background click at element center (no activation)
        if self._background_click_node(session, node):
            time.sleep(0.05)
            return True
        # Fallback: AX focus attribute (doesn't activate most apps)
        try:
            accessibility.set_attribute(node, "AXFocused", True)
            time.sleep(0.02)
            return True
        except Exception:
            pass
        return False

    def _build_app_state(self, target: AppTarget, window_title: str | None) -> AppState:
        """Build geometry metadata for the app state response."""
        visible_rect = None
        bounds = screenshot.get_window_bounds(target.window_id)
        if bounds is not None:
            wx, wy, ww, wh = bounds
            visible_rect = Rect(x=wx, y=wy, w=ww, h=wh)

        # Retina scaling factor — use the screen containing the target window
        scaling_factor = 2.0
        target_screen = None
        try:
            from AppKit import NSScreen
            if visible_rect is not None:
                # Find the screen containing the target window
                for screen in NSScreen.screens():
                    sf = screen.frame()
                    ix = max(float(sf.origin.x), visible_rect.x)
                    iy = max(float(sf.origin.y), visible_rect.y)
                    iw = min(float(sf.origin.x) + float(sf.size.width), visible_rect.x + visible_rect.w) - ix
                    ih = min(float(sf.origin.y) + float(sf.size.height), visible_rect.y + visible_rect.h) - iy
                    if iw > 0 and ih > 0:
                        target_screen = screen
                        break
            if target_screen is None:
                target_screen = NSScreen.mainScreen()
            if target_screen is not None:
                scaling_factor = float(target_screen.backingScaleFactor())
        except Exception:
            pass

        # Scaled screen size (logical points) — from the window's screen
        scaled_screen_size = None
        try:
            screen = target_screen
            if screen is None:
                from AppKit import NSScreen
                screen = NSScreen.mainScreen()
            if screen is not None:
                frame = screen.frame()
                scaled_screen_size = Size(w=frame.size.width, h=frame.size.height)
        except Exception:
            pass

        # Cursor position in scaled coordinates
        cursor_position = None
        try:
            from Quartz import CGEventCreate
            event = CGEventCreate(None)
            if event is not None:
                from Quartz import CGEventGetLocation
                loc = CGEventGetLocation(event)
                cursor_position = Point(x=loc.x, y=loc.y)
        except Exception:
            pass

        return AppState(
            bundle_id=target.bundle_id,
            is_active=True,
            is_running=True,
            window_title=window_title,
            visible_rect=visible_rect,
            scaling_factor=scaling_factor,
            scaled_screen_size=scaled_screen_size,
            cursor_position=cursor_position,
        )

    def take_snapshot(self, session: AppSession, *, skip_refresh: bool = False) -> ToolResponse:
        # Step 1: Refresh references for the targeted window
        # (skipped when the caller just validated the session, e.g. get_app_state)
        if not skip_refresh:
            self._refresh_window(session)
        t = session.target

        # Retry once if the AX reference for the targeted window is temporarily unavailable
        if t.ax_window is None:
            time.sleep(WINDOW_RETRY_DELAY_S)
            self._refresh_window(session)
            if t.ax_window is None:
                raise AutomationError(
                    f"Target window {t.window_id} in {t.bundle_id} is no longer available."
                )

        # Step 1b: Update/create ApplicationWindow bridge
        self._update_application_window(session)

        # Step 2: Walk AX tree (use cache if tree not invalidated)
        if (
            session.refetchable_tree is not None
            and not session.refetchable_tree.is_invalidated
        ):
            nodes = session.refetchable_tree.nodes
            logger.debug("Using cached AX tree (%d nodes, not invalidated)", len(nodes))
        else:
            with controller_tracer.interval("Walk AX Tree"):
                nodes = accessibility.walk_tree(t.ax_window, target_pid=t.pid)
        # Step 3: Capture screenshot — SCK primary, CGWindowListCreateImage fallback
        img = self._capture_screenshot(session, t)
        if img is None:
            # Retry: refresh window references and try again
            time.sleep(SCREENSHOT_RETRY_DELAY_S)
            self._refresh_window(session)
            t = session.target
            if t.ax_window is None:
                raise ScreenshotError(
                    f"Target window {t.window_id} in {t.bundle_id} disappeared while capturing a snapshot."
                )
            with controller_tracer.interval("Walk AX Tree (retry)"):
                nodes = accessibility.walk_tree(t.ax_window, target_pid=t.pid)
            img = self._capture_screenshot(session, t)
            if img is None:
                logger.warning(
                    "Screenshot unavailable for window %d in %s (screen recording permission may be missing)",
                    t.window_id, t.bundle_id,
                )
        # Step 4: Query focused element
        focused = accessibility.get_focused_element(t.ax_app, nodes)
        # Step 5: Build geometry metadata
        window_title = self._get_window_title(t.ax_window)
        app_state = self._build_app_state(t, window_title)
        # Step 5b: Extract web content from web areas and text areas
        if feature_flags.web_content_extraction:
            self._enrich_nodes_with_web_content(nodes, t.pid)
        # Step 5c: Extract system selection
        selection_text = None
        if feature_flags.system_selection and focused is not None:
            selection_text = self._extract_system_selection(nodes, focused, t.pid)
        # Step 6: Serialize tree to text (gate pruning behind feature flag)
        # CRITICAL: serialize() with pruning re-indexes Node objects in-place
        # via node.index = new_idx. We must use the PRUNED list for
        # session.tree_nodes so that the indexes the model sees in the tree
        # text match what _resolve_index looks up by list position.
        if feature_flags.tree_pruning and nodes:
            from app._lib.pruning import prune as prune_nodes
            pruned_nodes, _, _ = prune_nodes(
                nodes,
                advanced=feature_flags.advanced_pruning,
                bundle_id=t.bundle_id,
            )
            # Serialize the already-pruned nodes (no double-prune)
            tree_text = serialize(pruned_nodes, focused, enable_pruning=False)
            nodes = pruned_nodes
        else:
            tree_text = serialize(nodes, focused, enable_pruning=False)
        # Step 6b: Enforce byte budget — drop oldest lines if tree_text is too large
        tree_bytes = len(tree_text.encode("utf-8"))
        if tree_bytes > TREE_BYTE_BUDGET:
            lines = tree_text.split("\n")
            # Binary search: find how many lines to keep from the end to fit budget
            # Keep at least 1 line (the focused element summary if present)
            lo, hi = 1, len(lines)
            while lo < hi:
                mid = (lo + hi + 1) // 2
                candidate = "\n".join(lines[-mid:])
                if len(candidate.encode("utf-8")) <= TREE_BYTE_BUDGET - 80:  # room for truncation notice
                    lo = mid
                else:
                    hi = mid - 1
            dropped = len(lines) - lo
            if dropped > 0:
                tree_text = f"({dropped} lines truncated — tree exceeded {TREE_BYTE_BUDGET // 1000}KB budget)\n" + "\n".join(lines[-lo:])
                logger.info(
                    "Tree byte budget enforced for %s: %d bytes → %d bytes (%d lines dropped)",
                    t.bundle_id, tree_bytes, len(tree_text.encode("utf-8")), dropped,
                )
        # Step 7: Build header
        session.screenshot_size = img.size if img else None
        screenshot_size = session.screenshot_size
        header = make_header(
            t.bundle_id,
            t.pid,
            window_title,
            t.window_id,
            t.window_pid,
            screenshot_size,
            app_state=app_state,
        )
        # Step 8: Increment snapshot_id
        session.snapshot_id += 1
        # Step 9: Store tree_nodes on session for index resolution
        # nodes is now the pruned list — indexes match what the model sees
        session.tree_nodes = nodes
        # Step 9b: Update/create RefetchableTree
        if session.refetchable_tree is not None:
            session.refetchable_tree.update(
                nodes, ax_window=t.ax_window, target_pid=t.pid,
            )
        else:
            session.refetchable_tree = RefetchableTree(
                nodes,
                session.invalidation_monitor,
                ax_window=t.ax_window,
                target_pid=t.pid,
                walk_fn=accessibility.walk_tree,
            )
        # Step 10: Return ToolResponse

        return ToolResponse(
            app=t.bundle_id,
            pid=t.pid,
            snapshot_id=session.snapshot_id,
            window_title=window_title,
            tree_text=f"{header}\n\n{tree_text}",
            tree_nodes=nodes,
            focused_element=focused,
            screenshot=screenshot.image_to_base64(img) if img else None,
            app_state=app_state,
            system_selection=selection_text,
        )

    # ------------------------------------------------------------------
    # Web content enrichment + selection extraction
    # ------------------------------------------------------------------

    def _enrich_nodes_with_web_content(self, nodes: list[Node], target_pid: int) -> None:
        """Extract web/rich text content from web areas and text areas.

        Populates Node.web_content and Node.web_area_url for nodes that
        are AXWebArea or text area roles.
        """
        for node in nodes:
            if node.ax_ref is None:
                continue
            if node.is_web_area:
                # Web area: extract content + URL
                content = extract_web_area_text(
                    node.ax_ref, target_pid=target_pid,
                )
                if content:
                    node.web_content = content
                url = get_web_url(node.ax_ref)
                if url:
                    node.web_area_url = url
            elif node.ax_role in ("AXTextArea",) and feature_flags.rich_text_markdown:
                # Text area: extract rich text content
                content = extract_text_area_content(
                    node.ax_ref, target_pid=target_pid,
                )
                if content and content != node.value:
                    node.web_content = content

    def _extract_system_selection(
        self,
        nodes: list[Node],
        focused_index: int,
        target_pid: int,
    ) -> str | None:
        """Extract system selection from the focused element.

        Uses SelectionExtractor to try 4 methods in priority order.
        Returns formatted selection text or None.
        """
        if focused_index < 0 or focused_index >= len(nodes):
            return None
        focused_node = nodes[focused_index]
        if focused_node.ax_ref is None:
            return None

        extractor = SelectionExtractor()
        raw_text = extractor.extract(focused_node.ax_ref)
        return format_selection(raw_text)

    # ------------------------------------------------------------------
    # Screenshot pipeline + ApplicationWindow
    # ------------------------------------------------------------------

    def _capture_screenshot(self, session: AppSession, target: AppTarget) -> Image.Image | None:
        """Capture screenshot using SCK primary, CGWindowListCreateImage fallback.

        Uses SCREENSHOT_RETRY_POLICY for retries with exponential backoff.
        Applies ScreenshotClassifier when enabled to check for meaningful content.
        """
        def _try_capture() -> Image.Image | None:
            img = None
            # Primary: ScreenCaptureKit (GPU-accelerated)
            if feature_flags.screen_capture_kit and is_sck_available():
                with controller_tracer.interval("SCK Window Capture"):
                    worker = get_screen_capture_worker()
                    img = worker.capture(target.window_id, target.pid)

            # Fallback: CGWindowListCreateImage
            if img is None:
                with controller_tracer.interval("Capture Screenshot"):
                    img = screenshot.capture_window(target.window_id)

            return img

        # Use retry policy for screenshot capture
        img = None
        try:
            img = with_retry(
                SCREENSHOT_RETRY_POLICY,
                lambda: _try_capture() or (_ for _ in ()).throw(ScreenshotError("capture returned None")),
                retryable=ScreenshotError,
                context="screenshot_capture",
            )
        except ScreenshotError:
            # All retries exhausted — return None (caller handles)
            return None

        # ScreenshotClassifier: check if screenshot has meaningful content
        if feature_flags.screenshot_classifier:
            classifier = get_screenshot_classifier()
            if not classifier.is_meaningful(img):
                logger.debug("ScreenshotClassifier: screenshot not meaningful, returning anyway")

        return img

    def _update_application_window(self, session: AppSession) -> None:
        """Create or refresh the ApplicationWindow bridge for this session.

        Skips the expensive is_valid() + refresh_cg_info() calls when we already
        have a valid association — the window ID hasn't changed since session
        resolution validated it.
        """
        if session.application_window is not None:
            # Already have an association — trust it (session resolve validated the window)
            return

        # Create new association
        t = session.target
        app_window = ApplicationWindow.create(
            pid=t.pid,
            ax_window=t.ax_window,
            ax_application=t.ax_app,
        )
        if app_window is not None:
            session.application_window = app_window

    def _get_window_title(self, ax_window: Any) -> str | None:
        from ApplicationServices import AXUIElementCopyAttributeValue, kAXTitleAttribute, kAXErrorSuccess
        err, title = AXUIElementCopyAttributeValue(ax_window, kAXTitleAttribute, None)
        if err == kAXErrorSuccess and title:
            return str(title)
        return None

    def _dispatch(self, tool: str, session: AppSession, params: dict) -> str:
        t = session.target

        if tool == "get_app_state":
            return "App state retrieved."
        elif tool == "click":
            return self._handle_click(session, params)
        elif tool == "type_text":
            return self._handle_type_text(session, params)
        elif tool == "set_value":
            return self._handle_set_value(session, params)
        elif tool == "press_key":
            return self._handle_press_key(session, params)
        elif tool == "scroll":
            return self._handle_scroll(session, params)
        elif tool == "drag":
            return self._handle_drag(session, params)
        elif tool == "perform_secondary_action":
            return self._handle_secondary_action(session, params)
        else:
            raise AutomationError(f"Unknown tool: {tool}")

    # ------------------------------------------------------------------
    # Tool handlers — hybrid AX + CGEventPostToPid.
    # All event injection remains background-targeted: no activation and no
    # takeover of the user's live mouse or keyboard stream.
    # ------------------------------------------------------------------

    def _handle_click(self, session: AppSession, params: dict) -> str:
        """Click via background CGEvent, with AX fallbacks.

        By element: CGEventPostToPid → AXPress → AXSelected → AXShowMenu
        → repeated AXPress.
        By coords:  CGEventPostToPid → AX hit-test fallback.
        """
        t = session.target
        element_index = params.get("element_index")
        x = params.get("x")
        y = params.get("y")
        count = int(params.get("click_count", 1))
        button = params.get("mouse_button", "left")

        if element_index is not None:
            idx = int(element_index)
            node = self._resolve_index(session, idx)
            # --- Primary: Background click (CGEventPostToPid, no focus stealing) ---
            if self._background_click_node(session, node, button=button, count=count):
                return f"Clicked element {idx} (CGEventPostToPid)"

            # --- Fallback: AX actions (element has no position or CGEvent failed) ---
            # AXPress (may cause some apps to self-activate)
            if count == 1 and button == "left":
                try:
                    accessibility.perform_action(node, "AXPress")
                    return f"Clicked element {idx} (AXPress)"
                except Exception:
                    logger.debug("AXPress failed for element %d", idx)
                    if session.input_strategy is not None:
                        session.input_strategy.record_ax_failure()

            # AXSelected for selectable rows/cells
            if count == 1 and button == "left" and "selectable" in node.states:
                try:
                    accessibility.set_attribute(node, "AXSelected", True)
                    return f"Clicked element {idx} (AXSelected)"
                except Exception:
                    logger.debug("AXSelected failed for element %d", idx)

            # AXShowMenu for right-click
            if button == "right":
                try:
                    accessibility.perform_action(node, "AXShowMenu")
                    return f"Right-clicked element {idx} (AXShowMenu)"
                except Exception:
                    logger.debug("AXShowMenu failed for element %d", idx)

            # Repeated AXPress for multi-click
            if count > 1:
                try:
                    for _ in range(count):
                        accessibility.perform_action(node, "AXPress")
                    return f"Clicked element {idx} {count}x (AXPress)"
                except Exception:
                    logger.debug("Repeated AXPress failed for element %d", idx)

            raise AutomationError(
                f"Click failed for element {idx}. "
                f"Try a different element or use perform_secondary_action."
            )

        elif x is not None and y is not None:
            try:
                cg_input.click_at(
                    t.window_pid,
                    t.window_id,
                    float(x),
                    float(y),
                    button=button,
                    count=count,
                    screenshot_size=session.screenshot_size,
                )
                return f"Clicked at ({x}, {y}) (CGEventPostToPid)"
            except InputError as exc:
                logger.debug(
                    "Screenshot-space click failed for %s at (%s, %s): %s",
                    t.bundle_id,
                    x,
                    y,
                    exc,
                )
                self._refresh_window(session)
                t = session.target
                try:
                    cg_input.click_at(
                        t.window_pid,
                        t.window_id,
                        float(x),
                        float(y),
                        button=button,
                        count=count,
                        screenshot_size=session.screenshot_size,
                    )
                    return f"Clicked at ({x}, {y}) (CGEventPostToPid, refreshed window)"
                except InputError as retry_exc:
                    logger.debug(
                        "Retry screenshot-space click failed for %s at (%s, %s): %s",
                        t.bundle_id,
                        x,
                        y,
                        retry_exc,
                    )

            sx, sy = self._to_screen_coords(session, t.window_id, float(x), float(y))
            hit_ref = accessibility.element_at_position(t.ax_app, sx, sy)
            if hit_ref is not None:
                try:
                    if button == "right":
                        accessibility.perform_action_on_ref(hit_ref, "AXShowMenu")
                        return f"Right-clicked at ({x}, {y}) (AX hit-test)"
                    accessibility.perform_action_on_ref(hit_ref, "AXPress")
                    return f"Clicked at ({x}, {y}) (AX hit-test)"
                except Exception:
                    logger.debug("AX hit-test action failed at (%s, %s)", x, y)

            raise AutomationError(
                f"Click failed at ({x}, {y}). "
                f"Use get_app_state and retry with a fresh screenshot or click by element_index."
            )
        else:
            raise AutomationError(
                "click requires either element_index or both x and y coordinates"
            )

    def _handle_type_text(self, session: AppSession, params: dict) -> str:
        """Type text using background key events, optionally targeting an element.

        For text elements that support it, tries EditableTextObject.insert_text
        as a more reliable alternative to CGEvent key-by-key typing.
        """
        text = params.get("text", "")
        el_idx = params.get("element_index")
        t = session.target

        if el_idx is not None:
            node = self._resolve_index(session, int(el_idx))

            # Try EditableTextObject.insert_text for text elements
            if node.ax_role in ("AXTextField", "AXTextArea"):
                try:
                    eto = EditableTextObject(node.ax_ref, pid=node.element_pid)
                    eto.insert_text(text)
                    return f"Typed {text!r} into element {el_idx} (EditableTextObject.insertText)"
                except Exception as e:
                    logger.debug("EditableTextObject.insertText failed for element %d: %s", el_idx, e)

            if not self._focus_node_for_keyboard_input(session, node):
                raise AutomationError(
                    f"Cannot target element {el_idx} for typing without activating the app. "
                    f"Try set_value instead."
                )

        cg_input.type_text(t.window_pid, text)
        if el_idx is None:
            return f"Typed {text!r} into the current focused element"
        return f"Typed {text!r} into element {el_idx} (background key events)"

    def _handle_set_value(self, session: AppSession, params: dict) -> str:
        """Set value — pure AX.
        EditableTextObject.set_text → AXValue set → AXPress + retry AXValue → error.
        """
        idx = int(params["element_index"])
        node = self._resolve_index(session, idx)
        value = params["value"]
        insert_mode = params.get("insert", False)

        # --- EditableTextObject for text elements ---
        if node.ax_role in ("AXTextField", "AXTextArea"):
            try:
                eto = EditableTextObject(node.ax_ref, pid=node.element_pid)
                if insert_mode:
                    eto.insert_text(value)
                    return f"Inserted text into element {idx} (EditableTextObject.insertText)"
                else:
                    eto.set_text(value)
                    return f"Set value of element {idx} to {value!r} (EditableTextObject.setText)"
            except Exception as e:
                logger.debug("EditableTextObject failed for element %d: %s", idx, e)

        # --- Primary: Direct AX attribute set ---
        try:
            accessibility.set_attribute(node, "AXValue", value)
            return f"Set value of element {idx} to {value!r} (AXValue)"
        except Exception as e:
            logger.debug("AXValue set failed for element %d: %s", idx, e)

        # --- Background focus + retry (avoid AXPress which can activate app) ---
        try:
            if self._background_click_node(session, node):
                time.sleep(0.05)
                accessibility.set_attribute(node, "AXValue", value)
                return f"Set value of element {idx} to {value!r} (focus + AXValue)"
        except Exception as e:
            logger.debug("Focus + AXValue retry failed for element %d: %s", idx, e)

        raise AutomationError(
            f"Cannot set value of element {idx}. "
            f"Element may not support direct value setting. "
            f"Try type_text with element_index instead."
        )

    def _handle_press_key(self, session: AppSession, params: dict) -> str:
        """Press a key via background key events, optionally targeting an element."""
        t = session.target
        key = params["key"]
        el_idx = params.get("element_index")

        if el_idx is not None:
            node = self._resolve_index(session, int(el_idx))

            ax_key_action = _KEY_TO_AX_ACTION.get(key.lower())
            if ax_key_action:
                try:
                    accessibility.perform_action(node, ax_key_action)
                    return f"Pressed {key} on element {el_idx} ({ax_key_action})"
                except Exception:
                    logger.debug("%s failed for element %s", ax_key_action, el_idx)

            if not self._focus_node_for_keyboard_input(session, node):
                raise AutomationError(
                    f"Cannot target element {el_idx} for key input without activating the app."
                )

        cg_input.press_key(t.window_pid, key)
        if el_idx is None:
            return f"Pressed {key} in {t.bundle_id} (background key event)"
        return f"Pressed {key} on element {el_idx} (background key event)"

    def _handle_drag(self, session: AppSession, params: dict) -> str:
        """Drag via background-targeted mouse events."""
        t = session.target
        from_x = float(params["from_x"])
        from_y = float(params["from_y"])
        to_x = float(params["to_x"])
        to_y = float(params["to_y"])

        try:
            cg_input.drag(
                t.window_pid,
                t.window_id,
                from_x,
                from_y,
                to_x,
                to_y,
                screenshot_size=session.screenshot_size,
            )
        except InputError as exc:
            logger.debug("Drag failed for %s window %s: %s", t.bundle_id, t.window_id, exc)
            self._refresh_window(session)
            t = session.target
            cg_input.drag(
                t.window_pid,
                t.window_id,
                from_x,
                from_y,
                to_x,
                to_y,
                screenshot_size=session.screenshot_size,
            )

        return f"Dragged from ({from_x}, {from_y}) to ({to_x}, {to_y})"

    def _handle_secondary_action(self, session: AppSession, params: dict) -> str:
        """Perform secondary action — pure AX."""
        idx = int(params["element_index"])
        node = self._resolve_index(session, idx)
        action = params["action"]

        # --- Primary: Direct AX action ---
        try:
            accessibility.perform_action(node, action)
            return f"Performed {action!r} on element {idx}"
        except Exception as e:
            logger.debug("Action %s failed for element %d: %s", action, idx, e)

        # --- AXPress as generic fallback ---
        if action not in ("AXPress", "AXCancel"):
            try:
                accessibility.perform_action(node, "AXPress")
                return f"Performed AXPress on element {idx} (fallback for {action!r})"
            except Exception:
                logger.debug("AXPress fallback failed for element %d", idx)

        raise AutomationError(
            f"Action {action!r} failed on element {idx}. "
            f"Try a different action from the element's secondary_actions list."
        )

    def _handle_scroll(self, session: AppSession, params: dict) -> str:
        """Scroll with verified fallback chain.

        Tries truly-background methods first (AX actions, CGEventPostToPid),
        verifies they worked by checking element positions before/after,
        falls back to CGEventPost+CGWarp if background methods fail.
        Caches the working method per session to skip failed tiers.
        """
        direction = params["direction"]
        pages = int(params.get("pages", 1))
        if pages < 1:
            raise AutomationError("pages must be >= 1")

        element_index = params.get("element_index")
        x = params.get("x")
        y = params.get("y")

        node: Node | None = None
        idx: int | None = None
        scroll_point: tuple[float, float] | None = None

        if element_index is not None:
            idx = int(element_index)
            node = self._resolve_index(session, idx)
            center = accessibility.get_element_position(node)
            if center is not None and center[0] is not None:
                scroll_point = (center[0], center[1])
        elif x is not None and y is not None:
            sx, sy = cg_input.window_to_screen_coords(
                session.target.window_id, float(x), float(y),
                session.screenshot_size,
            )
            scroll_point = (sx, sy)

        if node is None and scroll_point is None:
            raise AutomationError(
                "scroll requires either element_index or x/y coordinates"
            )

        for _ in range(pages):
            performed = False
            cached = session.scroll_method

            # If we already know what works, use it directly
            if cached == "ax" and node is not None:
                performed = self._try_ax_scroll(session, node, direction)
            elif cached == "pid" and scroll_point is not None:
                performed = self._try_pid_scroll(session, scroll_point, direction)
            elif cached == "system" and scroll_point is not None:
                performed = self._try_system_scroll(scroll_point, direction)

            if performed:
                continue

            # No cache hit — discover which method works with verification

            # Tier 1: AX scroll (truly background, no cursor movement)
            if node is not None:
                before = self._get_scroll_witness(session, node)
                if self._try_ax_scroll(session, node, direction):
                    time.sleep(0.05)
                    if self._scroll_changed(session, node, before):
                        session.scroll_method = "ax"
                        logger.debug("Scroll method: ax (verified)")
                        continue

            # Tier 2: CGEventPostToPid (truly background)
            if scroll_point is not None:
                before = self._get_scroll_witness(session, node) if node else None
                if self._try_pid_scroll(session, scroll_point, direction):
                    time.sleep(0.05)
                    if before is not None and self._scroll_changed(session, node, before):
                        session.scroll_method = "pid"
                        logger.debug("Scroll method: pid (verified)")
                        continue

            # Tier 3: CGEventPost + CGWarp (brief cursor teleport, always works)
            if scroll_point is not None:
                if self._try_system_scroll(scroll_point, direction):
                    session.scroll_method = "system"
                    logger.debug("Scroll method: system")
                    continue

            # Tier 4: Scrollbar value manipulation
            if node is not None:
                if self._try_scrollbar_fallback(node, direction):
                    continue

            raise AutomationError("No scroll action was performed")

        target_desc = f"element {idx}" if idx is not None else f"({x}, {y})"
        return f"Scrolled {target_desc} {direction} ({pages} page(s))"

    def _to_screen_coords(
        self,
        session: AppSession,
        window_id: int,
        x: float,
        y: float,
    ) -> tuple[float, float]:
        """Convert screenshot coords to screen coords (no CGEvent, just lookup)."""
        return cg_input.window_to_screen_coords(
            window_id,
            x,
            y,
            session.screenshot_size,
        )

    def _try_scrollbar_fallback(self, node: Node, direction: str) -> bool:
        """Step 4: Try setting scrollbar value directly."""
        is_vertical = direction in ("up", "down")
        scrollbar_attr = "AXVerticalScrollBar" if is_vertical else "AXHorizontalScrollBar"

        if node.ax_ref is None:
            return False

        try:
            from ApplicationServices import AXUIElementCopyAttributeValue, kAXErrorSuccess, kAXValueAttribute

            err, scrollbar = AXUIElementCopyAttributeValue(node.ax_ref, scrollbar_attr, None)
            if err != kAXErrorSuccess or scrollbar is None:
                return False

            err2, current_val = AXUIElementCopyAttributeValue(scrollbar, kAXValueAttribute, None)
            if err2 != kAXErrorSuccess or current_val is None:
                return False

            val = float(current_val)
            delta = 0.1 if direction in ("down", "right") else -0.1
            new_val = max(0.0, min(1.0, val + delta))

            from ApplicationServices import AXUIElementSetAttributeValue
            from Foundation import NSNumber
            err3 = AXUIElementSetAttributeValue(scrollbar, kAXValueAttribute, NSNumber.numberWithFloat_(new_val))
            return err3 == kAXErrorSuccess
        except Exception:
            return False

    def _try_ax_scroll(self, session: AppSession, node: Node, direction: str) -> bool:
        """Try AX scroll actions on the target element and its ancestors.

        Walks up the tree to find scrollable ancestors (e.g. AXScrollArea,
        AXWebArea) when the target element itself doesn't support scrolling.
        """
        direction_title = direction.capitalize()
        ax_page_actions = [
            f"AXScroll{direction_title}ByPage",
            f"AXScroll{direction_title}",
        ]

        # Collect candidate elements: target + ancestors up to scroll area
        candidates = [node]
        if session.tree_nodes and node.index is not None:
            ancestor_depth = node.depth
            for prev_idx in range(node.index - 1, -1, -1):
                prev = session.tree_nodes[prev_idx]
                if prev.depth >= ancestor_depth:
                    continue
                candidates.append(prev)
                ancestor_depth = prev.depth
                if prev.ax_role in ("AXScrollArea", "AXWebArea"):
                    break

        for candidate in candidates:
            # Try page-level actions (only if listed)
            for action in ax_page_actions:
                if action in candidate.secondary_actions:
                    try:
                        accessibility.perform_action(candidate, action)
                        return True
                    except Exception as e:
                        logger.debug("AX scroll %s on %s failed: %s", action, candidate.ax_role, e)

            # Try generic scroll-to actions
            for action in ("AXScrollToVisible", "AXScrollToShowDescendant"):
                try:
                    accessibility.perform_action(candidate, action)
                    return True
                except Exception:
                    continue

        return False

    def _get_scroll_witness(
        self, session: AppSession, node: Node | None,
    ) -> tuple[float, float] | None:
        """Get position of a child element to verify scroll happened."""
        if node is None or not session.tree_nodes or node.index is None:
            return None
        for i in range(node.index + 1, min(node.index + 20, len(session.tree_nodes))):
            child = session.tree_nodes[i]
            if child.depth <= node.depth:
                break
            pos = accessibility.get_element_position(child)
            if pos is not None and pos[0] is not None:
                return pos
        return None

    def _scroll_changed(
        self, session: AppSession, node: Node | None,
        before: tuple[float, float] | None,
    ) -> bool:
        """Check if a child element moved (i.e. scroll actually happened)."""
        if before is None:
            return False
        after = self._get_scroll_witness(session, node)
        if after is None:
            return False
        return abs(after[0] - before[0]) > 1 or abs(after[1] - before[1]) > 1

    def _try_pid_scroll(
        self, session: AppSession, point: tuple[float, float], direction: str,
    ) -> bool:
        """Scroll via CGEventPostToPid — truly background, no cursor movement."""
        try:
            cg_input.scroll_pid(
                session.target.window_pid,
                point[0],
                point[1],
                direction,
                clicks=SCROLL_CLICKS_PER_PAGE,
            )
            return True
        except Exception as e:
            logger.debug("CGEventPostToPid scroll failed: %s", e)
            return False

    def _try_system_scroll(
        self, point: tuple[float, float], direction: str,
    ) -> bool:
        """Scroll via CGEventPost + CGWarp — brief cursor teleport."""
        try:
            cg_input.scroll_system(
                point[0],
                point[1],
                direction,
                clicks=SCROLL_CLICKS_PER_PAGE,
            )
            return True
        except Exception as e:
            logger.debug("CGEvent system scroll failed: %s", e)
            return False

    def _resolve_index(self, session: AppSession, idx: int) -> Node:
        # Use RefetchableTree for element resolution with refetch support
        if session.refetchable_tree is not None:
            result = session.refetchable_tree.element(idx)
            if result.success:
                return result.node  # type: ignore[return-value]
            # Refetch failed — raise appropriate error
            if result.error_code == RefetchErrorCode.NOT_FOUND:
                raise StaleReferenceError(
                    result.error_message
                    or f"Element {idx} no longer valid after refetch. Call get_app_state to refresh."
                )
            if result.error_code in (
                RefetchErrorCode.AMBIGUOUS_BEFORE,
                RefetchErrorCode.AMBIGUOUS_AFTER,
            ):
                raise RefetchError(
                    result.error_message
                    or f"Element {idx} is ambiguous. Call get_app_state to refresh."
                )
            if result.error_code == RefetchErrorCode.NO_INVALIDATION_MONITOR:
                # Fall through to direct lookup
                pass

        # Fallback: direct index lookup (no refetchable tree or monitor missing)
        if idx < 0 or idx >= len(session.tree_nodes):
            raise BadIndexError(
                f"Index {idx} out of bounds (tree has {len(session.tree_nodes)} elements). "
                f"Call get_app_state to refresh."
            )
        return session.tree_nodes[idx]

    def _handle_list_apps(self) -> ToolResponse:
        running = apps.list_running_apps()
        recent = apps.list_recent_apps()
        windows = screenshot.list_windows()
        windows_by_pid: dict[int, list[screenshot.WindowInfo]] = {}
        for window in windows:
            windows_by_pid.setdefault(window.owner_pid, []).append(window)

        lines = []
        seen_pids: set[int] = set()
        for a in running:
            parts = [f"{a.name} \u2014 {a.bundle_id} [running"]
            if a.pid is not None:
                parts.append(f", pid={a.pid}")
            if a.last_used:
                parts.append(f", last-used={a.last_used}")
            if a.use_count:
                parts.append(f", uses={a.use_count}")
            parts.append("]")
            lines.append("".join(parts))
            if a.pid is not None:
                seen_pids.add(a.pid)
                for window in sorted(windows_by_pid.get(a.pid, []), key=lambda w: w.window_id):
                    title = repr(window.title) if window.title else '"(untitled)"'
                    lines.append(
                        f"  window_id={window.window_id}, window_pid={window.owner_pid}, "
                        f"title={title}, bounds=({int(window.x)}, {int(window.y)}, "
                        f"{int(window.width)}x{int(window.height)})"
                    )

        for pid, owned_windows in sorted(windows_by_pid.items()):
            if pid in seen_pids:
                continue
            info = apps.resolve_running_app_by_pid(pid)
            if info is not None:
                lines.append(f"{info.name} \u2014 {info.bundle_id} [running, pid={pid}]")
            else:
                owner_name = owned_windows[0].owner_name or "Unknown"
                lines.append(f"{owner_name} \u2014 pid.{pid} [running, pid={pid}]")
            for window in sorted(owned_windows, key=lambda w: w.window_id):
                title = repr(window.title) if window.title else '"(untitled)"'
                lines.append(
                    f"  window_id={window.window_id}, window_pid={window.owner_pid}, "
                    f"title={title}, bounds=({int(window.x)}, {int(window.y)}, "
                    f"{int(window.width)}x{int(window.height)})"
                )

        for a in recent:
            if any(r.bundle_id == a.bundle_id for r in running):
                continue
            parts = [f"{a.name} \u2014 {a.bundle_id} ["]
            if a.last_used:
                parts.append(f"last-used={a.last_used}")
            if a.use_count:
                parts.append(f", uses={a.use_count}")
            parts.append("]")
            lines.append("".join(parts))

        return ToolResponse(
            app="system",
            pid=0,
            snapshot_id=0,
            result="\n".join(lines),
        )

    def _load_guidance(self, bundle_id: str) -> str | None:
        if bundle_id in self._guidance_cache:
            return self._guidance_cache[bundle_id]
        path = GUIDANCE_DIR / f"{bundle_id}.md"
        guidance = None
        if path.exists():
            guidance = path.read_text()
        self._guidance_cache[bundle_id] = guidance
        return guidance

    def _error_only(self, message: str) -> ToolResponse:
        return ToolResponse(
            app="unknown",
            pid=0,
            snapshot_id=0,
            error=message,
        )

    def _try_snapshot_or_error(self, session: AppSession, error: Exception) -> ToolResponse:
        try:
            response = self.take_snapshot(session)
            response.error = str(error)
            return response
        except Exception:
            return self._error_only(str(error))
