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
    UserInterruptionError,
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
from app._lib.graphs import (
    GraphKind,
    GraphRecord,
    GraphRegistry,
    GraphState,
    SessionGraphs,
    TransientGraphTracker,
    TransientSurface,
    TransientSource,
    annotate_graph_nodes,
    match_node_by_locator,
)
from app._lib.action_verification import (
    ActionOutcomeMonitor,
    ActionVerificationResult,
    CGEventOutcomeMonitor,
    VerificationContract,
    expectation_for_click,
    expectation_for_drag,
    expectation_for_keypress,
    expectation_for_scroll,
    expectation_for_typing,
)
from app._lib.screen_capture import (
    get_screen_capture_worker,
    get_screenshot_classifier,
    is_sck_available,
)
from app._lib.retry import RetryPolicy, with_retry, SCREENSHOT_RETRY_POLICY
from app._lib.screenshot import ApplicationWindow
from app._lib.observer import (
    AXNotificationObserver,
    AX_NOTIFICATION_CREATED,
    AX_NOTIFICATION_ELEMENT_DESTROYED,
    AX_NOTIFICATION_FOCUSED_ELEMENT_CHANGED,
    AX_NOTIFICATION_MENU_OPENED,
    AX_NOTIFICATION_MENU_CLOSED,
    AX_NOTIFICATION_VALUE_CHANGED,
    AX_NOTIFICATION_WINDOW_CREATED,
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
SCROLL_PIXELS_PER_PAGE_RATIO = 0.6
SCROLL_PIXELS_MIN = 160
GEOMETRY_HINT_LIMIT = 160

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
_SCROLLABLE_DISPLAY_ROLES = frozenset({
    "list",
    "outline",
    "scroll area",
    "table",
    "web area",
})
_DIRECTIONAL_SCROLL_ACTIONS = frozenset({
    "AXScrollUpByPage",
    "AXScrollDownByPage",
    "AXScrollLeftByPage",
    "AXScrollRightByPage",
})
_AX_ACTIVATION_ACTIONS = frozenset({
    "AXConfirm",
    "AXPick",
    "AXPress",
})
_STRICT_SECONDARY_ACTIONS = frozenset({
    "AXScrollToVisible",
    "AXShowAlternateUI",
    "AXShowDefaultUI",
    "AXShowMenu",
})
_BUTTONISH_AX_ROLES = frozenset({
    "AXButton",
    "AXCheckBox",
    "AXMenuButton",
    "AXPopUpButton",
    "AXRadioButton",
    "AXTab",
})
_SELECTION_CONTAINER_ROLES = frozenset({
    "collection",
    "list",
    "outline",
    "table",
})


def _safe_perform_action(node: Node, action: str) -> bool:
    try:
        accessibility.perform_action(node, action)
        return True
    except Exception:
        return False
_GEOMETRY_HINT_ROLES = _POINTER_PREFERRED_ROLES | _SCROLLABLE_DISPLAY_ROLES
_TEXT_GROUNDING_ROLES = frozenset({
    "text",
    "heading",
    "image",
    "menu item",
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
    graphs: SessionGraphs = field(default_factory=SessionGraphs, repr=False)
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
    transient_graph_tracker: TransientGraphTracker | None = field(default=None, repr=False)
    ax_outcome_monitor: ActionOutcomeMonitor | None = field(default=None, repr=False)
    cgevent_outcome_monitor: CGEventOutcomeMonitor | None = field(default=None, repr=False)
    app_type: AppType = field(default=AppType.NATIVE_COCOA, repr=False)
    cursor: BackgroundCursor | None = field(default=None, repr=False)
    # Selection tracking
    selection_client: SelectionClient | None = field(default=None, repr=False)
    # ApplicationWindow bridge (permanent CG+AX association)
    application_window: ApplicationWindow | None = field(default=None, repr=False)
    # Scroll: cached working method per session (None = not yet determined)
    # Values: "ax", "pid", "system", None
    scroll_method: str | None = field(default=None, repr=False)
    last_action_verification: ActionVerificationResult | None = field(default=None, repr=False)
    last_delivery_verdict: Any = field(default=None, repr=False)  # DeliveryVerdict
    # Confirmed delivery pipeline — per-session event source and transport confirmation
    event_source: Any = field(default=None, repr=False)
    delivery_tap: Any = field(default=None, repr=False)  # DeliveryConfirmationTap
    pending_transient_source: TransientSource | None = field(default=None, repr=False)
    user_state_invalidated: bool = False
    user_state_invalidated_message: str | None = None


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
        self._graph_registry = GraphRegistry()

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

        transient_tracker = None
        if feature_flags.transient_graphs:
            transient_tracker = TransientGraphTracker()
            for notification in (
                AX_NOTIFICATION_MENU_OPENED,
                AX_NOTIFICATION_MENU_CLOSED,
                AX_NOTIFICATION_CREATED,
                AX_NOTIFICATION_WINDOW_CREATED,
                AX_NOTIFICATION_ELEMENT_DESTROYED,
                AX_NOTIFICATION_FOCUSED_ELEMENT_CHANGED,
                AX_NOTIFICATION_VALUE_CHANGED,
            ):
                bridge.subscribe_detailed(notification, transient_tracker.on_notification)

            app_level_targets = [session.target.ax_window]
            if session.target.ax_app is not None:
                app_level_targets.append(session.target.ax_app)
            for target in app_level_targets:
                if target is None:
                    continue
                for notification in (
                    AX_NOTIFICATION_MENU_OPENED,
                    AX_NOTIFICATION_MENU_CLOSED,
                    AX_NOTIFICATION_CREATED,
                    AX_NOTIFICATION_WINDOW_CREATED,
                    AX_NOTIFICATION_ELEMENT_DESTROYED,
                    AX_NOTIFICATION_FOCUSED_ELEMENT_CHANGED,
                    AX_NOTIFICATION_VALUE_CHANGED,
                ):
                    observer.add_notification(target, notification)

        observer_started = observer.start()
        if observer_started:
            session.observer = observer
            session.notification_bridge = bridge
            session.invalidation_monitor = invalidation_monitor
            session.menu_tracker = menu_tracker
            session.transient_graph_tracker = transient_tracker
            session.ax_outcome_monitor = ActionOutcomeMonitor(
                bridge,
                invalidation_monitor,
                transient_tracker,
            )
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
        if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is None:
            # Only add source filtering when confirmed_delivery is on — the
            # per-event Quartz call adds latency to every HID event system-wide
            _source_id = None
            if feature_flags.confirmed_delivery and session.event_source is not None:
                try:
                    from Quartz import CGEventSourceGetSourceStateID
                    _source_id = CGEventSourceGetSourceStateID(session.event_source)
                except Exception:
                    pass
            cgevent_monitor = CGEventOutcomeMonitor(source_state_id=_source_id)
            cgevent_monitor.start()
            session.cgevent_outcome_monitor = cgevent_monitor

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

        # Set up per-session event source and delivery confirmation tap
        if feature_flags.confirmed_delivery and session.event_source is None:
            from app._lib.input import create_event_source
            from app._lib.delivery_tap import DeliveryConfirmationTap
            session.event_source = create_event_source()
            try:
                from Quartz import CGEventSourceGetSourceStateID
                source_state_id = CGEventSourceGetSourceStateID(session.event_source)
            except (ImportError, Exception):
                source_state_id = 0
            if source_state_id != 0:
                tap = DeliveryConfirmationTap(expected_source_state_id=source_state_id)
                if tap.start():
                    session.delivery_tap = tap
                    logger.debug(
                        "Delivery confirmation tap started for %s (source_state_id=%d)",
                        session.target.bundle_id, source_state_id,
                    )
                else:
                    logger.debug("Delivery confirmation tap failed to start for %s", session.target.bundle_id)

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
        if session.transient_graph_tracker is not None:
            session.transient_graph_tracker.reset()
            session.transient_graph_tracker = None
        session.ax_outcome_monitor = None
        if session.cgevent_outcome_monitor is not None:
            session.cgevent_outcome_monitor.stop()
            session.cgevent_outcome_monitor = None
        if session.delivery_tap is not None:
            session.delivery_tap.stop()
            session.delivery_tap = None
        session.event_source = None

    def _activate_focus_enforcement(self, session: AppSession) -> None:
        """Step 6: Monitor focus without activating the target app.

        Creates a SyntheticAppFocusEnforcer that:
        1. Monitors frontmost app changes during the action
        2. Installs listen-only taps for focus-theft diagnostics
        3. Never proactively activates or raises the target app
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

    def _restore_previous_frontmost_app(
        self,
        session: AppSession | None,
        previous_frontmost: Any | None,
    ) -> None:
        if session is None or previous_frontmost is None:
            return
        try:
            previous_pid = int(previous_frontmost.processIdentifier())
        except Exception:
            previous_pid = None
        if previous_pid is None or previous_pid == session.target.pid:
            return
        current = apps.get_frontmost_app()
        try:
            current_pid = int(current.processIdentifier()) if current is not None else None
        except Exception:
            current_pid = None
        if current_pid == session.target.pid:
            apps.restore_frontmost(previous_frontmost)

    def _cleanup_after_action(
        self,
        session: AppSession | None,
        previous_frontmost: Any | None = None,
    ) -> None:
        """Clean up focus/input resources after action (success or error)."""
        if session is None:
            return
        if feature_flags.focus_enforcement:
            self._deactivate_focus_enforcement(session)
        if feature_flags.user_interruption_detection:
            self._user_interaction_monitor.stop_monitoring()
        # Remove delivery tap between actions — avoids Python callback overhead
        # on every input event while idle
        if session.delivery_tap is not None:
            session.delivery_tap.deactivate()
        self._restore_previous_frontmost_app(session, previous_frontmost)

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

    def _ensure_session_observer_ready(self, session: AppSession) -> None:
        if session.target.ax_window is None:
            return
        if (
            session.observer is None
            or session.invalidation_monitor is None
            or session.ax_outcome_monitor is None
        ):
            self._teardown_observer(session)
            self._setup_observer(session)
        if session.invalidation_monitor is None:
            return
        if session.refetchable_tree is not None:
            session.refetchable_tree.update(
                session.refetchable_tree.nodes,
                monitor=session.invalidation_monitor,
            )
        graphs: list[GraphRecord] = []
        if session.graphs.persistent_graph is not None:
            graphs.append(session.graphs.persistent_graph)
        graphs.extend(session.graphs.transient_stack)
        for graph in graphs:
            if graph.refetchable_tree is not None:
                graph.refetchable_tree.update(
                    graph.refetchable_tree.nodes,
                    monitor=session.invalidation_monitor,
                )

    def execute(self, tool: str, params: dict) -> ToolResponse:
        """Execute a tool call following the action pipeline.

        Pipeline steps:
        1. Log tool call
        2. Check app approval
        3. Check URL blocklist
        4. Ensure permissions
        5. Resolve element
        6. Monitor focus without activating the target app
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
        previous_frontmost = None
        with controller_tracer.interval(f"Action:{tool}") as span:
            try:
                with controller_tracer.interval("Resolve Session"):
                    self._ensure_trackers_started()
                    session = self._resolve_session(tool, params)
                if tool not in ("get_app_state", "list_apps"):
                    previous_frontmost = apps.get_frontmost_app()
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
                # Step 6c: Start user interaction monitoring
                if (
                    feature_flags.user_interruption_detection
                    and tool not in ("get_app_state", "list_apps")
                ):
                    self._user_interaction_monitor.start_monitoring(session.target.pid)
                # Steps 5-7: Element resolution + execute action
                with controller_tracer.interval(f"Execute:{tool}"):
                    result = self._dispatch(tool, session, params)
                transient_probe_active = (
                    feature_flags.transient_graphs
                    and tool not in ("get_app_state", "list_apps")
                    and session.transient_graph_tracker is not None
                    and session.transient_graph_tracker.has_active_transient
                )
                if transient_probe_active:
                    with controller_tracer.interval("Capture Transient Snapshot"):
                        response = self.take_snapshot(session, skip_refresh=True)
                    if feature_flags.user_interruption_detection:
                        interruption_msg = self._user_interaction_monitor.check_interruption(
                            session.target.bundle_id,
                        )
                        if interruption_msg is not None:
                            logger.info("userInterruptedControlledApp: %s", interruption_msg)
                            self._invalidate_session_for_user_change(session, interruption_msg)
                            self._user_interaction_monitor.stop_monitoring()
                            raise UserInterruptionError(interruption_msg)
                        self._user_interaction_monitor.stop_monitoring()
                    response.result = result
                    analytics.service_result(tool, success=True, duration_ms=0.0)
                    if feature_flags.focus_enforcement:
                        self._deactivate_focus_enforcement(session)
                    self._restore_previous_frontmost_app(session, previous_frontmost)
                    return response
                # Step 8: Wait for settle (event-driven via TreeInvalidationMonitor)
                settle_timeout = SETTLE_TIMEOUTS.get(tool, 1.0)
                transient_open = (
                    feature_flags.transient_graphs
                    and session.transient_graph_tracker is not None
                    and session.transient_graph_tracker.has_active_transient
                )
                if (
                    (
                        (feature_flags.menu_tracking and session.menu_tracker is not None and session.menu_tracker.menus_open)
                        or transient_open
                    )
                    and tool not in ("get_app_state", "list_apps")
                ):
                    # Use a short settle for open menus/transients rather than skipping entirely.
                    # Zero settle causes popovers and context menus to persist as visible artifacts.
                    logger.debug("Short settle for %s while menu/transient is open", tool)
                    settle_timeout = min(settle_timeout, 0.15)
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
                        self._invalidate_session_for_user_change(session, interruption_msg)
                        self._user_interaction_monitor.stop_monitoring()
                        raise UserInterruptionError(interruption_msg)
                    self._user_interaction_monitor.stop_monitoring()
                # Step 10: Capture snapshot
                with controller_tracer.interval("Capture Snapshot"):
                    # Skip redundant window refresh — session was just
                    # validated in _resolve_session and action just executed
                    response = self.take_snapshot(session, skip_refresh=True)
                response.result = result
                analytics.service_result(tool, success=True, duration_ms=0.0)
                if tool == "get_app_state":
                    self._clear_user_invalidated_state(session)
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
                self._restore_previous_frontmost_app(session, previous_frontmost)
                # Step 12: Return response
                return response
            except StaleReferenceError as e:
                self._cleanup_after_action(session, previous_frontmost)
                if session:
                    response = self.take_snapshot(session)
                    response.error = f"Element reference became stale: {e}. Tree refreshed."
                    return response
                return self._error_only(str(e))
            except UserInterruptionError as e:
                self._cleanup_after_action(session, previous_frontmost)
                if session is not None:
                    return ToolResponse(
                        app=session.target.bundle_id,
                        pid=session.target.pid,
                        snapshot_id=session.snapshot_id,
                        error=str(e),
                    )
                return self._error_only(str(e))
            except AutomationError as e:
                self._cleanup_after_action(session, previous_frontmost)
                if session:
                    return self._try_snapshot_or_error(session, e)
                return self._error_only(str(e))

    def _resolve_session(self, tool: str, params: dict) -> AppSession:
        window_id = params.get("window_id")
        if window_id is not None:
            session = self.get_or_create_session_for_window(int(window_id))
        else:
            app = params.get("app")
            if app is None:
                raise AutomationError(
                    f"{tool} requires window_id or app. Prefer window_id from the latest get_app_state."
                )
            session = self.get_or_create_session(app)

        if tool != "get_app_state" and getattr(session, "user_state_invalidated", False):
            raise UserInterruptionError(
                getattr(session, "user_state_invalidated_message", None)
                or "The user changed the target app. Re-query the latest state with `get_app_state` before sending more actions."
            )

        self._ensure_session_observer_ready(session)

        return session

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
        target_node = self._prepare_node_for_pointer_click(session, node)
        target_node = self._resolve_click_target_node(session, target_node)
        point = self._click_point_for_node(session, target_node)
        if point is None:
            return False
        sx, sy = point
        try:
            transport_mark = 0
            if session.cgevent_outcome_monitor is not None:
                _, transport_mark = session.cgevent_outcome_monitor.begin_action()
            notification_mark = (
                session.ax_outcome_monitor.mark()
                if session.ax_outcome_monitor is not None
                else None
            )
            cg_input.click_at_screen_point(
                self._background_pid_for_node(session, target_node),
                sx,
                sy,
                button=button,
                count=count,
                window_id=session.target.window_id,
                source=session.event_source,
            )
            if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                transient_source = None
                direct_verifier = self._make_selection_click_verifier(session, target_node)
                if button == "right":
                    transient_source = self._make_transient_source(
                        session,
                        node,
                        action_name="CGEventClick",
                        reopen_fn=lambda resolved: self._background_click_node(
                            session, resolved, button=button, count=count
                        ),
                        graph_kind=self._active_graph(session).kind if self._active_graph(session) is not None else GraphKind.PERSISTENT,
                    )
                verification = self._verify_cgevent_contract(
                    session,
                    expectation=expectation_for_click(button, count),
                    transport_mark=transport_mark,
                    contract=VerificationContract(
                        expect_transient_open=(button == "right"),
                        direct_verifier=direct_verifier,
                    ),
                    notification_mark=notification_mark,
                    transient_source=transient_source,
                )
                return verification in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }
            return True
        except InputError as exc:
            logger.debug("Background click fallback failed: %s", exc)
            return False

    def _iter_node_ancestors(self, session: AppSession, node: Node):
        if not session.tree_nodes or node.index is None:
            return
        ancestor_depth = node.depth
        for prev_idx in range(node.index - 1, -1, -1):
            prev = session.tree_nodes[prev_idx]
            if prev.depth >= ancestor_depth:
                continue
            yield prev
            ancestor_depth = prev.depth

    def _background_pid_for_node(self, session: AppSession, node: Node | None) -> int:
        if node is not None and node.is_oop and node.element_pid is not None:
            return node.element_pid
        return session.target.window_pid

    def _iter_live_click_ancestors(self, node: Node):
        current = node.ax_ref
        depth = node.depth
        for _ in range(12):
            if current is None:
                break
            parent = accessibility.get_parent_ref(current)
            if parent is None:
                break
            depth = max(0, depth - 1)
            current = parent
            yield accessibility.node_from_ref(parent, depth=depth)

    def _node_has_current_snapshot_index(self, session: AppSession, node: Node) -> bool:
        return (
            node.index is not None
            and 0 <= node.index < len(session.tree_nodes)
            and session.tree_nodes[node.index] is node
        )

    def _resolve_click_target_node(self, session: AppSession, node: Node) -> Node:
        candidates = [node]
        candidates.extend(self._iter_live_click_ancestors(node))
        if self._node_has_current_snapshot_index(session, node):
            candidates.extend(self._iter_node_ancestors(session, node) or [])
        for candidate in candidates:
            if accessibility.get_element_frame(candidate) is not None:
                return candidate
        return node

    def _window_visible_rect(self, session: AppSession) -> tuple[float, float, float, float] | None:
        return screenshot.get_window_bounds(session.target.window_id)

    def _visible_click_point_for_frame(
        self,
        session: AppSession,
        frame: tuple[float, float, float, float],
    ) -> tuple[float, float] | None:
        fx, fy, fw, fh = frame
        if fw <= 0 or fh <= 0:
            return None
        visible = self._window_visible_rect(session)
        if visible is None:
            return (fx + fw / 2, fy + fh / 2)
        vx, vy, vw, vh = visible
        if vw <= 0 or vh <= 0:
            return None
        ix = max(fx, vx)
        iy = max(fy, vy)
        iw = min(fx + fw, vx + vw) - ix
        ih = min(fy + fh, vy + vh) - iy
        if iw <= 0 or ih <= 0:
            return None
        return (ix + iw / 2, iy + ih / 2)

    def _click_point_for_node(
        self,
        session: AppSession,
        node: Node,
    ) -> tuple[float, float] | None:
        frame = accessibility.get_element_frame(node)
        if frame is None:
            return None
        return self._visible_click_point_for_frame(session, frame)

    def _node_is_visible_in_window(self, session: AppSession, node: Node) -> bool:
        frame = accessibility.get_element_frame(node)
        if frame is None:
            return False
        return self._visible_click_point_for_frame(session, frame) is not None

    def _refresh_live_node_from_ref(self, node: Node) -> Node:
        if node.ax_ref is None:
            return node
        try:
            return accessibility.node_from_ref(node.ax_ref, depth=node.depth)
        except Exception:
            logger.debug("Failed to refresh live node %s from AX ref", node.index, exc_info=True)
            return node

    def _prepare_node_for_pointer_click(self, session: AppSession, node: Node) -> Node:
        if self._node_is_visible_in_window(session, node):
            return node
        if "AXScrollToVisible" not in self._node_action_names(node):
            return node
        try:
            mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
            accessibility.perform_action(node, "AXScrollToVisible")
            verification = self._verify_ax_contract(
                session,
                contract=VerificationContract(
                    allow_focus_change=False,
                    allow_value_change=False,
                    direct_verifier=lambda: self._node_is_visible_in_window(
                        session,
                        self._refresh_live_node_from_ref(node),
                    ),
                ),
                mark=mark,
            )
            if verification in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_OPENED,
            }:
                return self._refresh_live_node_from_ref(node)
        except Exception:
            logger.debug("AXScrollToVisible failed for element %s", node.index, exc_info=True)
        return node

    def _try_ax_click_node(
        self,
        session: AppSession,
        node: Node,
        idx: int,
        *,
        button: str,
        count: int,
    ) -> str | None:
        if count == 1 and button == "left" and "selectable" in node.states:
            try:
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                accessibility.set_attribute(node, "AXSelected", True)
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(
                        direct_verifier=lambda: "selected" in accessibility.node_from_ref(node.ax_ref).states
                        if node.ax_ref is not None
                        else False
                    ),
                    mark=mark,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    return None
                return f"Clicked element {idx} (AXSelected)"
            except Exception:
                logger.debug("AXSelected failed for element %d", idx)

        if button == "right":
            try:
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                accessibility.perform_action(node, "AXShowMenu")
                transient_source = self._make_transient_source(
                    session,
                    node,
                    action_name="AXShowMenu",
                    reopen_fn=lambda resolved: _safe_perform_action(resolved, "AXShowMenu"),
                    graph_kind=self._active_graph(session).kind if self._active_graph(session) is not None else GraphKind.PERSISTENT,
                )
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(expect_transient_open=True),
                    mark=mark,
                    transient_source=transient_source,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    return None
                return f"Right-clicked element {idx} (AXShowMenu)"
            except Exception:
                logger.debug("AXShowMenu failed for element %d", idx)
                if session.input_strategy is not None:
                    session.input_strategy.record_ax_failure()
                return None

        if count == 1 and button == "left":
            if self._should_force_pointer_for_node(node):
                return None
            try:
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                accessibility.perform_action(node, "AXPress")
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(),
                    mark=mark,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    return None
                return f"Clicked element {idx} (AXPress)"
            except Exception:
                logger.debug("AXPress failed for element %d", idx)
                if session.input_strategy is not None:
                    session.input_strategy.record_ax_failure()
        return None

    def _try_ax_hit_test_click(
        self,
        session: AppSession,
        node: Node,
        idx: int,
        *,
        button: str,
        count: int,
    ) -> str | None:
        if count != 1:
            return None
        target_node = self._resolve_click_target_node(session, node)
        point = self._click_point_for_node(session, target_node)
        if point is None:
            return None
        hit_ref = accessibility.element_at_position(session.target.ax_app, point[0], point[1])
        if hit_ref is None:
            return None
        try:
            mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
            if button == "right":
                accessibility.perform_action_on_ref(hit_ref, "AXShowMenu")
                transient_source = None
                try:
                    hit_node = accessibility.node_from_ref(hit_ref)
                    transient_source = self._make_transient_source(
                        session,
                        hit_node,
                        action_name="AXShowMenu",
                        reopen_fn=lambda resolved: _safe_perform_action(resolved, "AXShowMenu"),
                        graph_kind=self._active_graph(session).kind if self._active_graph(session) is not None else GraphKind.PERSISTENT,
                    )
                except Exception:
                    transient_source = None
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(expect_transient_open=True),
                    mark=mark,
                    transient_source=transient_source,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    return None
                return f"Right-clicked element {idx} (AX hit-test)"
            accessibility.perform_action_on_ref(hit_ref, "AXPress")
            verification = self._verify_ax_contract(
                session,
                contract=VerificationContract(),
                mark=mark,
            )
            if verification not in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_OPENED,
            }:
                return None
            return f"Clicked element {idx} (AX hit-test)"
        except Exception:
            logger.debug("AX hit-test action failed for element %d", idx)
            return None

    def _try_ax_hit_test_click_at_point(
        self,
        session: AppSession,
        x: float,
        y: float,
        *,
        display_x: float,
        display_y: float,
        button: str,
        count: int,
    ) -> str | None:
        if count != 1:
            return None
        hit_ref = accessibility.element_at_position(session.target.ax_app, x, y)
        if hit_ref is None:
            return None

        try:
            hit_node = accessibility.node_from_ref(hit_ref)
        except Exception:
            hit_node = None

        if (
            hit_node is not None
            and session.input_strategy is not None
            and not session.input_strategy.should_use_ax_action(
                "click",
                is_web_area=hit_node.is_web_area,
            )
        ):
            return None

        try:
            mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
            if button == "right":
                accessibility.perform_action_on_ref(hit_ref, "AXShowMenu")
                transient_source = self._make_transient_source(
                    session,
                    hit_node if hit_node is not None else accessibility.node_from_ref(hit_ref),
                    action_name="AXShowMenu",
                    reopen_fn=lambda resolved: _safe_perform_action(resolved, "AXShowMenu"),
                    graph_kind=self._active_graph(session).kind if self._active_graph(session) is not None else GraphKind.PERSISTENT,
                )
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(expect_transient_open=True),
                    mark=mark,
                    transient_source=transient_source,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    return None
                return f"Right-clicked at ({display_x}, {display_y}) (AX hit-test)"
            accessibility.perform_action_on_ref(hit_ref, "AXPress")
            verification = self._verify_ax_contract(
                session,
                contract=VerificationContract(),
                mark=mark,
            )
            if verification not in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_OPENED,
            }:
                return None
            return f"Clicked at ({display_x}, {display_y}) (AX hit-test)"
        except Exception:
            logger.debug("AX hit-test action failed at (%s, %s)", x, y)
            if session.input_strategy is not None:
                session.input_strategy.record_ax_failure()
            return None

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
        has_web_ancestor = (
            node.index is not None
            and node.index < len(session.tree_nodes)
            and self._has_web_ancestor(session.tree_nodes, node.index)
        )
        if session.input_strategy is not None and not session.input_strategy.should_use_ax_action(
            "click",
            is_web_area=node.is_web_area or has_web_ancestor,
        ):
            return True
        if node.role not in _POINTER_PREFERRED_ROLES:
            return False
        if node.index is None or node.index >= len(session.tree_nodes):
            return False
        if self._should_force_pointer_for_node(node):
            return True
        return has_web_ancestor

    def _node_action_names(self, node: Node) -> set[str]:
        if node.ax_ref is None:
            return set(node.secondary_actions)
        try:
            return set(accessibility.get_action_names_for_ref(node.ax_ref))
        except Exception:
            logger.debug("Failed to read raw AX actions for node %s", node.index, exc_info=True)
            return set(node.secondary_actions)

    def _should_force_pointer_for_node(self, node: Node) -> bool:
        if node.ax_role not in _BUTTONISH_AX_ROLES:
            return False
        action_names = self._node_action_names(node)
        if not action_names:
            return False
        return action_names.isdisjoint(_AX_ACTIVATION_ACTIONS)

    def _node_identity(self, node: Node) -> tuple[str | None, str | None, str | None]:
        return (node.ax_id, node.description, node.label)

    def _selection_container_node(self, session: AppSession, node: Node) -> Node | None:
        candidates = [self._refresh_live_node_from_ref(node)]
        candidates.extend(self._iter_live_click_ancestors(node))
        if self._node_has_current_snapshot_index(session, node):
            candidates.extend(self._iter_node_ancestors(session, node) or [])
        for candidate in candidates:
            if candidate.role in _SELECTION_CONTAINER_ROLES and candidate.ax_ref is not None:
                return candidate
        return None

    def _selected_identities_in_container(
        self,
        session: AppSession,
        container: Node,
    ) -> set[tuple[str | None, str | None, str | None]]:
        if container.ax_ref is None:
            return set()
        try:
            subtree = accessibility.walk_tree(
                container.ax_ref,
                include_actions=False,
                target_pid=self._background_pid_for_node(session, container),
            )
        except Exception:
            logger.debug("Failed to collect selection subtree for node %s", container.index, exc_info=True)
            return set()
        return {
            self._node_identity(item)
            for item in subtree
            if "selected" in item.states
        }

    def _make_selection_click_verifier(
        self,
        session: AppSession,
        node: Node,
    ) -> Callable[[], bool] | None:
        if not self._should_force_pointer_for_node(node):
            return None
        container = self._selection_container_node(session, node)
        if container is None:
            return None
        baseline_selected = self._selected_identities_in_container(session, container)
        target_identity = self._node_identity(node)

        def _verifier() -> bool:
            refreshed = self._refresh_live_node_from_ref(node)
            if "selected" in refreshed.states:
                return True
            refreshed_container = self._refresh_live_node_from_ref(container)
            selected_after = self._selected_identities_in_container(session, refreshed_container)
            return selected_after != baseline_selected and target_identity in selected_after

        return _verifier

    def _focus_node_for_keyboard_input(self, session: AppSession, node: Node) -> bool:
        """Focus an element for keyboard input WITHOUT activating the app.

        Uses element-level AX focus first and falls back to a background click
        on the target element if the app does not expose a focusable AX field.
        """
        try:
            accessibility.set_attribute(node, "AXFocused", True)
            time.sleep(0.02)
            return True
        except Exception:
            pass
        if self._background_click_node(session, node):
            time.sleep(0.05)
            return True
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

    def _should_annotate_geometry(self, node: Node) -> bool:
        if node.role in _GEOMETRY_HINT_ROLES:
            return True
        if node.role in _TEXT_GROUNDING_ROLES and node.label:
            return True
        if node.secondary_actions:
            return True
        return "settable" in node.states

    def _screen_frame_to_screenshot_frame(
        self,
        frame: tuple[float, float, float, float],
        visible_rect: Rect,
        screenshot_size: tuple[int, int],
    ) -> tuple[float, float, float, float] | None:
        fx, fy, fw, fh = frame
        if fw <= 0 or fh <= 0 or visible_rect.w <= 0 or visible_rect.h <= 0:
            return None

        ix = max(fx, visible_rect.x)
        iy = max(fy, visible_rect.y)
        iw = min(fx + fw, visible_rect.x + visible_rect.w) - ix
        ih = min(fy + fh, visible_rect.y + visible_rect.h) - iy
        if iw <= 0 or ih <= 0:
            return None

        shot_width, shot_height = screenshot_size
        scale_x = shot_width / visible_rect.w
        scale_y = shot_height / visible_rect.h
        return (
            (ix - visible_rect.x) * scale_x,
            (iy - visible_rect.y) * scale_y,
            iw * scale_x,
            ih * scale_y,
        )

    def _annotate_node_geometry(
        self,
        nodes: list[Node],
        app_state: AppState | None,
        screenshot_size: tuple[int, int] | None,
    ) -> None:
        for node in nodes:
            node.position = None
            node.size = None

        if app_state is None or app_state.visible_rect is None or screenshot_size is None:
            return
        if (
            not isinstance(screenshot_size, tuple)
            or len(screenshot_size) != 2
            or not all(isinstance(v, (int, float)) for v in screenshot_size)
        ):
            return

        annotated = 0
        for node in nodes:
            if annotated >= GEOMETRY_HINT_LIMIT:
                break
            if not self._should_annotate_geometry(node):
                continue
            frame = accessibility.get_element_frame(node)
            if frame is None:
                continue
            screenshot_frame = self._screen_frame_to_screenshot_frame(
                frame,
                app_state.visible_rect,
                screenshot_size,
            )
            if screenshot_frame is None:
                continue
            node.position = Point(x=screenshot_frame[0], y=screenshot_frame[1])
            node.size = Size(w=screenshot_frame[2], h=screenshot_frame[3])
            annotated += 1

    def _collect_tree_nodes(
        self,
        ax_window: Any,
        *,
        ax_app: Any | None = None,
        target_pid: int | None = None,
        app_type: AppType | None = None,
    ) -> list[Node]:
        nodes = accessibility.walk_tree(ax_window, target_pid=target_pid)
        return self._expand_focused_collection_children(nodes)

    def _node_has_descendants(self, nodes: list[Node], index: int) -> bool:
        if not (0 <= index < len(nodes)):
            return False
        depth = nodes[index].depth
        for next_index in range(index + 1, len(nodes)):
            next_node = nodes[next_index]
            if next_node.depth <= depth:
                return False
            return True
        return False

    def _node_has_meaningful_direct_children(self, nodes: list[Node], index: int) -> bool:
        if not (0 <= index < len(nodes)):
            return False
        depth = nodes[index].depth
        direct_children: list[Node] = []
        for next_index in range(index + 1, len(nodes)):
            next_node = nodes[next_index]
            if next_node.depth <= depth:
                break
            if next_node.depth == depth + 1:
                direct_children.append(next_node)
        if not direct_children:
            return False
        return any(child.ax_role != "AXScrollBar" for child in direct_children)

    def _live_collection_children(self, node: Node) -> list[Node]:
        if node.ax_ref is None:
            return []
        try:
            from ApplicationServices import AXUIElementCopyAttributeValue, kAXErrorSuccess
        except Exception:
            return []

        child_refs: list[Any] = []
        for attr in ("AXChildren", "AXChildrenInNavigationOrder", "AXVisibleChildren"):
            try:
                err, refs = AXUIElementCopyAttributeValue(node.ax_ref, attr, None)
            except Exception:
                continue
            if err != kAXErrorSuccess or refs is None:
                continue
            child_refs = list(refs)
            if child_refs:
                break
        children: list[Node] = []
        for child_ref in child_refs[:100]:
            try:
                child = accessibility.node_from_ref(child_ref, depth=node.depth + 1, index=-1)
            except Exception:
                continue
            children.append(child)
        return children

    def _expand_focused_collection_children(self, nodes: list[Node]) -> list[Node]:
        if not nodes:
            return nodes

        expanded: list[Node] = []
        for index, node in enumerate(nodes):
            expanded.append(node)
            if "focused" not in node.states:
                continue
            if node.role not in {"collection", "list"} and node.ax_role not in {"AXCollection", "AXList", "AXOpaqueProviderGroup"}:
                continue
            if self._node_has_meaningful_direct_children(nodes, index):
                continue
            children = self._live_collection_children(node)
            if not children:
                continue
            expanded.extend(children)

        for new_index, node in enumerate(expanded):
            node.index = new_index
        return expanded

    def _walk_interaction_tree(
        self,
        ax_window: Any,
        *,
        ax_app: Any | None = None,
        target_pid: int | None = None,
        bundle_id: str | None = None,
        app_type: AppType | None = None,
    ) -> list[Node]:
        nodes = self._collect_tree_nodes(
            ax_window,
            ax_app=ax_app,
            target_pid=target_pid,
            app_type=app_type,
        )
        return self._prune_tree_nodes(
            nodes,
            bundle_id=bundle_id,
            app_type=app_type,
            ax_app=ax_app,
            target_pid=target_pid,
        )

    def _normalize_focused_index(self, nodes: list[Node], focused_index: int | None) -> int | None:
        index = focused_index
        if index is None or not (0 <= index < len(nodes)):
            index = self._focused_index_from_states(nodes)
            if index is None:
                return None

        node = nodes[index]
        if node.ax_role == "AXList" and node.subrole == "AXCollectionList":
            index = 0 if nodes else index

        if feature_flags.codex_tree_style:
            ancestor_index = self._preferred_focus_ancestor(nodes, index)
            if ancestor_index is not None:
                return ancestor_index
        return index

    def _focused_index_from_states(self, nodes: list[Node]) -> int | None:
        for position, node in enumerate(nodes):
            if any(str(state).lower() == "focused" for state in node.states):
                return position
        return None

    def _preferred_focus_ancestor(self, nodes: list[Node], focused_index: int) -> int | None:
        if not (0 <= focused_index < len(nodes)):
            return None
        focused_node = nodes[focused_index]
        if focused_node.role not in {"text area", "text field"}:
            return None
        target_depth = focused_node.depth
        for position in range(focused_index - 1, -1, -1):
            candidate = nodes[position]
            if candidate.depth >= target_depth:
                continue
            if candidate.role in _WEB_CONTAINER_ROLES:
                return position
            target_depth = candidate.depth
        return None

    def _prune_tree_nodes(
        self,
        nodes: list[Node],
        *,
        bundle_id: str | None = None,
        app_type: AppType | None = None,
        ax_app: Any | None = None,
        target_pid: int | None = None,
    ) -> list[Node]:
        if not feature_flags.tree_pruning or not nodes:
            return nodes

        use_codex_tree = feature_flags.codex_tree_style

        if use_codex_tree:
            from app._lib.pruning import prune_for_codex_tree
            if ax_app is not None:
                menu_bar = accessibility.get_menu_bar(ax_app)
                if menu_bar is not None:
                    menu_nodes = accessibility.walk_tree(menu_bar, target_pid=target_pid)
                    if menu_nodes:
                        filtered_menu_nodes: list[Node] = []
                        for node in menu_nodes:
                            # Codex-style output only shows the top-level menu bar
                            # and its immediate items, not expanded menu trees.
                            if node.depth > 1:
                                continue
                            if node.depth == 1 and (node.label or node.description) == "Apple":
                                continue
                            node.depth += 1
                            filtered_menu_nodes.append(node)
                        nodes = [*nodes, *filtered_menu_nodes]
            return prune_for_codex_tree(nodes, bundle_id=bundle_id)

        from app._lib.pruning import prune as prune_nodes
        pruned_nodes, _, _ = prune_nodes(
            nodes,
            advanced=feature_flags.advanced_pruning,
            bundle_id=bundle_id,
        )
        return pruned_nodes

    def _active_graph(self, session: AppSession) -> GraphRecord | None:
        return self._graph_registry.active_graph(session.graphs)

    def _active_transient_surface(self, session: AppSession) -> TransientSurface | None:
        if not feature_flags.transient_graphs or session.transient_graph_tracker is None:
            return None
        return session.transient_graph_tracker.active_surface

    def _graph_state_getter(self, session: AppSession, graph_id: str) -> Any:
        def _getter() -> GraphState:
            graph = self._graph_registry.find(session.graphs, graph_id)
            if graph is None:
                return GraphState.CLOSED
            if graph.kind == GraphKind.TRANSIENT and session.transient_graph_tracker is not None:
                if not session.transient_graph_tracker.is_root_live(graph.root_ref):
                    graph.state = GraphState.CLOSED
                    return graph.state
            if session.invalidation_monitor is not None and session.invalidation_monitor.is_invalidated:
                graph.state = GraphState.INVALIDATED
                return graph.state
            return graph.state

        return _getter

    def _resolve_locator_in_graph(
        self,
        session: AppSession,
        locator: Any,
        *,
        kind: GraphKind = GraphKind.PERSISTENT,
    ) -> Node | None:
        if locator is None:
            return None
        if kind == GraphKind.PERSISTENT:
            graph = session.graphs.persistent_graph
        else:
            graph = self._active_graph(session)
        if graph is None:
            return None
        return match_node_by_locator(graph.nodes, locator)

    def _reopen_active_transient_graph(self, session: AppSession) -> list[Node] | None:
        graph = self._active_graph(session)
        if graph is None or graph.kind != GraphKind.TRANSIENT:
            return None
        source = graph.source
        if source is None or source.reopen is None:
            return None
        graph.state = GraphState.REOPENING
        if not source.reopen():
            graph.state = GraphState.CLOSED
            return None
        snapshot = self.take_snapshot(session, skip_refresh=True)
        return snapshot.tree_nodes

    def _invalidate_session_for_user_change(self, session: AppSession, message: str) -> None:
        session.user_state_invalidated = True
        session.user_state_invalidated_message = message
        if session.graphs.persistent_graph is not None:
            session.graphs.persistent_graph.state = GraphState.INVALIDATED
        for graph in session.graphs.transient_stack:
            graph.state = GraphState.CLOSED
        session.pending_transient_source = None

    def _clear_user_invalidated_state(self, session: AppSession) -> None:
        session.user_state_invalidated = False
        session.user_state_invalidated_message = None

    def _dismiss_transient_surface(self, session: AppSession, graph: GraphRecord) -> None:
        if graph.kind != GraphKind.TRANSIENT:
            return
        tracker = session.transient_graph_tracker
        if tracker is None or not tracker.is_root_live(graph.root_ref):
            graph.state = GraphState.CLOSED
            return

        actions = set(accessibility.get_action_names_for_ref(graph.root_ref))
        dismiss_actions = [action for action in ("AXCancel", "AXPress") if action in actions]

        for action in dismiss_actions:
            try:
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                accessibility.perform_action_on_ref(graph.root_ref, action)
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(expect_transient_close=True),
                    mark=mark,
                    timeout=0.2,
                )
                if verification in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_CLOSED,
                }:
                    graph.state = GraphState.CLOSED
                    return
            except Exception:
                logger.debug("Transient dismiss via %s failed", action, exc_info=True)

        if tracker is not None and not tracker.is_root_live(graph.root_ref):
            graph.state = GraphState.CLOSED

    def _make_transient_source(
        self,
        session: AppSession,
        node: Node,
        *,
        action_name: str,
        reopen_fn: Callable[[Node], bool],
        graph_kind: GraphKind = GraphKind.PERSISTENT,
    ) -> TransientSource:
        locator = getattr(node, "graph_locator", None)

        def _reopen() -> bool:
            resolved = self._resolve_locator_in_graph(session, locator, kind=graph_kind)
            if resolved is None:
                return False
            return reopen_fn(resolved)

        return TransientSource(
            action_name=action_name,
            node_locator=locator,
            graph_kind=graph_kind,
            description=node.label or node.description or node.role,
            reopen=_reopen,
        )

    def _verify_ax_contract(
        self,
        session: AppSession,
        *,
        contract: VerificationContract,
        mark: tuple[int, int, int] | None,
        transient_source: TransientSource | None = None,
        timeout: float = 0.35,
    ) -> ActionVerificationResult:
        if not feature_flags.ax_action_verification or session.ax_outcome_monitor is None:
            if transient_source is not None:
                session.pending_transient_source = transient_source
            if contract.direct_verifier is not None:
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    try:
                        if contract.direct_verifier():
                            return ActionVerificationResult.CONFIRMED
                    except Exception:
                        logger.debug("Direct verifier raised", exc_info=True)
                    time.sleep(0.01)
                return ActionVerificationResult.TIMEOUT
            return ActionVerificationResult.CONFIRMED
        result = session.ax_outcome_monitor.verify(contract=contract, mark=mark, timeout=timeout)
        session.last_action_verification = result
        if result == ActionVerificationResult.TRANSIENT_OPENED and transient_source is not None:
            session.pending_transient_source = transient_source
        return result

    def _verify_cgevent_contract(
        self,
        session: AppSession,
        *,
        expectation: Any,
        transport_mark: int,
        contract: VerificationContract,
        notification_mark: tuple[int, int, int] | None,
        transient_source: TransientSource | None = None,
        timeout: float = 0.35,
    ) -> ActionVerificationResult:
        if not feature_flags.cgevent_action_verification:
            if transient_source is not None:
                session.pending_transient_source = transient_source
            return ActionVerificationResult.CONFIRMED

        if session.cgevent_outcome_monitor is None:
            outcome = self._verify_ax_contract(
                session,
                contract=contract,
                mark=notification_mark,
                transient_source=transient_source,
                timeout=timeout,
            )
            if contract.direct_verifier is not None or contract.expect_transient_open or contract.expect_transient_close:
                return outcome
            return ActionVerificationResult.CONFIRMED

        transport_ok = session.cgevent_outcome_monitor.verify_transport(
            start_sequence=transport_mark,
            expectation=expectation,
            timeout=min(timeout, 0.25),
        )
        outcome = self._verify_ax_contract(
            session,
            contract=contract,
            mark=notification_mark,
            transient_source=transient_source,
            timeout=timeout,
        )
        if transport_ok and outcome in {
            ActionVerificationResult.CONFIRMED,
            ActionVerificationResult.TRANSIENT_OPENED,
            ActionVerificationResult.TRANSIENT_CLOSED,
        }:
            return outcome
        if transport_ok:
            return ActionVerificationResult.NO_EFFECT
        return ActionVerificationResult.TIMEOUT

    def _capture_element_snapshot(self, session: AppSession, node: Node | None) -> Any:
        """Capture lightweight element state for pre/post comparison."""
        from app._lib.confirmed_verification import ElementSnapshot

        value = None
        selected = False
        child_count = 0
        if node is not None:
            value = getattr(node, 'value', None)
            selected = getattr(node, 'selected', False)
            child_count = len(node.children) if hasattr(node, 'children') else 0

        focused_id = None
        if node is not None:
            try:
                focused = accessibility.get_focused_element(
                    session.target.ax_app, session.tree_nodes
                )
                if focused is not None:
                    focused_id = id(focused)
            except Exception:
                pass

        menu_open = False
        if session.menu_tracker is not None:
            menu_open = session.menu_tracker.menus_open

        return ElementSnapshot(
            value=value,
            selected=selected,
            focused_element_id=focused_id,
            menu_open=menu_open,
            child_count=child_count,
        )

    def _compute_delivery_verdict(
        self,
        session: AppSession,
        before: Any,
        after: Any,
        *,
        transport_confirmed: bool,
        fallback_used: bool,
        expected: Any,
    ) -> Any:
        """Compute and store the delivery verdict alongside existing verification."""
        from app._lib.confirmed_verification import ActionVerifier

        diff = before.diff(after)
        verdict = ActionVerifier.compute_verdict(
            transport_confirmed=transport_confirmed,
            diff_any_changed=diff.any_changed,
            expected=expected,
            fallback_used=fallback_used,
        )
        session.last_delivery_verdict = verdict
        return verdict

    def _take_transient_snapshot(
        self,
        session: AppSession,
        surface: TransientSurface,
    ) -> ToolResponse:
        """Capture a transient-only snapshot without rebuilding the main window state.

        This is the fast path for menus, context menus, and popovers that open
        from an already-established persistent graph. We only walk the transient
        root, keep the persistent graph cached underneath, and skip screenshot,
        geometry, rich-text extraction, and other heavyweight persistent-window
        work.
        """
        t = session.target
        root_ref = surface.root_ref
        nodes = self._collect_tree_nodes(
            root_ref,
            ax_app=t.ax_app,
            target_pid=t.pid,
            app_type=session.app_type,
        )
        nodes = self._prune_tree_nodes(
            nodes,
            bundle_id=t.bundle_id,
            app_type=session.app_type,
            ax_app=None,
            target_pid=t.pid,
        )

        active_graph = self._graph_registry.push_transient(
            session.graphs,
            root_ref=root_ref,
            nodes=nodes,
            root_locator=None,
            source=session.pending_transient_source,
            transient_kind=surface.kind,
        )
        session.pending_transient_source = None
        annotate_graph_nodes(nodes, active_graph.graph_id, active_graph.generation)
        active_graph.nodes = nodes
        active_graph.root_locator = nodes[0].graph_locator if nodes else None

        tree_text = serialize(
            nodes,
            focused_index=None,
            enable_pruning=False,
            codex_style=feature_flags.codex_tree_style,
        )

        window_title = self._get_window_title(t.ax_window) if t.ax_window is not None else None
        header = make_header(
            t.bundle_id,
            t.pid,
            window_title,
            t.window_id,
            t.window_pid,
            None,
            app_state=None,
            codex_style=feature_flags.codex_tree_style,
        )

        session.snapshot_id += 1
        session.tree_nodes = nodes
        session.screenshot_size = None

        refetch_walk = (
            lambda ax_window, *, target_pid=None, bundle_id=t.bundle_id, app_type=session.app_type, ax_app=t.ax_app: self._walk_interaction_tree(
                ax_window,
                ax_app=ax_app,
                target_pid=target_pid,
                bundle_id=bundle_id,
                app_type=app_type,
            )
        )
        reopen_cb = lambda: self._reopen_active_transient_graph(session)
        if active_graph.refetchable_tree is not None:
            active_graph.refetchable_tree.update(
                nodes,
                ax_window=root_ref,
                monitor=session.invalidation_monitor,
                graph_id=active_graph.graph_id,
                generation=active_graph.generation,
                graph_state_getter=self._graph_state_getter(session, active_graph.graph_id),
                reopen_fn=reopen_cb,
            )
        else:
            active_graph.refetchable_tree = RefetchableTree(
                nodes=nodes,
                monitor=session.invalidation_monitor,
                ax_window=root_ref,
                target_pid=t.pid,
                walk_fn=refetch_walk,
                graph_id=active_graph.graph_id,
                generation=active_graph.generation,
                graph_state_getter=self._graph_state_getter(session, active_graph.graph_id),
                reopen_fn=reopen_cb,
            )
        session.refetchable_tree = active_graph.refetchable_tree
        self._dismiss_transient_surface(session, active_graph)

        return ToolResponse(
            app=t.bundle_id,
            pid=t.pid,
            snapshot_id=session.snapshot_id,
            window_title=window_title,
            tree_text=f"{header}\n\n{tree_text}",
            tree_nodes=nodes,
            focused_element=None,
            screenshot=None,
            app_state=None,
            system_selection=None,
        )

    def take_snapshot(self, session: AppSession, *, skip_refresh: bool = False) -> ToolResponse:
        transient_surface = self._active_transient_surface(session)

        # Step 1: Refresh references for the targeted window
        # (skipped when the caller just validated the session, e.g. get_app_state)
        if not skip_refresh and transient_surface is None:
            self._refresh_window(session)
        t = session.target

        # Retry once if the AX reference for the targeted window is temporarily unavailable
        if t.ax_window is None and transient_surface is None:
            time.sleep(WINDOW_RETRY_DELAY_S)
            self._refresh_window(session)
            if t.ax_window is None:
                raise AutomationError(
                    f"Target window {t.window_id} in {t.bundle_id} is no longer available."
                )

        if transient_surface is not None:
            return self._take_transient_snapshot(session, transient_surface)

        # Step 1b: Update/create ApplicationWindow bridge
        self._update_application_window(session)

        graph_kind = GraphKind.PERSISTENT
        root_ref = t.ax_window
        capture_screenshot = True
        include_menu_bar = True
        transient_kind: str | None = None

        # Step 2: Walk AX tree (use cache if tree not invalidated)
        if (
            session.refetchable_tree is not None
            and not session.refetchable_tree.is_invalidated
            and graph_kind == GraphKind.PERSISTENT
        ):
            nodes = session.refetchable_tree.nodes
            logger.debug("Using cached AX tree (%d nodes, not invalidated)", len(nodes))
        else:
            with controller_tracer.interval("Walk AX Tree"):
                nodes = self._collect_tree_nodes(
                    root_ref,
                    ax_app=t.ax_app,
                    target_pid=t.pid,
                    app_type=session.app_type,
                )
        # Step 3: Capture screenshot — SCK primary, CGWindowListCreateImage fallback
        img = self._capture_screenshot(session, t) if capture_screenshot else None
        if capture_screenshot and img is None:
            # Retry: refresh window references and try again
            time.sleep(SCREENSHOT_RETRY_DELAY_S)
            self._refresh_window(session)
            t = session.target
            if t.ax_window is None:
                raise ScreenshotError(
                    f"Target window {t.window_id} in {t.bundle_id} disappeared while capturing a snapshot."
                )
            with controller_tracer.interval("Walk AX Tree (retry)"):
                nodes = self._collect_tree_nodes(
                    t.ax_window,
                    ax_app=t.ax_app,
                    target_pid=t.pid,
                    app_type=session.app_type,
                )
            img = self._capture_screenshot(session, t)
            if img is None:
                logger.warning(
                    "Screenshot unavailable for window %d in %s (screen recording permission may be missing)",
                    t.window_id, t.bundle_id,
                )
        # Step 4: Query focused element
        focused = self._normalize_focused_index(
            nodes,
            accessibility.get_focused_element(t.ax_app, nodes) if graph_kind == GraphKind.PERSISTENT else None,
        )
        transport_img = screenshot.prepare_image_for_transport(img) if img else None
        session.screenshot_size = transport_img.size if transport_img else None
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
        nodes = self._prune_tree_nodes(
            nodes,
            bundle_id=t.bundle_id,
            app_type=session.app_type,
            ax_app=t.ax_app if include_menu_bar else None,
            target_pid=t.pid,
        )
        focused = self._normalize_focused_index(
            nodes,
            accessibility.get_focused_element(t.ax_app, nodes) if graph_kind == GraphKind.PERSISTENT else None,
        )
        self._annotate_node_geometry(nodes, app_state, session.screenshot_size)
        active_graph: GraphRecord | None = None
        if feature_flags.transient_graphs:
            if graph_kind == GraphKind.TRANSIENT:
                active_graph = self._graph_registry.push_transient(
                    session.graphs,
                    root_ref=root_ref,
                    nodes=nodes,
                    root_locator=None,
                    source=session.pending_transient_source,
                    transient_kind=transient_kind,
                )
                session.pending_transient_source = None
            else:
                if session.graphs.transient_stack:
                    self._graph_registry.mark_transients_closed(session.graphs)
                active_graph = self._graph_registry.set_persistent(
                    session.graphs,
                    root_ref=root_ref,
                    nodes=nodes,
                    root_locator=None,
                )
            annotate_graph_nodes(nodes, active_graph.graph_id, active_graph.generation)
            active_graph.nodes = nodes
            active_graph.root_locator = nodes[0].graph_locator if nodes else None
        tree_text = serialize(
            nodes,
            focused,
            enable_pruning=False,
            codex_style=feature_flags.codex_tree_style,
        )
        # Step 7: Build header
        screenshot_size = session.screenshot_size
        header = make_header(
            t.bundle_id,
            t.pid,
            window_title,
            t.window_id,
            t.window_pid,
            screenshot_size,
            app_state=app_state,
            codex_style=feature_flags.codex_tree_style,
        )
        # Step 8: Increment snapshot_id
        session.snapshot_id += 1
        # Step 9: Store tree_nodes on session for index resolution
        # nodes is now the pruned list — indexes match what the model sees
        session.tree_nodes = nodes
        # Step 9b: Update/create RefetchableTree
        refetch_walk = (
            lambda ax_window, *, target_pid=None, bundle_id=t.bundle_id, app_type=session.app_type, ax_app=t.ax_app: self._walk_interaction_tree(
                ax_window,
                ax_app=ax_app,
                target_pid=target_pid,
                bundle_id=bundle_id,
                app_type=app_type,
            )
        )
        if feature_flags.transient_graphs and active_graph is not None:
            reopen_cb = (
                (lambda: self._reopen_active_transient_graph(session))
                if active_graph.kind == GraphKind.TRANSIENT
                else None
            )
            if active_graph.refetchable_tree is not None:
                active_graph.refetchable_tree.update(
                    nodes,
                    ax_window=root_ref,
                    monitor=session.invalidation_monitor,
                    target_pid=t.pid,
                    walk_fn=refetch_walk,
                    graph_id=active_graph.graph_id,
                    generation=active_graph.generation,
                    graph_state_getter=self._graph_state_getter(session, active_graph.graph_id),
                    reopen_fn=reopen_cb,
                )
            else:
                active_graph.refetchable_tree = RefetchableTree(
                    nodes,
                    session.invalidation_monitor,
                    ax_window=root_ref,
                    target_pid=t.pid,
                    walk_fn=refetch_walk,
                    graph_id=active_graph.graph_id,
                    generation=active_graph.generation,
                    graph_state_getter=self._graph_state_getter(session, active_graph.graph_id),
                    reopen_fn=reopen_cb,
                )
            session.refetchable_tree = active_graph.refetchable_tree
        elif session.refetchable_tree is not None:
            session.refetchable_tree.update(
                nodes,
                ax_window=t.ax_window,
                monitor=session.invalidation_monitor,
                target_pid=t.pid,
                walk_fn=refetch_walk,
            )
        else:
            session.refetchable_tree = RefetchableTree(
                nodes,
                session.invalidation_monitor,
                ax_window=t.ax_window,
                target_pid=t.pid,
                walk_fn=refetch_walk,
            )
        # Step 10: Return ToolResponse
        if feature_flags.transient_graphs and active_graph is not None and active_graph.kind == GraphKind.TRANSIENT:
            self._dismiss_transient_surface(session, active_graph)

        return ToolResponse(
            app=t.bundle_id,
            pid=t.pid,
            snapshot_id=session.snapshot_id,
            window_title=window_title,
            tree_text=f"{header}\n\n{tree_text}",
            tree_nodes=nodes,
            focused_element=focused,
            screenshot=screenshot.image_to_base64(transport_img) if transport_img else None,
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

        # Validate window ownership — re-resolve stale window IDs without capturing
        from app._lib import skylight
        if not skylight.validate_window_owner(target.window_id, target.pid):
            logger.info("Window ID %d stale for pid %d, re-resolving", target.window_id, target.pid)
            candidates = [
                w for w in screenshot.list_windows(owner_pid=target.pid)
                if w.onscreen and w.width > 0 and w.height > 0
            ]
            if candidates:
                candidates.sort(key=lambda w: w.width * w.height, reverse=True)
                new_wid = candidates[0].window_id
                if new_wid != target.window_id:
                    logger.info("Window ID re-resolved: %d -> %d", target.window_id, new_wid)
                    target = AppTarget(
                        pid=target.pid,
                        bundle_id=target.bundle_id,
                        window_id=new_wid,
                        window_pid=target.window_pid,
                        ax_app=target.ax_app,
                        ax_window=target.ax_window,
                    )
                    session.target = target

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
        """Click via background CGEvent, with AX fallbacks only as a last resort.

        By element: CGEventPostToPid first, then AX recovery if background delivery fails.
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
            prefer_pointer = self._should_prefer_pointer_input(session, node)
            if not prefer_pointer:
                ax_result = self._try_ax_click_node(
                    session, node, idx, button=button, count=count,
                )
                if ax_result is not None:
                    return ax_result
                hit_result = self._try_ax_hit_test_click(
                    session, node, idx, button=button, count=count,
                )
                if hit_result is not None:
                    return hit_result
            if self._background_click_node(session, node, button=button, count=count):
                return f"Clicked element {idx} (CGEventPostToPid)"
            if prefer_pointer:
                hit_result = self._try_ax_hit_test_click(
                    session, node, idx, button=button, count=count,
                )
                if hit_result is not None:
                    return hit_result
                ax_result = self._try_ax_click_node(
                    session, node, idx, button=button, count=count,
                )
                if ax_result is not None:
                    return ax_result

            raise AutomationError(
                f"Click failed for element {idx}. "
                f"Try a different element or use perform_secondary_action."
            )

        elif x is not None and y is not None:
            sx, sy = self._to_screen_coords(session, t.window_id, float(x), float(y))
            ax_result = self._try_ax_hit_test_click_at_point(
                session,
                sx,
                sy,
                display_x=float(x),
                display_y=float(y),
                button=button,
                count=count,
            )
            if ax_result is not None:
                return ax_result

            # Pre-snapshot for delivery verdict (coord click path)
            before_snapshot_coord = self._capture_element_snapshot(session, None)

            try:
                transport_mark = 0
                if session.cgevent_outcome_monitor is not None:
                    _, transport_mark = session.cgevent_outcome_monitor.begin_action()
                notification_mark = (
                    session.ax_outcome_monitor.mark()
                    if session.ax_outcome_monitor is not None
                    else None
                )
                if feature_flags.confirmed_delivery and session.delivery_tap is not None:
                    from app._lib.input import deliver_click
                    from Quartz import CGPointMake
                    sx, sy = cg_input.window_to_screen_coords(
                        t.window_id, float(x), float(y), session.screenshot_size,
                    )
                    click_result = deliver_click(
                        pid=t.window_pid,
                        point=CGPointMake(sx, sy),
                        button=button,
                        count=count,
                        window_id=t.window_id,
                        source=session.event_source,
                        confirmation_tap=session.delivery_tap,
                    )
                else:
                    click_result = None
                    cg_input.click_at(
                        t.window_pid,
                        t.window_id,
                        float(x),
                        float(y),
                        button=button,
                        count=count,
                        screenshot_size=session.screenshot_size,
                        source=session.event_source,
                    )
                if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                    verification = self._verify_cgevent_contract(
                        session,
                        expectation=expectation_for_click(button, count),
                        transport_mark=transport_mark,
                        contract=VerificationContract(expect_transient_open=(button == "right")),
                        notification_mark=notification_mark,
                    )
                    if verification not in {
                        ActionVerificationResult.CONFIRMED,
                        ActionVerificationResult.TRANSIENT_OPENED,
                    }:
                        logger.info("click: verification timeout — action likely landed (AX lag)")
                from app._lib.confirmed_verification import ExpectedDiff
                after_snapshot_coord = self._capture_element_snapshot(session, None)
                self._compute_delivery_verdict(
                    session, before_snapshot_coord, after_snapshot_coord,
                    transport_confirmed=True,
                    fallback_used=False,
                    expected=ExpectedDiff.FOCUS_OR_LAYOUT,
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
                    transport_mark = 0
                    if session.cgevent_outcome_monitor is not None:
                        _, transport_mark = session.cgevent_outcome_monitor.begin_action()
                    notification_mark = (
                        session.ax_outcome_monitor.mark()
                        if session.ax_outcome_monitor is not None
                        else None
                    )
                    cg_input.click_at(
                        t.window_pid,
                        t.window_id,
                        float(x),
                        float(y),
                        button=button,
                        count=count,
                        screenshot_size=session.screenshot_size,
                        source=session.event_source,
                    )
                    if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                        verification = self._verify_cgevent_contract(
                            session,
                            expectation=expectation_for_click(button, count),
                            transport_mark=transport_mark,
                            contract=VerificationContract(expect_transient_open=(button == "right")),
                            notification_mark=notification_mark,
                        )
                        if verification not in {
                            ActionVerificationResult.CONFIRMED,
                            ActionVerificationResult.TRANSIENT_OPENED,
                        }:
                            raise InputError("Coordinate click had no observed effect after refresh")
                    from app._lib.confirmed_verification import ExpectedDiff
                    after_snapshot_coord = self._capture_element_snapshot(session, None)
                    self._compute_delivery_verdict(
                        session, before_snapshot_coord, after_snapshot_coord,
                        transport_confirmed=True,
                        fallback_used=False,
                        expected=ExpectedDiff.FOCUS_OR_LAYOUT,
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

            ax_result = self._try_ax_hit_test_click_at_point(
                session,
                sx,
                sy,
                display_x=float(x),
                display_y=float(y),
                button=button,
                count=count,
            )
            if ax_result is not None:
                return ax_result

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
            before_text = None
            if node.ax_role in ("AXTextField", "AXTextArea") and node.ax_ref is not None:
                try:
                    before_text = EditableTextObject(node.ax_ref, pid=node.element_pid).text
                except Exception:
                    before_text = None

            # Try EditableTextObject.insert_text for text elements
            if node.ax_role in ("AXTextField", "AXTextArea"):
                try:
                    mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                    eto = EditableTextObject(node.ax_ref, pid=node.element_pid)
                    eto.insert_text(text)
                    verification = self._verify_ax_contract(
                        session,
                        contract=VerificationContract(
                            direct_verifier=lambda: text in EditableTextObject(
                                node.ax_ref, pid=node.element_pid
                            ).text
                        ),
                        mark=mark,
                    )
                    if verification not in {
                        ActionVerificationResult.CONFIRMED,
                        ActionVerificationResult.TRANSIENT_OPENED,
                    }:
                        raise AutomationError("EditableTextObject.insertText had no observed effect")
                    return f"Typed {text!r} into element {el_idx} (EditableTextObject.insertText)"
                except Exception as e:
                    logger.debug("EditableTextObject.insertText failed for element %d: %s", el_idx, e)

            if not self._focus_node_for_keyboard_input(session, node):
                raise AutomationError(
                    f"Cannot target element {el_idx} for typing without activating the app. "
                    f"Try set_value instead."
                )

        input_pid = self._background_pid_for_node(session, node if el_idx is not None else None)
        transport_mark = 0
        if session.cgevent_outcome_monitor is not None:
            _, transport_mark = session.cgevent_outcome_monitor.begin_action()
        notification_mark = (
            session.ax_outcome_monitor.mark()
            if session.ax_outcome_monitor is not None
            else None
        )
        # Pre-snapshot for delivery verdict
        type_target_node = node if el_idx is not None else None
        before_snapshot_type = self._capture_element_snapshot(session, type_target_node)
        # Use confirmed delivery pipeline with mid-stream interruption
        if feature_flags.confirmed_delivery and session.delivery_tap is not None:
            from app._lib.input import deliver_type_text
            _interrupt_monitor = self._user_interaction_monitor
            _target_bid = session.target.bundle_id

            def _check_interrupted() -> bool:
                if not feature_flags.user_interruption_detection:
                    return False
                msg = _interrupt_monitor.check_interruption(_target_bid)
                return msg is not None

            deliver_type_text(
                pid=input_pid,
                text=text,
                source=session.event_source,
                confirmation_tap=session.delivery_tap,
                check_interrupted=_check_interrupted,
            )
        else:
            cg_input.type_text(input_pid, text, source=session.event_source)
        if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
            direct_verifier = None
            if el_idx is not None and node.ax_ref is not None:
                def _verifier() -> bool:
                    current = EditableTextObject(node.ax_ref, pid=node.element_pid).text
                    if before_text is None:
                        return text in current
                    return current != before_text
                direct_verifier = _verifier
            verification = self._verify_cgevent_contract(
                session,
                expectation=expectation_for_typing(),
                transport_mark=transport_mark,
                contract=VerificationContract(direct_verifier=direct_verifier),
                notification_mark=notification_mark,
            )
            if verification not in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_OPENED,
            }:
                # Check new ActionVerifier before raising — old monitor may false-negative
                after_snapshot_type = self._capture_element_snapshot(session, type_target_node)
                from app._lib.confirmed_verification import ExpectedDiff, DeliveryVerdict
                verdict = self._compute_delivery_verdict(
                    session, before_snapshot_type, after_snapshot_type,
                    transport_confirmed=True,
                    fallback_used=False,
                    expected=ExpectedDiff.VALUE_CHANGED,
                )
                if verdict not in {DeliveryVerdict.CONFIRMED, DeliveryVerdict.CONFIRMED_VIA_FALLBACK}:
                    logger.info("type_text: verification timeout — action likely landed (AX lag)")
                logger.debug("type_text: old monitor said no effect but ActionVerifier confirmed state change")
        else:
            after_snapshot_type = self._capture_element_snapshot(session, type_target_node)
            from app._lib.confirmed_verification import ExpectedDiff
            self._compute_delivery_verdict(
                session, before_snapshot_type, after_snapshot_type,
                transport_confirmed=True,
                fallback_used=False,
                expected=ExpectedDiff.VALUE_CHANGED,
            )
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
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                eto = EditableTextObject(node.ax_ref, pid=node.element_pid)
                if insert_mode:
                    eto.insert_text(value)
                    verification = self._verify_ax_contract(
                        session,
                        contract=VerificationContract(
                            direct_verifier=lambda: value in EditableTextObject(
                                node.ax_ref, pid=node.element_pid
                            ).text
                        ),
                        mark=mark,
                    )
                    if verification not in {
                        ActionVerificationResult.CONFIRMED,
                        ActionVerificationResult.TRANSIENT_OPENED,
                    }:
                        raise AutomationError("EditableTextObject.insertText had no observed effect")
                    return f"Inserted text into element {idx} (EditableTextObject.insertText)"
                else:
                    eto.set_text(value)
                    verification = self._verify_ax_contract(
                        session,
                        contract=VerificationContract(
                            direct_verifier=lambda: EditableTextObject(
                                node.ax_ref, pid=node.element_pid
                            ).text == value
                        ),
                        mark=mark,
                    )
                    if verification not in {
                        ActionVerificationResult.CONFIRMED,
                        ActionVerificationResult.TRANSIENT_OPENED,
                    }:
                        raise AutomationError("EditableTextObject.setText had no observed effect")
                    return f"Set value of element {idx} to {value!r} (EditableTextObject.setText)"
            except Exception as e:
                logger.debug("EditableTextObject failed for element %d: %s", idx, e)

        # --- Primary: Direct AX attribute set ---
        try:
            mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
            accessibility.set_attribute(node, "AXValue", value)
            verification = self._verify_ax_contract(
                session,
                contract=VerificationContract(
                    direct_verifier=lambda: EditableTextObject(node.ax_ref, pid=node.element_pid).text == value
                    if node.ax_ref is not None
                    else False
                ),
                mark=mark,
            )
            if verification not in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_OPENED,
            }:
                raise AutomationError("AXValue set had no observed effect")
            return f"Set value of element {idx} to {value!r} (AXValue)"
        except Exception as e:
            logger.debug("AXValue set failed for element %d: %s", idx, e)

        # --- Background focus + retry (avoid AXPress which can activate app) ---
        try:
            if self._background_click_node(session, node):
                time.sleep(0.05)
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                accessibility.set_attribute(node, "AXValue", value)
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(
                        direct_verifier=lambda: EditableTextObject(node.ax_ref, pid=node.element_pid).text == value
                        if node.ax_ref is not None
                        else False
                    ),
                    mark=mark,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    raise AutomationError("Focus + AXValue had no observed effect")
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
        node = None
        delivery_result = None

        if el_idx is not None:
            node = self._resolve_index(session, int(el_idx))

            ax_key_action = _KEY_TO_AX_ACTION.get(key.lower())
            if ax_key_action:
                try:
                    mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                    accessibility.perform_action(node, ax_key_action)
                    verification = self._verify_ax_contract(
                        session,
                        contract=VerificationContract(
                            expect_transient_close=(
                                key.lower() == "escape"
                                and session.transient_graph_tracker is not None
                                and session.transient_graph_tracker.has_active_transient
                            )
                        ),
                        mark=mark,
                    )
                    if verification not in {
                        ActionVerificationResult.CONFIRMED,
                        ActionVerificationResult.TRANSIENT_CLOSED,
                    }:
                        raise AutomationError(f"{ax_key_action} had no observed effect")
                    return f"Pressed {key} on element {el_idx} ({ax_key_action})"
                except Exception:
                    logger.debug("%s failed for element %s", ax_key_action, el_idx)

            if not self._focus_node_for_keyboard_input(session, node):
                raise AutomationError(
                    f"Cannot target element {el_idx} for key input without activating the app."
                )

        input_pid = self._background_pid_for_node(session, node if el_idx is not None else None)
        transport_mark = 0
        if session.cgevent_outcome_monitor is not None:
            _, transport_mark = session.cgevent_outcome_monitor.begin_action()
        notification_mark = (
            session.ax_outcome_monitor.mark()
            if session.ax_outcome_monitor is not None
            else None
        )
        # Pre-snapshot for delivery verdict
        target_node = node if el_idx is not None else None
        before_snapshot = self._capture_element_snapshot(session, target_node)

        # Resolve key to keycode + modifiers for delivery pipeline
        resolved_key = cg_input._coerce_text_key(key)
        if resolved_key == " ":
            resolved_key = "space"
        if resolved_key is None:
            resolved_key = key

        # Use confirmed delivery pipeline when tap is available and flag enabled
        if feature_flags.confirmed_delivery and session.delivery_tap is not None and session.input_strategy is not None:
            from app._lib.input import deliver_key_events
            from app._lib.keys import parse_key_combo
            try:
                keycode, modifiers = parse_key_combo(resolved_key)
            except ValueError as exc:
                raise AutomationError(str(exc)) from exc
            delivery_result = deliver_key_events(
                pid=input_pid,
                keycode=keycode,
                modifiers=modifiers,
                source=session.event_source,
                delivery_method=session.input_strategy.delivery_method,
                confirmation_tap=session.delivery_tap,
                activation_policy=session.input_strategy.activation_policy,
            )
            if not delivery_result.transport_confirmed:
                logger.warning("press_key transport not confirmed for %s", key)
        else:
            cg_input.press_key(input_pid, key, source=session.event_source)
        if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
            verification = self._verify_cgevent_contract(
                session,
                expectation=expectation_for_keypress(),
                transport_mark=transport_mark,
                contract=VerificationContract(
                    expect_transient_close=(
                        key.lower() == "escape"
                        and session.transient_graph_tracker is not None
                        and session.transient_graph_tracker.has_active_transient
                    )
                ),
                notification_mark=notification_mark,
            )
            if verification not in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_CLOSED,
            }:
                # Check new ActionVerifier before raising — old monitor may false-negative
                after_snapshot = self._capture_element_snapshot(session, target_node)
                from app._lib.confirmed_verification import ExpectedDiff, DeliveryVerdict
                verdict = self._compute_delivery_verdict(
                    session, before_snapshot, after_snapshot,
                    transport_confirmed=delivery_result.transport_confirmed if delivery_result is not None else True,
                    fallback_used=delivery_result.fallback_used if delivery_result is not None else False,
                    expected=ExpectedDiff.LAYOUT_OR_MENU,
                )
                if verdict not in {DeliveryVerdict.CONFIRMED, DeliveryVerdict.CONFIRMED_VIA_FALLBACK}:
                    logger.info("press_key: verification timeout — action likely landed (AX lag)")
                logger.debug("press_key: old monitor said no effect but ActionVerifier confirmed state change")
        else:
            # No old verification — still compute verdict for diagnostics
            after_snapshot = self._capture_element_snapshot(session, target_node)
            from app._lib.confirmed_verification import ExpectedDiff
            self._compute_delivery_verdict(
                session, before_snapshot, after_snapshot,
                transport_confirmed=delivery_result.transport_confirmed if delivery_result is not None else True,
                fallback_used=delivery_result.fallback_used if delivery_result is not None else False,
                expected=ExpectedDiff.LAYOUT_OR_MENU,
            )
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

        # Pre-snapshot for delivery verdict
        before_snapshot_drag = self._capture_element_snapshot(session, None)

        try:
            transport_mark = 0
            if session.cgevent_outcome_monitor is not None:
                _, transport_mark = session.cgevent_outcome_monitor.begin_action()
            notification_mark = (
                session.ax_outcome_monitor.mark()
                if session.ax_outcome_monitor is not None
                else None
            )
            cg_input.drag(
                t.window_pid,
                t.window_id,
                from_x,
                from_y,
                to_x,
                to_y,
                screenshot_size=session.screenshot_size,
                source=session.event_source,
            )
            if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                verification = self._verify_cgevent_contract(
                    session,
                    expectation=expectation_for_drag(),
                    transport_mark=transport_mark,
                    contract=VerificationContract(),
                    notification_mark=notification_mark,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    logger.info("drag: verification timeout — action likely landed (AX lag)")
        except InputError as exc:
            logger.debug("Drag failed for %s window %s: %s", t.bundle_id, t.window_id, exc)
            self._refresh_window(session)
            t = session.target
            transport_mark = 0
            if session.cgevent_outcome_monitor is not None:
                _, transport_mark = session.cgevent_outcome_monitor.begin_action()
            notification_mark = (
                session.ax_outcome_monitor.mark()
                if session.ax_outcome_monitor is not None
                else None
            )
            cg_input.drag(
                t.window_pid,
                t.window_id,
                from_x,
                from_y,
                to_x,
                to_y,
                screenshot_size=session.screenshot_size,
                source=session.event_source,
            )
            if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                verification = self._verify_cgevent_contract(
                    session,
                    expectation=expectation_for_drag(),
                    transport_mark=transport_mark,
                    contract=VerificationContract(),
                    notification_mark=notification_mark,
                )
                if verification not in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }:
                    logger.info("drag: verification timeout after refresh — action likely landed (AX lag)")

        # Post-snapshot and verdict (alongside existing verification)
        after_snapshot_drag = self._capture_element_snapshot(session, None)
        from app._lib.confirmed_verification import ExpectedDiff
        self._compute_delivery_verdict(
            session, before_snapshot_drag, after_snapshot_drag,
            transport_confirmed=True,
            fallback_used=False,
            expected=ExpectedDiff.FOCUS_OR_LAYOUT,
        )
        return f"Dragged from ({from_x}, {from_y}) to ({to_x}, {to_y})"

    def _handle_secondary_action(self, session: AppSession, params: dict) -> str:
        """Perform secondary action — pure AX."""
        idx = int(params["element_index"])
        node = self._resolve_index(session, idx)
        action = params["action"]
        active_graph = self._active_graph(session)
        source_graph_kind = active_graph.kind if active_graph is not None else GraphKind.PERSISTENT

        expect_transient_open = action in {"AXShowMenu", "AXShowDefaultUI", "AXShowAlternateUI"} or (
            action in {"AXPress", "AXPick"} and node.ax_role in {"AXMenuBarItem", "AXMenuButton", "AXPopUpButton"}
        )
        expect_transient_close = action in {"AXPick", "AXCancel"} and bool(
            session.transient_graph_tracker is not None and session.transient_graph_tracker.has_active_transient
        )
        direct_verifier = None
        if action == "AXScrollToVisible":
            direct_verifier = lambda: self._node_is_visible_in_window(
                session,
                self._refresh_live_node_from_ref(node),
            )
        contract = VerificationContract(
            expect_transient_open=expect_transient_open,
            expect_transient_close=expect_transient_close,
            allow_focus_change=action != "AXScrollToVisible",
            allow_value_change=action != "AXScrollToVisible",
            direct_verifier=direct_verifier,
        )

        # --- Primary: Direct AX action ---
        try:
            mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
            accessibility.perform_action(node, action)
            transient_source = None
            if expect_transient_open:
                transient_source = self._make_transient_source(
                    session,
                    node,
                    action_name=action,
                    reopen_fn=lambda resolved: _safe_perform_action(resolved, action),
                    graph_kind=source_graph_kind,
                )
            verification = self._verify_ax_contract(
                session,
                contract=contract,
                mark=mark,
                transient_source=transient_source,
            )
            if verification in {
                ActionVerificationResult.CONFIRMED,
                ActionVerificationResult.TRANSIENT_OPENED,
                ActionVerificationResult.TRANSIENT_CLOSED,
            }:
                return f"Performed {action!r} on element {idx}"
        except Exception as e:
            logger.debug("Action %s failed for element %d: %s", action, idx, e)

        # --- AXPress as generic fallback ---
        if action not in ("AXPress", "AXCancel") and action not in _STRICT_SECONDARY_ACTIONS:
            try:
                mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                accessibility.perform_action(node, "AXPress")
                transient_source = None
                if node.ax_role in {"AXMenuBarItem", "AXMenuButton", "AXPopUpButton"}:
                    transient_source = self._make_transient_source(
                        session,
                        node,
                        action_name="AXPress",
                        reopen_fn=lambda resolved: _safe_perform_action(resolved, "AXPress"),
                        graph_kind=source_graph_kind,
                    )
                verification = self._verify_ax_contract(
                    session,
                    contract=VerificationContract(
                        expect_transient_open=transient_source is not None,
                        expect_transient_close=expect_transient_close,
                    ),
                    mark=mark,
                    transient_source=transient_source,
                )
                if verification in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                    ActionVerificationResult.TRANSIENT_CLOSED,
                }:
                    return f"Performed AXPress on element {idx} (fallback for {action!r})"
            except Exception:
                logger.debug("AXPress fallback failed for element %d", idx)

        raise AutomationError(
            f"Action {action!r} failed on element {idx}. "
            f"Try a different action from the element's secondary_actions list."
        )

    def _handle_scroll(self, session: AppSession, params: dict) -> str:
        """Scroll using background-only methods with per-session method caching."""
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
            node = self._resolve_scroll_node(session, self._resolve_index(session, idx))
            scroll_point = self._scroll_point_for_node(node)
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

        prefer_ax = (
            session.input_strategy.should_use_ax_action(
                "scroll",
                is_web_area=bool(node and node.is_web_area),
            )
            if session.input_strategy is not None
            else True
        )
        ordered_methods = self._scroll_method_order(prefer_ax)

        for _ in range(pages):
            cached = session.scroll_method
            if cached is not None:
                if self._try_scroll_method(session, node, scroll_point, direction, cached):
                    continue
                session.scroll_method = None

            performed = False
            for method in ordered_methods:
                if self._try_scroll_method(session, node, scroll_point, direction, method):
                    session.scroll_method = method
                    performed = True
                    break
            if performed:
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

    def _node_supports_scroll(self, node: Node) -> bool:
        if node.role in _SCROLLABLE_DISPLAY_ROLES:
            return True
        if any(action in _DIRECTIONAL_SCROLL_ACTIONS for action in node.secondary_actions):
            return True
        return node.ax_ref is not None and accessibility.has_scrollbar_ref(node.ax_ref)

    def _iter_live_scroll_ancestors(self, node: Node):
        current = node.ax_ref
        depth = node.depth
        for _ in range(12):
            if current is None:
                break
            parent = accessibility.get_parent_ref(current)
            if parent is None:
                break
            depth = max(0, depth - 1)
            current = parent
            yield accessibility.node_from_ref(parent, depth=depth)

    def _resolve_scroll_node(self, session: AppSession, node: Node) -> Node:
        if self._node_supports_scroll(node):
            return node
        for ancestor in self._iter_live_scroll_ancestors(node):
            if self._node_supports_scroll(ancestor):
                return ancestor
        for ancestor in self._iter_node_ancestors(session, node) or []:
            if self._node_supports_scroll(ancestor):
                return ancestor
        return node

    def _scroll_point_for_node(self, node: Node) -> tuple[float, float] | None:
        frame = accessibility.get_element_frame(node)
        if frame is None:
            return None
        return (frame[0] + frame[2] / 2, frame[1] + frame[3] / 2)

    def _scroll_method_order(self, prefer_ax: bool) -> list[str]:
        if prefer_ax:
            return ["scrollbar", "ax", "pixel", "pid"]
        return ["pixel", "pid", "ax", "scrollbar"]

    def _try_scroll_method(
        self,
        session: AppSession,
        node: Node | None,
        point: tuple[float, float] | None,
        direction: str,
        method: str,
    ) -> bool:
        if method == "ax" and node is not None:
            return self._try_ax_scroll(session, node, direction)
        if method == "scrollbar" and node is not None:
            return self._try_scrollbar_fallback(node, direction)
        if method == "pixel" and point is not None:
            return self._try_pid_pixel_scroll(session, node, point, direction)
        if method == "pid" and point is not None:
            return self._try_pid_scroll(session, node, point, direction)
        return False

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

        candidates = [node]
        candidates.extend(self._iter_live_scroll_ancestors(node))
        candidates.extend(self._iter_node_ancestors(session, node) or [])
        before = self._get_scroll_witness(session, node)

        for candidate in candidates:
            action_names = (
                accessibility.get_action_names_for_ref(candidate.ax_ref)
                if candidate.ax_ref is not None
                else candidate.secondary_actions
            )
            # Try page-level actions (only if listed)
            for action in ax_page_actions:
                if action in action_names:
                    try:
                        mark = session.ax_outcome_monitor.mark() if session.ax_outcome_monitor is not None else None
                        accessibility.perform_action(candidate, action)
                        verification = self._verify_ax_contract(
                            session,
                            contract=VerificationContract(
                                direct_verifier=lambda: self._scroll_changed(session, node, before)
                            ),
                            mark=mark,
                        )
                        if verification in {
                            ActionVerificationResult.CONFIRMED,
                            ActionVerificationResult.TRANSIENT_OPENED,
                        }:
                            return True
                    except Exception as e:
                        logger.debug("AX scroll %s on %s failed: %s", action, candidate.ax_role, e)

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

    def _try_pid_pixel_scroll(
        self,
        session: AppSession,
        node: Node | None,
        point: tuple[float, float],
        direction: str,
    ) -> bool:
        try:
            before = self._get_scroll_witness(session, node)
            bounds = screenshot.get_window_bounds(session.target.window_id)
            is_vertical = direction in ("up", "down")
            span = bounds[3] if bounds is not None and is_vertical else bounds[2] if bounds is not None else 0
            pixels = max(SCROLL_PIXELS_MIN, int(span * SCROLL_PIXELS_PER_PAGE_RATIO))
            transport_mark = 0
            if session.cgevent_outcome_monitor is not None:
                _, transport_mark = session.cgevent_outcome_monitor.begin_action()
            notification_mark = (
                session.ax_outcome_monitor.mark()
                if session.ax_outcome_monitor is not None
                else None
            )
            scroll_pid = self._background_pid_for_node(session, node)
            if feature_flags.confirmed_delivery and session.delivery_tap is not None:
                from app._lib.input import deliver_scroll
                scroll_result = deliver_scroll(
                    pid=scroll_pid,
                    direction=direction,
                    pixels=pixels,
                    source=session.event_source,
                    confirmation_tap=session.delivery_tap,
                )
                if not scroll_result.transport_confirmed:
                    logger.debug("scroll_pid_pixel transport not confirmed")
            else:
                cg_input.scroll_pid_pixel(
                    scroll_pid,
                    point[0],
                    point[1],
                    direction,
                    pixels,
                    window_id=session.target.window_id,
                    source=session.event_source,
                )
            if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                verification = self._verify_cgevent_contract(
                    session,
                    expectation=expectation_for_scroll(),
                    transport_mark=transport_mark,
                    contract=VerificationContract(
                        direct_verifier=lambda: self._scroll_changed(session, node, before)
                    ),
                    notification_mark=notification_mark,
                )
                return verification in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }
            return True
        except Exception as e:
            logger.debug("CGEventPostToPid pixel scroll failed: %s", e)
            return False

    def _try_pid_scroll(
        self,
        session: AppSession,
        node: Node | None,
        point: tuple[float, float],
        direction: str,
    ) -> bool:
        """Scroll via CGEventPostToPid — truly background, no cursor movement."""
        try:
            before = self._get_scroll_witness(session, node)
            transport_mark = 0
            if session.cgevent_outcome_monitor is not None:
                _, transport_mark = session.cgevent_outcome_monitor.begin_action()
            notification_mark = (
                session.ax_outcome_monitor.mark()
                if session.ax_outcome_monitor is not None
                else None
            )
            cg_input.scroll_pid(
                self._background_pid_for_node(session, node),
                point[0],
                point[1],
                direction,
                clicks=SCROLL_CLICKS_PER_PAGE,
                window_id=session.target.window_id,
                source=session.event_source,
            )
            if feature_flags.cgevent_action_verification and session.cgevent_outcome_monitor is not None:
                verification = self._verify_cgevent_contract(
                    session,
                    expectation=expectation_for_scroll(),
                    transport_mark=transport_mark,
                    contract=VerificationContract(
                        direct_verifier=lambda: self._scroll_changed(session, node, before)
                    ),
                    notification_mark=notification_mark,
                )
                return verification in {
                    ActionVerificationResult.CONFIRMED,
                    ActionVerificationResult.TRANSIENT_OPENED,
                }
            return True
        except Exception as e:
            logger.debug("CGEventPostToPid scroll failed: %s", e)
            return False

    def _resolve_index(self, session: AppSession, idx: int) -> Node:
        if feature_flags.transient_graphs:
            active_graph = self._active_graph(session)
            if (
                active_graph is not None
                and active_graph.kind == GraphKind.TRANSIENT
                and session.transient_graph_tracker is not None
                and not session.transient_graph_tracker.is_root_live(active_graph.root_ref)
            ):
                active_graph.state = GraphState.CLOSED
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
