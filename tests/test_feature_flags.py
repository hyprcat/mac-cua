"""Tests for feature flag toggling in the pipeline.

Verifies that disabling each feature flag correctly disables
its corresponding feature in the execute() pipeline.
"""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from app._lib.flags import FeatureFlags
from app._lib.errors import AutomationError
from app.response import Node, ToolResponse
from app.session import AppSession, AppTarget, SessionManager


def _make_session() -> AppSession:
    return AppSession(
        target=AppTarget(
            bundle_id="com.example.App",
            pid=111,
            window_id=77,
            window_pid=111,
            ax_app=object(),
            ax_window=object(),
        )
    )


def _stub_response() -> ToolResponse:
    return ToolResponse(app="com.example.App", pid=111, snapshot_id=1, tree_text="h\n\nt")


class TestFocusEnforcementFlag(unittest.TestCase):
    def test_disabled_skips_focus_activation(self) -> None:
        with patch("app.session.feature_flags") as flags:
            flags.focus_enforcement = False
            flags.menu_tracking = True
            flags.user_interruption_detection = False
            flags.tree_pruning = True
            flags.web_content_extraction = False
            flags.system_selection = False
            flags.screen_capture_kit = False
            flags.screenshot_classifier = False
            flags.rich_text_markdown = False

            manager = SessionManager()
            session = _make_session()

            with (
                patch.object(manager, "_resolve_session", return_value=session),
                patch.object(manager, "_ensure_trackers_started"),
                patch.object(manager, "_check_safety"),
                patch.object(manager, "_check_approval"),
                patch.object(manager._lifecycle, "track_app_used"),
                patch.object(manager._lifecycle, "increment_step"),
                patch.object(manager._lifecycle, "check_step_limit", return_value=False),
                patch.object(manager, "_activate_focus_enforcement") as focus_mock,
                patch.object(manager, "_dispatch", return_value="ok"),
                patch("app.session.wait_for_settle"),
                patch.object(manager, "take_snapshot", return_value=_stub_response()),
                patch.object(manager, "_deactivate_focus_enforcement"),
                patch("app.session.analytics"),
            ):
                manager.execute("click", {"window_id": 77, "element_index": "0"})

            focus_mock.assert_not_called()


class TestUserInterruptionFlag(unittest.TestCase):
    def test_disabled_skips_interruption_monitoring(self) -> None:
        with patch("app.session.feature_flags") as flags:
            flags.focus_enforcement = True
            flags.user_interruption_detection = False
            flags.menu_tracking = False
            flags.tree_pruning = True
            flags.web_content_extraction = False
            flags.system_selection = False
            flags.screen_capture_kit = False
            flags.screenshot_classifier = False
            flags.rich_text_markdown = False

            manager = SessionManager()
            session = _make_session()

            with (
                patch.object(manager, "_resolve_session", return_value=session),
                patch.object(manager, "_ensure_trackers_started"),
                patch.object(manager, "_check_safety"),
                patch.object(manager, "_check_approval"),
                patch.object(manager._lifecycle, "track_app_used"),
                patch.object(manager._lifecycle, "increment_step"),
                patch.object(manager._lifecycle, "check_step_limit", return_value=False),
                patch.object(manager, "_activate_focus_enforcement"),
                patch.object(manager, "_dispatch", return_value="ok"),
                patch("app.session.wait_for_settle"),
                patch.object(manager, "take_snapshot", return_value=_stub_response()),
                patch.object(manager, "_deactivate_focus_enforcement"),
                patch.object(manager._user_interaction_monitor, "start_monitoring") as start_mock,
                patch("app.session.analytics"),
            ):
                manager.execute("click", {"window_id": 77, "element_index": "0"})

            start_mock.assert_not_called()


class TestTreePruningFlag(unittest.TestCase):
    def test_pruning_flag_passed_to_serialize(self) -> None:
        from app._lib.flags import FeatureFlags

        # When tree_pruning=False, serialize should be called with enable_pruning=False
        flags = FeatureFlags(tree_pruning=False)
        with patch("app.session.feature_flags", flags):
            with patch("app.session.serialize") as serialize_mock:
                serialize_mock.return_value = "tree text"
                manager = SessionManager()
                session = _make_session()

                with (
                    patch.object(manager, "_refresh_window"),
                    patch("app.session.accessibility.walk_tree", return_value=[]),
                    patch.object(manager, "_capture_screenshot", return_value=MagicMock()),
                    patch("app.session.accessibility.get_focused_element", return_value=None),
                    patch.object(manager, "_build_app_state", return_value=None),
                    patch.object(manager, "_get_window_title", return_value="Test"),
                    patch("app.session.make_header", return_value="header"),
                    patch("app.session.screenshot.image_to_base64", return_value="base64"),
                    patch.object(manager, "_update_application_window"),
                ):
                    manager.take_snapshot(session)

                serialize_mock.assert_called_once()
                _, kwargs = serialize_mock.call_args
                self.assertFalse(kwargs.get("enable_pruning", True))


class TestScreenCaptureKitFlag(unittest.TestCase):
    def test_disabled_skips_sck(self) -> None:
        flags = FeatureFlags(screen_capture_kit=False)
        with patch("app.session.feature_flags", flags):
            manager = SessionManager()
            session = _make_session()
            target = session.target

            with (
                patch("app.session.is_sck_available", return_value=True) as sck_check,
                patch("app.session.get_screen_capture_worker") as sck_worker,
                patch("app.session.screenshot.capture_window", return_value=MagicMock()),
            ):
                result = manager._capture_screenshot(session, target)

            # SCK should not be attempted when flag is disabled
            sck_worker.assert_not_called()


class TestFeatureFlagLoading(unittest.TestCase):
    def test_env_var_override(self) -> None:
        with patch.dict("os.environ", {"MAC_CUA_FLAG_TREE_PRUNING": "0"}):
            flags = FeatureFlags.load()
            self.assertFalse(flags.tree_pruning)

    def test_is_enabled_method(self) -> None:
        flags = FeatureFlags(tree_pruning=True, focus_enforcement=False)
        self.assertTrue(flags.is_enabled("tree_pruning"))
        self.assertFalse(flags.is_enabled("focus_enforcement"))
        self.assertFalse(flags.is_enabled("nonexistent_flag"))

    def test_defaults_are_sensible(self) -> None:
        flags = FeatureFlags()
        # Default-on features
        self.assertTrue(flags.tree_pruning)
        self.assertTrue(flags.focus_enforcement)
        self.assertTrue(flags.user_interruption_detection)
        self.assertTrue(flags.screen_capture_kit)
        # Default-off features
        self.assertFalse(flags.always_simulate_click)
        self.assertFalse(flags.screenshot_classifier)
        self.assertFalse(flags.allow_forbidden_targets)


if __name__ == "__main__":
    unittest.main()
