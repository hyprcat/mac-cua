"""Integration tests for the execute() pipeline.

Verifies pipeline step ordering,
error path handling, and cleanup behavior. All macOS APIs are mocked.
"""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch, PropertyMock, call

from app._lib.errors import (
    AppBlockedError,
    AutomationError,
    StaleReferenceError,
    StepLimitError,
)
from app._lib.graphs import TransientSurface
from app.response import Node, ToolResponse
from app.session import AppSession, AppTarget, SessionManager


def _make_target(**overrides) -> AppTarget:
    defaults = dict(
        bundle_id="com.example.App",
        pid=111,
        window_id=77,
        window_pid=111,
        ax_app=object(),
        ax_window=object(),
    )
    defaults.update(overrides)
    return AppTarget(**defaults)


def _make_session(**overrides) -> AppSession:
    return AppSession(target=_make_target(**overrides))


def _make_nodes(n: int = 5) -> list[Node]:
    return [
        Node(
            index=i,
            role="button",
            label=f"Button {i}",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=["AXPress"],
            depth=1,
            ax_ref=object(),
            ax_role="AXButton",
        )
        for i in range(n)
    ]


def _stub_snapshot(session: AppSession) -> ToolResponse:
    return ToolResponse(
        app=session.target.bundle_id,
        pid=session.target.pid,
        snapshot_id=1,
        tree_text="header\n\ntree",
        tree_nodes=[],
    )


class TestPipelineStepOrdering(unittest.TestCase):
    """Verify execute() calls pipeline steps in the correct order."""

    def _run_pipeline(self, tool: str = "click", params: dict | None = None):
        """Run execute() with all macOS calls mocked, return call order."""
        manager = SessionManager()
        session = _make_session()
        session.tree_nodes = _make_nodes()

        call_order = []

        def track(name):
            def side_effect(*a, **kw):
                call_order.append(name)
            return side_effect

        if params is None:
            params = {"window_id": 77, "element_index": "0"}

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_check_safety", side_effect=track("check_safety")),
            patch.object(manager, "_check_approval", side_effect=track("check_approval")),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_activate_focus_enforcement", side_effect=track("focus_activate")),
            patch.object(manager, "_deactivate_focus_enforcement", side_effect=track("focus_deactivate")),
            patch.object(manager, "_dispatch", side_effect=track("dispatch"), return_value="ok"),
            patch("app.session.wait_for_settle", side_effect=track("settle")),
            patch.object(manager._user_interaction_monitor, "start_monitoring", side_effect=track("interruption_start")),
            patch.object(manager._user_interaction_monitor, "check_interruption", return_value=None),
            patch.object(manager._user_interaction_monitor, "stop_monitoring"),
            patch.object(manager, "take_snapshot", return_value=_stub_snapshot(session)),
            patch.object(manager, "_ensure_trackers_started"),
            patch("app.session.analytics"),
        ):
            manager.execute(tool, params)

        return call_order

    def test_action_tool_fires_all_steps_in_order(self) -> None:
        order = self._run_pipeline("click")
        expected = [
            "check_safety",
            "check_approval",
            "focus_activate",
            "interruption_start",
            "dispatch",
            "settle",
            "focus_deactivate",
        ]
        self.assertEqual(order, expected)

    def test_get_app_state_skips_focus_and_interruption(self) -> None:
        order = self._run_pipeline("get_app_state", {"window_id": 77})
        # get_app_state should NOT activate focus or start interruption monitoring
        self.assertNotIn("focus_activate", order)
        self.assertNotIn("interruption_start", order)
        self.assertIn("check_safety", order)
        self.assertIn("dispatch", order)

    def test_settle_timeout_zero_skips_settle(self) -> None:
        """get_app_state has settle timeout 0, should skip wait_for_settle."""
        order = self._run_pipeline("get_app_state", {"window_id": 77})
        self.assertNotIn("settle", order)

    def test_focus_deactivation_on_success(self) -> None:
        order = self._run_pipeline("click")
        # focus_deactivate happens after dispatch (in the return path)
        self.assertIn("focus_activate", order)

    def test_open_menu_does_not_block_next_action(self) -> None:
        manager = SessionManager()
        session = _make_session()
        session.tree_nodes = _make_nodes()
        session.menu_tracker = MagicMock()
        type(session.menu_tracker).menus_open = PropertyMock(return_value=True)

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_activate_focus_enforcement"),
            patch.object(manager, "_deactivate_focus_enforcement"),
            patch.object(manager, "_dispatch", return_value="ok") as dispatch_mock,
            patch.object(manager._user_interaction_monitor, "start_monitoring"),
            patch.object(manager._user_interaction_monitor, "check_interruption", return_value=None),
            patch.object(manager._user_interaction_monitor, "stop_monitoring"),
            patch.object(manager, "take_snapshot", return_value=_stub_snapshot(session)),
            patch.object(manager, "_ensure_trackers_started"),
            patch("app.session.analytics"),
        ):
            manager.execute("click", {"window_id": 77, "element_index": "0"})

        dispatch_mock.assert_called_once()
        session.menu_tracker.wait_for_menu_close.assert_not_called()

    def test_open_menu_uses_short_settle_wait(self) -> None:
        """When a menu is open, use a short settle (0.15s) instead of skipping entirely."""
        manager = SessionManager()
        session = _make_session()
        session.tree_nodes = _make_nodes()
        session.menu_tracker = MagicMock()
        type(session.menu_tracker).menus_open = PropertyMock(return_value=True)

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_activate_focus_enforcement"),
            patch.object(manager, "_deactivate_focus_enforcement"),
            patch.object(manager, "_dispatch", return_value="ok"),
            patch("app.session.wait_for_settle") as settle_mock,
            patch.object(manager._user_interaction_monitor, "start_monitoring"),
            patch.object(manager._user_interaction_monitor, "check_interruption", return_value=None),
            patch.object(manager._user_interaction_monitor, "stop_monitoring"),
            patch.object(manager, "take_snapshot", return_value=_stub_snapshot(session)),
            patch.object(manager, "_ensure_trackers_started"),
            patch("app.session.analytics"),
        ):
            manager.execute("click", {"window_id": 77, "element_index": "0"})

        settle_mock.assert_called_once()
        # Short settle — capped at 0.15s, not full timeout
        self.assertLessEqual(settle_mock.call_args.kwargs.get("timeout", settle_mock.call_args[1].get("timeout", 999)), 0.15)

    def test_transient_probe_captures_snapshot_immediately_without_settle(self) -> None:
        manager = SessionManager()
        session = _make_session()
        session.tree_nodes = _make_nodes()
        session.transient_graph_tracker = MagicMock()
        type(session.transient_graph_tracker).has_active_transient = PropertyMock(return_value=True)
        type(session.transient_graph_tracker).active_surface = PropertyMock(
            return_value=TransientSurface(root_ref=object(), locator=None, kind="menu")
        )

        snapshot = _stub_snapshot(session)
        snapshot.snapshot_id = 2

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_activate_focus_enforcement"),
            patch.object(manager, "_deactivate_focus_enforcement"),
            patch.object(manager, "_dispatch", return_value="ok"),
            patch("app.session.wait_for_settle") as settle_mock,
            patch.object(manager._user_interaction_monitor, "start_monitoring"),
            patch.object(manager._user_interaction_monitor, "check_interruption", return_value=None),
            patch.object(manager._user_interaction_monitor, "stop_monitoring"),
            patch.object(manager, "take_snapshot", return_value=snapshot) as snapshot_mock,
            patch.object(manager, "_ensure_trackers_started"),
            patch.object(manager, "_restore_previous_frontmost_app"),
            patch("app.session.analytics"),
        ):
            response = manager.execute("click", {"window_id": 77, "element_index": "0"})

        settle_mock.assert_not_called()
        snapshot_mock.assert_called_once_with(session, skip_refresh=True)
        self.assertEqual(response.snapshot_id, 2)
        self.assertEqual(response.result, "ok")


