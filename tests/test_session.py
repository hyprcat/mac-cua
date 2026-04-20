from __future__ import annotations

import unittest
from unittest.mock import patch, sentinel

from app._lib.apps import AppInfo
from app._lib.errors import AutomationError
from app._lib.screenshot import WindowInfo
from app.session import (
    AppSession,
    AppTarget,
    SessionManager,
)


class SessionManagerTests(unittest.TestCase):
    def test_resolve_session_prefers_window_id_over_app(self) -> None:
        manager = SessionManager()

        with (
            patch.object(manager, "get_or_create_session_for_window", return_value=sentinel.window_session) as by_window,
            patch.object(manager, "get_or_create_session", return_value=sentinel.app_session) as by_app,
        ):
            result = manager._resolve_session("click", {"window_id": 44, "app": "ignored"})

        self.assertIs(result, sentinel.window_session)
        by_window.assert_called_once_with(44)
        by_app.assert_not_called()

    def test_resolve_session_requires_window_id_or_app(self) -> None:
        manager = SessionManager()

        with self.assertRaisesRegex(
            AutomationError,
            "requires window_id or app",
        ):
            manager._resolve_session("click", {})

    def test_get_or_create_session_for_window_reuses_existing_session(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.App",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )
        manager._sessions[77] = session

        with patch("app.session.screenshot.get_window_pid", return_value=222):
            result = manager.get_or_create_session_for_window(77)

        self.assertIs(result, session)
        self.assertEqual(session.target.window_pid, 222)

    def test_get_or_create_session_for_window_falls_back_across_running_apps(self) -> None:
        manager = SessionManager()
        fallback_ax_app = object()
        fallback_ax_window = object()

        with (
            patch("app.session.screenshot.get_window_pid", return_value=222),
            patch("app.session.apps.resolve_running_app_by_pid", return_value=None),
            patch("app.session.apps.get_ax_app_for_pid", return_value=(object(), 222)),
            patch.object(manager, "_find_ax_window_for_window_id", return_value=None),
            patch.object(
                manager,
                "_find_window_across_running_apps",
                return_value=("com.example.Helper", 333, fallback_ax_app, fallback_ax_window),
            ),
        ):
            session = manager.get_or_create_session_for_window(88)

        self.assertEqual(session.target.bundle_id, "com.example.Helper")
        self.assertEqual(session.target.pid, 333)
        self.assertEqual(session.target.window_id, 88)
        self.assertEqual(session.target.window_pid, 222)
        self.assertIs(session.target.ax_app, fallback_ax_app)
        self.assertIs(session.target.ax_window, fallback_ax_window)
        self.assertIs(manager._sessions[88], session)

    def test_handle_list_apps_includes_window_ids_for_running_apps(self) -> None:
        manager = SessionManager()
        running = [
            AppInfo(
                name="Code",
                bundle_id="com.microsoft.VSCode",
                pid=123,
                running=True,
            )
        ]
        windows = [
            WindowInfo(
                window_id=9001,
                owner_pid=123,
                owner_name="Code",
                title="workspace",
                x=10,
                y=20,
                width=800,
                height=600,
                onscreen=True,
            )
        ]

        with (
            patch("app.session.apps.list_running_apps", return_value=running),
            patch("app.session.apps.list_recent_apps", return_value=[]),
            patch("app.session.screenshot.list_windows", return_value=windows),
        ):
            response = manager._handle_list_apps()

        self.assertIsNotNone(response.result)
        assert response.result is not None
        self.assertIn("pid=123", response.result)
        self.assertIn("window_id=9001", response.result)
        self.assertIn("window_pid=123", response.result)

    def test_get_or_create_session_reuses_cached_session_from_app_hint(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.finder",
                pid=123,
                window_id=55,
                window_pid=123,
                ax_app=object(),
                ax_window=object(),
            )
        )
        manager._sessions[55] = session
        manager._bundle_to_window["com.apple.finder"] = 55

        with (
            patch.object(manager, "_refresh_window") as refresh_window,
            patch("app.session.apps.resolve_app") as resolve_app,
        ):
            result = manager.get_or_create_session("Finder")

        self.assertIs(result, session)
        refresh_window.assert_called_once_with(session)
        resolve_app.assert_not_called()

    def test_get_or_create_session_uses_window_fallback_when_signature_matching_fails(self) -> None:
        manager = SessionManager()

        with (
            patch(
                "app.session.apps.resolve_app",
                return_value=AppInfo(
                    name="Finder",
                    bundle_id="com.apple.finder",
                    pid=123,
                    running=True,
                ),
            ),
            patch("app.session.apps.get_ax_app_for_bundle", return_value=(sentinel.ax_app, 123)),
            patch("app.session.accessibility.get_key_window", return_value=sentinel.ax_window),
            patch(
                "app.session.screenshot.find_window_id_for_ax_window",
                side_effect=[None, None],
            ) as find_window_id,
            patch(
                "app.session.screenshot.list_windows",
                return_value=[
                    WindowInfo(
                        window_id=1,
                        owner_pid=123,
                        owner_name="Finder",
                        title=None,
                        x=0,
                        y=0,
                        width=1920,
                        height=1080,
                        onscreen=True,
                    ),
                    WindowInfo(
                        window_id=2,
                        owner_pid=123,
                        owner_name="Finder",
                        title="Downloads",
                        x=100,
                        y=100,
                        width=1200,
                        height=800,
                        onscreen=True,
                    ),
                ],
            ),
            patch("app.session.screenshot.get_window_pid", return_value=123),
        ):
            session = manager.get_or_create_session("Finder")

        self.assertEqual(session.target.window_id, 2)
        self.assertEqual(session.target.window_pid, 123)
        self.assertEqual(find_window_id.call_count, 2)



if __name__ == "__main__":
    unittest.main()