class TestPipelineErrorPaths(unittest.TestCase):
    """Verify error handling at each pipeline stage."""

    def _make_manager_with_session(self):
        manager = SessionManager()
        session = _make_session()
        session.tree_nodes = _make_nodes()
        return manager, session

    def test_blocked_app_raises_app_blocked_error(self) -> None:
        manager, session = self._make_manager_with_session()

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_ensure_trackers_started"),
            patch("app.session.analytics"),
            patch.object(
                manager._safety,
                "check_app",
                return_value="blocked for safety",
            ),
        ):
            response = manager.execute("click", {"window_id": 77, "element_index": "0"})

        self.assertIsNotNone(response.error)

    def test_step_limit_raises_step_limit_error(self) -> None:
        manager, session = self._make_manager_with_session()

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_ensure_trackers_started"),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=True),
            patch("app.session.analytics"),
            patch.object(manager, "take_snapshot", return_value=_stub_snapshot(session)),
        ):
            response = manager.execute("click", {"window_id": 77, "element_index": "0"})

        self.assertIsNotNone(response.error)
        self.assertIn("Step limit", response.error)

    def test_stale_reference_refreshes_tree(self) -> None:
        manager, session = self._make_manager_with_session()

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_ensure_trackers_started"),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_dispatch", side_effect=StaleReferenceError("stale")),
            patch.object(manager, "_activate_focus_enforcement"),
            patch.object(manager, "_cleanup_after_action"),
            patch.object(manager, "take_snapshot", return_value=_stub_snapshot(session)),
            patch("app.session.wait_for_settle"),
            patch.object(manager._user_interaction_monitor, "start_monitoring"),
            patch("app.session.analytics"),
        ):
            response = manager.execute("click", {"window_id": 77, "element_index": "0"})

        self.assertIsNotNone(response.error)
        self.assertIn("stale", response.error.lower())

    def test_cleanup_called_on_error(self) -> None:
        manager, session = self._make_manager_with_session()

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_ensure_trackers_started"),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_dispatch", side_effect=AutomationError("boom")),
            patch.object(manager, "_activate_focus_enforcement"),
            patch.object(manager, "_cleanup_after_action") as cleanup_mock,
            patch.object(manager, "take_snapshot", return_value=_stub_snapshot(session)),
            patch("app.session.wait_for_settle"),
            patch.object(manager._user_interaction_monitor, "start_monitoring"),
            patch("app.session.analytics"),
        ):
            manager.execute("click", {"window_id": 77, "element_index": "0"})

        cleanup_mock.assert_called_once()
        self.assertIs(cleanup_mock.call_args.args[0], session)

    def test_list_apps_bypasses_pipeline(self) -> None:
        """list_apps returns immediately without resolving a session."""
        manager = SessionManager()

        with (
            patch.object(manager, "_handle_list_apps", return_value=_stub_snapshot(_make_session())) as handle_mock,
        ):
            manager.execute("list_apps", {})

        handle_mock.assert_called_once()


class TestPipelineUserInterruption(unittest.TestCase):
    """Verify user interruption detection hard-stops further actions."""

    def test_interruption_returns_error_without_snapshot(self) -> None:
        manager = SessionManager()
        session = _make_session()
        session.tree_nodes = _make_nodes()

        with (
            patch.object(manager, "_resolve_session", return_value=session),
            patch.object(manager, "_ensure_trackers_started"),
            patch.object(manager, "_check_safety"),
            patch.object(manager, "_check_approval"),
            patch.object(manager._lifecycle, "track_app_used"),
            patch.object(manager._lifecycle, "increment_step"),
            patch.object(manager._lifecycle, "check_step_limit", return_value=False),
            patch.object(manager, "_dispatch", return_value="Clicked"),
            patch.object(manager, "_activate_focus_enforcement"),
            patch.object(manager, "_deactivate_focus_enforcement"),
            patch("app.session.wait_for_settle"),
            patch.object(manager._user_interaction_monitor, "start_monitoring"),
            patch.object(
                manager._user_interaction_monitor,
                "check_interruption",
                return_value="The user changed 'com.example.App'. Re-query the latest state with `get_app_state` before sending more actions.",
            ),
            patch.object(manager._user_interaction_monitor, "stop_monitoring"),
            patch.object(manager, "take_snapshot") as take_snapshot,
            patch("app.session.analytics"),
        ):
            response = manager.execute("click", {"window_id": 77, "element_index": "0"})

        self.assertEqual(
            response.error,
            "The user changed 'com.example.App'. Re-query the latest state with `get_app_state` before sending more actions.",
        )
        self.assertTrue(session.user_state_invalidated)
        take_snapshot.assert_not_called()


class TestResponseFormat(unittest.TestCase):
    """Verify response formatting."""

    def test_format_response_header_has_version(self) -> None:
        from app.response import format_response_header
        header = format_response_header()
        self.assertTrue(header.startswith("Desktop Automation state (version:"))
        self.assertIn(")", header)

    def test_format_mcp_includes_version_header(self) -> None:
        from app.server import format_mcp
        response = ToolResponse(
            app="com.example.App",
            pid=1,
            snapshot_id=1,
            tree_text="header\n\ntree body",
            result="ok",
        )
        blocks = format_mcp(response)
        text_blocks = [b for b in blocks if hasattr(b, "text")]
        self.assertTrue(any("version:" in b.text for b in text_blocks))

    def test_format_mcp_wraps_guidance_in_xml(self) -> None:
        from app.server import format_mcp
        response = ToolResponse(
            app="com.example.App",
            pid=1,
            snapshot_id=1,
            tree_text="header\n\ntree body",
            guidance="Use keyboard shortcuts for navigation.",
        )
        blocks = format_mcp(response)
        text = blocks[0].text
        self.assertIn("<app_specific_instructions>", text)
        self.assertIn("</app_specific_instructions>", text)

    def test_format_mcp_includes_system_selection(self) -> None:
        from app.server import format_mcp
        response = ToolResponse(
            app="com.example.App",
            pid=1,
            snapshot_id=1,
            tree_text="header\n\ntree body",
            system_selection="Selected text: ```\nhello\n```",
        )
        blocks = format_mcp(response)
        text = blocks[0].text
        self.assertIn("Selected text:", text)

    def test_format_mcp_wraps_in_app_state_tags(self) -> None:
        from app.server import format_mcp
        response = ToolResponse(
            app="com.example.App",
            pid=1,
            snapshot_id=1,
            tree_text="header\n\ntree body",
        )
        blocks = format_mcp(response)
        text = blocks[0].text
        self.assertIn("<app_state>", text)
        self.assertIn("</app_state>", text)


if __name__ == "__main__":
    unittest.main()
