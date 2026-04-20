from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch, sentinel

from app._lib.action_verification import ActionVerificationResult, VerificationContract
from app._lib.apps import AppInfo
from app._lib.flags import FeatureFlags
from app._lib.errors import AutomationError, UserInterruptionError
from app._lib.graphs import TransientSurface
from app._lib.screenshot import WindowInfo
from app._lib.virtual_cursor import AppType, InputStrategy
from app.response import AppState, Node, Rect
from app.session import (
    AppSession,
    AppTarget,
    SessionManager,
)


class SessionManagerTests(unittest.TestCase):
    def test_resolve_session_prefers_window_id_over_app(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.App",
                pid=111,
                window_id=44,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )

        with (
            patch.object(manager, "get_or_create_session_for_window", return_value=session) as by_window,
            patch.object(manager, "get_or_create_session", return_value=sentinel.app_session) as by_app,
            patch.object(manager, "_ensure_session_observer_ready") as ensure_ready,
        ):
            result = manager._resolve_session("click", {"window_id": 44, "app": "ignored"})

        self.assertIs(result, session)
        by_window.assert_called_once_with(44)
        by_app.assert_not_called()
        ensure_ready.assert_called_once_with(session)

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

    def test_annotate_node_geometry_uses_transport_screenshot_space(self) -> None:
        manager = SessionManager()
        node = Node(
            index=0,
            role="button",
            label="Submit",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
        )
        app_state = AppState(
            bundle_id="com.example.App",
            is_active=True,
            is_running=True,
            window_title="Example",
            visible_rect=Rect(x=100.0, y=200.0, w=400.0, h=200.0),
        )

        with patch("app.session.accessibility.get_element_frame", return_value=(150.0, 250.0, 100.0, 40.0)):
            manager._annotate_node_geometry([node], app_state, (200, 100))

        self.assertIsNotNone(node.position)
        self.assertIsNotNone(node.size)
        assert node.position is not None
        assert node.size is not None
        self.assertEqual((node.position.x, node.position.y), (25.0, 25.0))
        self.assertEqual((node.size.w, node.size.h), (50.0, 20.0))

    def test_annotate_node_geometry_includes_labeled_text_for_grounding(self) -> None:
        manager = SessionManager()
        node = Node(
            index=0,
            role="text",
            label="Replay 2024",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
        )
        app_state = AppState(
            bundle_id="com.example.App",
            is_active=True,
            is_running=True,
            window_title="Example",
            visible_rect=Rect(x=100.0, y=200.0, w=400.0, h=200.0),
        )

        with patch("app.session.accessibility.get_element_frame", return_value=(120.0, 220.0, 80.0, 20.0)):
            manager._annotate_node_geometry([node], app_state, (200, 100))

        self.assertIsNotNone(node.position)
        self.assertIsNotNone(node.size)

    def test_handle_scroll_prefers_background_pixel_scroll_for_browser(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Browser",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.BROWSER),
            app_type=AppType.BROWSER,
        )
        node = Node(
            index=0,
            role="web area",
            label=None,
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            is_web_area=True,
            ax_role="AXWebArea",
        )

        with (
            patch.object(manager, "_resolve_index", return_value=node),
            patch.object(manager, "_scroll_point_for_node", return_value=(10.0, 20.0)),
            patch.object(manager, "_try_pid_pixel_scroll", return_value=True) as pixel_scroll,
            patch.object(manager, "_try_pid_scroll", return_value=False) as line_scroll,
            patch.object(manager, "_try_ax_scroll", return_value=False) as ax_scroll,
            patch.object(manager, "_try_scrollbar_fallback", return_value=False) as scrollbar_scroll,
        ):
            result = manager._handle_scroll(
                session,
                {"direction": "down", "pages": 1, "element_index": "0"},
            )

        self.assertEqual(result, "Scrolled element 0 down (1 page(s))")
        self.assertEqual(session.scroll_method, "pixel")
        pixel_scroll.assert_called_once_with(session, node, (10.0, 20.0), "down")
        line_scroll.assert_not_called()
        ax_scroll.assert_not_called()
        scrollbar_scroll.assert_not_called()

    def test_resolve_scroll_node_uses_live_parent_chain_when_tree_is_pruned(self) -> None:
        manager = SessionManager()
        leaf = Node(
            index=5,
            role="text",
            label="Privacy",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=3,
            ax_ref=sentinel.leaf_ref,
            ax_role="AXStaticText",
        )
        live_scroll_parent = Node(
            index=-1,
            role="group",
            label=None,
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=2,
            ax_ref=sentinel.scroll_parent_ref,
            ax_role="AXGroup",
        )
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            tree_nodes=[leaf],
        )

        with (
            patch("app.session.accessibility.has_scrollbar_ref", side_effect=lambda ref: ref is sentinel.scroll_parent_ref),
            patch.object(manager, "_iter_live_scroll_ancestors", return_value=iter([live_scroll_parent])),
        ):
            resolved = manager._resolve_scroll_node(session, leaf)

        self.assertIs(resolved, live_scroll_parent)

    def test_try_ax_scroll_uses_live_action_names(self) -> None:
        manager = SessionManager()
        node = Node(
            index=0,
            role="group",
            label=None,
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_ref=sentinel.scroll_ref,
            ax_role="AXScrollArea",
        )
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            tree_nodes=[node],
        )

        with (
            patch("app.session.accessibility.get_action_names_for_ref", return_value=["AXScrollDownByPage"]),
            patch("app.session.accessibility.perform_action") as perform_action,
            patch.object(manager, "_iter_live_scroll_ancestors", return_value=iter(())),
            patch.object(manager, "_scroll_changed", return_value=True),
        ):
            performed = manager._try_ax_scroll(session, node, "down")

        self.assertTrue(performed)
        perform_action.assert_called_once_with(node, "AXScrollDownByPage")

    def test_normalize_focused_index_falls_back_to_focused_state(self) -> None:
        manager = SessionManager()
        nodes = [
            Node(
                index=0,
                role="standard window",
                label="Code",
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=0,
                ax_role="AXWindow",
            ),
            Node(
                index=1,
                role="button",
                label="Explorer",
                states=["focused"],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=1,
                ax_role="AXButton",
            ),
        ]

        self.assertEqual(manager._normalize_focused_index(nodes, None), 1)

    def test_normalize_focused_index_prefers_web_area_ancestor_for_editor_focus(self) -> None:
        flags = FeatureFlags(codex_tree_style=True)
        manager = SessionManager()
        nodes = [
            Node(
                index=0,
                role="standard window",
                label="Code",
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=0,
                ax_role="AXWindow",
            ),
            Node(
                index=1,
                role="web area",
                label="workspace",
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=1,
                ax_role="AXWebArea",
                is_web_area=True,
            ),
            Node(
                index=2,
                role="text area",
                label="editor",
                states=["focused"],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=2,
                ax_role="AXTextArea",
            ),
        ]

        with patch("app.session.feature_flags", flags):
            self.assertEqual(manager._normalize_focused_index(nodes, 2), 1)

    def test_prune_tree_nodes_uses_codex_pruning_for_web_areas_and_injects_menu_bar(self) -> None:
        flags = FeatureFlags(codex_tree_style=True, tree_pruning=True)
        manager = SessionManager()
        nodes = [
            Node(
                index=0,
                role="standard window",
                label="Code",
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=0,
                ax_role="AXWindow",
            ),
            Node(
                index=1,
                role="web area",
                label="workspace",
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=1,
                ax_role="AXWebArea",
                is_web_area=True,
            ),
        ]
        menu_nodes = [
            Node(
                index=0,
                role="menu bar",
                label=None,
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=0,
                ax_role="AXMenuBar",
            ),
            Node(
                index=1,
                role="menu bar item",
                label="File",
                states=[],
                description=None,
                value=None,
                ax_id=None,
                secondary_actions=[],
                depth=1,
                ax_role="AXMenuBarItem",
            ),
        ]

        with (
            patch("app.session.feature_flags", flags),
            patch("app.session.accessibility.get_menu_bar", return_value=sentinel.menu_bar),
            patch("app.session.accessibility.walk_tree", return_value=menu_nodes),
        ):
            pruned = manager._prune_tree_nodes(
                nodes,
                bundle_id="com.microsoft.VSCode",
                ax_app=sentinel.ax_app,
                target_pid=123,
            )

        self.assertTrue(any(node.role == "menu bar" for node in pruned))
        self.assertTrue(any(node.role == "menu bar item" and node.label == "File" for node in pruned))

    def test_restore_previous_frontmost_app_when_target_steals_focus(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.microsoft.VSCode",
                pid=222,
                window_id=77,
                window_pid=222,
                ax_app=object(),
                ax_window=object(),
            ),
        )
        previous_frontmost = MagicMock()
        previous_frontmost.processIdentifier.return_value = 111
        current_frontmost = MagicMock()
        current_frontmost.processIdentifier.return_value = 222

        with (
            patch("app.session.apps.get_frontmost_app", return_value=current_frontmost),
            patch("app.session.apps.restore_frontmost") as restore_frontmost,
        ):
            manager._restore_previous_frontmost_app(session, previous_frontmost)

        restore_frontmost.assert_called_once_with(previous_frontmost)

    def test_restore_previous_frontmost_app_skips_when_target_was_already_frontmost(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.microsoft.VSCode",
                pid=222,
                window_id=77,
                window_pid=222,
                ax_app=object(),
                ax_window=object(),
            ),
        )
        previous_frontmost = MagicMock()
        previous_frontmost.processIdentifier.return_value = 222

        with patch("app.session.apps.restore_frontmost") as restore_frontmost:
            manager._restore_previous_frontmost_app(session, previous_frontmost)

        restore_frontmost.assert_not_called()

    def test_take_snapshot_uses_transient_only_tree_without_screenshot(self) -> None:
        flags = FeatureFlags(
            transient_graphs=True,
            tree_pruning=False,
            codex_tree_style=True,
            web_content_extraction=False,
            system_selection=False,
            screen_capture_kit=False,
            screenshot_classifier=False,
            rich_text_markdown=False,
        )
        manager = SessionManager()
        transient_root = object()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.Music",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
        )
        session.transient_graph_tracker = MagicMock()
        type(session.transient_graph_tracker).active_surface = property(
            lambda _: TransientSurface(root_ref=transient_root, locator=None, kind="menu")
        )

        node = Node(
            index=0,
            role="menu",
            label="View",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_ref=object(),
            ax_role="AXMenu",
        )

        with (
            patch("app.session.feature_flags", flags),
            patch.object(manager, "_refresh_window"),
            patch.object(manager, "_update_application_window"),
            patch.object(manager, "_collect_tree_nodes", return_value=[node]) as collect_tree,
            patch.object(manager, "_capture_screenshot") as capture_screenshot,
            patch("app.session.accessibility.get_focused_element", return_value=None),
            patch.object(manager, "_build_app_state", return_value=None),
            patch.object(manager, "_get_window_title", return_value="Music"),
            patch.object(manager, "_prune_tree_nodes", side_effect=lambda nodes, **_: nodes),
            patch.object(manager, "_annotate_node_geometry"),
        ):
            response = manager.take_snapshot(session)

        collect_tree.assert_called_once_with(
            transient_root,
            ax_app=session.target.ax_app,
            target_pid=session.target.pid,
            app_type=session.app_type,
        )
        capture_screenshot.assert_not_called()
        self.assertIsNone(response.screenshot)
        self.assertEqual(len(session.graphs.transient_stack), 1)
        self.assertEqual(session.graphs.transient_stack[-1].kind.value, "transient")
        self.assertEqual(session.tree_nodes[0].graph_id, session.graphs.transient_stack[-1].graph_id)

    def test_take_snapshot_dismisses_transient_surface_after_capture(self) -> None:
        flags = FeatureFlags(
            transient_graphs=True,
            tree_pruning=False,
            codex_tree_style=True,
            web_content_extraction=False,
            system_selection=False,
            screen_capture_kit=False,
            screenshot_classifier=False,
            rich_text_markdown=False,
        )
        manager = SessionManager()
        transient_root = object()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.Music",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
        )
        session.transient_graph_tracker = MagicMock()
        type(session.transient_graph_tracker).active_surface = property(
            lambda _: TransientSurface(root_ref=transient_root, locator=None, kind="menu")
        )

        node = Node(
            index=0,
            role="menu",
            label="View",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_ref=object(),
            ax_role="AXMenu",
        )

        with (
            patch("app.session.feature_flags", flags),
            patch.object(manager, "_refresh_window"),
            patch.object(manager, "_update_application_window"),
            patch.object(manager, "_collect_tree_nodes", return_value=[node]),
            patch.object(manager, "_capture_screenshot"),
            patch("app.session.accessibility.get_focused_element", return_value=None),
            patch.object(manager, "_build_app_state", return_value=None),
            patch.object(manager, "_get_window_title", return_value="Music"),
            patch.object(manager, "_prune_tree_nodes", side_effect=lambda nodes, **_: nodes),
            patch.object(manager, "_annotate_node_geometry"),
            patch.object(manager, "_dismiss_transient_surface") as dismiss_transient,
        ):
            manager.take_snapshot(session)

        dismiss_transient.assert_called_once()

    def test_take_snapshot_active_transient_skips_persistent_refresh_and_enrichment(self) -> None:
        flags = FeatureFlags(
            transient_graphs=True,
            tree_pruning=False,
            codex_tree_style=True,
            web_content_extraction=True,
            system_selection=True,
            screen_capture_kit=False,
            screenshot_classifier=False,
            rich_text_markdown=True,
        )
        manager = SessionManager()
        transient_root = object()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.Music",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
        )
        session.transient_graph_tracker = MagicMock()
        type(session.transient_graph_tracker).active_surface = property(
            lambda _: TransientSurface(root_ref=transient_root, locator=None, kind="menu")
        )

        node = Node(
            index=0,
            role="menu",
            label="View",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_ref=object(),
            ax_role="AXMenu",
        )

        with (
            patch("app.session.feature_flags", flags),
            patch.object(manager, "_refresh_window") as refresh_window,
            patch.object(manager, "_update_application_window") as update_application_window,
            patch.object(manager, "_collect_tree_nodes", return_value=[node]),
            patch.object(manager, "_capture_screenshot") as capture_screenshot,
            patch.object(manager, "_enrich_nodes_with_web_content") as enrich_nodes,
            patch.object(manager, "_annotate_node_geometry") as annotate_geometry,
            patch.object(manager, "_build_app_state") as build_app_state,
            patch.object(manager, "_extract_system_selection") as extract_selection,
            patch.object(manager, "_get_window_title", return_value="Music"),
            patch.object(manager, "_prune_tree_nodes", side_effect=lambda nodes, **_: nodes),
            patch.object(manager, "_dismiss_transient_surface"),
        ):
            response = manager.take_snapshot(session)

        refresh_window.assert_not_called()
        update_application_window.assert_not_called()
        capture_screenshot.assert_not_called()
        enrich_nodes.assert_not_called()
        annotate_geometry.assert_not_called()
        build_app_state.assert_not_called()
        extract_selection.assert_not_called()
        self.assertIsNone(response.screenshot)
        self.assertEqual(response.app, "com.apple.Music")

    def test_resolve_session_blocks_actions_after_user_invalidation(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.microsoft.VSCode",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            user_state_invalidated=True,
            user_state_invalidated_message="The user changed 'VSCode'. Re-query the latest state with `get_app_state` before sending more actions.",
        )
        with patch.object(manager, "get_or_create_session_for_window", return_value=session):
            with self.assertRaises(UserInterruptionError):
                manager._resolve_session("click", {"window_id": 77})

            resolved = manager._resolve_session("get_app_state", {"window_id": 77})
        self.assertIs(resolved, session)

    def test_clear_user_invalidated_state_resets_block(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.microsoft.VSCode",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            user_state_invalidated=True,
            user_state_invalidated_message="stale",
        )

        manager._clear_user_invalidated_state(session)

        self.assertFalse(session.user_state_invalidated)
        self.assertIsNone(session.user_state_invalidated_message)

    def test_resolve_session_repairs_missing_observer_monitor(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Native",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
        )
        session.refetchable_tree = MagicMock()
        session.refetchable_tree.nodes = []

        with (
            patch.object(manager, "get_or_create_session_for_window", return_value=session),
            patch.object(manager, "_teardown_observer") as teardown,
            patch.object(manager, "_setup_observer", side_effect=lambda s: setattr(s, "invalidation_monitor", sentinel.monitor)) as setup,
        ):
            resolved = manager._resolve_session("click", {"window_id": 77})

        self.assertIs(resolved, session)
        teardown.assert_called_once_with(session)
        setup.assert_called_once_with(session)
        session.refetchable_tree.update.assert_called_once_with([], monitor=sentinel.monitor)

    def test_setup_observer_starts_cgevent_monitor_even_when_ax_observer_fails(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Native",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )

        cgevent_monitor = MagicMock()
        with (
            patch("app.session.AXNotificationObserver") as observer_cls,
            patch("app.session.CGEventOutcomeMonitor", return_value=cgevent_monitor),
            patch("app.session.feature_flags.cgevent_action_verification", True),
            patch("app.session.feature_flags.transient_graphs", False),
            patch("app.session.feature_flags.menu_tracking", False),
            patch("app.session.feature_flags.system_selection", False),
        ):
            observer = observer_cls.return_value
            observer.start.return_value = False
            manager._setup_observer(session)

        cgevent_monitor.start.assert_called_once()
        self.assertIs(session.cgevent_outcome_monitor, cgevent_monitor)

    def test_handle_click_prefers_ax_for_native_index_click(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Native",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.NATIVE_COCOA),
            app_type=AppType.NATIVE_COCOA,
        )
        node = Node(
            index=0,
            role="button",
            label="Submit",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
        )

        with (
            patch.object(manager, "_resolve_index", return_value=node),
            patch.object(manager, "_should_prefer_pointer_input", return_value=False),
            patch.object(manager, "_try_ax_click_node", return_value="Clicked element 0 (AXPress)") as ax_click,
            patch.object(manager, "_try_ax_hit_test_click", return_value=None) as hit_click,
            patch.object(manager, "_background_click_node", return_value=False) as background_click,
        ):
            result = manager._handle_click(session, {"element_index": "0"})

        self.assertEqual(result, "Clicked element 0 (AXPress)")
        ax_click.assert_called_once_with(session, node, 0, button="left", count=1)
        hit_click.assert_not_called()
        background_click.assert_not_called()

    def test_should_prefer_pointer_input_for_button_without_ax_activation(self) -> None:
        manager = SessionManager()
        node = Node(
            index=0,
            role="button",
            label=None,
            states=[],
            description="Mac Blue",
            value=None,
            ax_id=None,
            secondary_actions=["AXScrollToVisible"],
            depth=0,
            ax_role="AXButton",
            ax_ref=object(),
        )
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.NATIVE_COCOA),
            app_type=AppType.NATIVE_COCOA,
            tree_nodes=[node],
        )

        with patch(
            "app.session.accessibility.get_action_names_for_ref",
            return_value=["AXScrollToVisible", "AXShowMenu"],
        ):
            self.assertTrue(manager._should_prefer_pointer_input(session, node))

    def test_try_ax_click_node_skips_axpress_when_button_has_no_activation_action(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )
        node = Node(
            index=0,
            role="button",
            label=None,
            states=[],
            description="Mac Blue",
            value=None,
            ax_id=None,
            secondary_actions=["AXScrollToVisible"],
            depth=0,
            ax_role="AXButton",
            ax_ref=object(),
        )

        with (
            patch.object(manager, "_should_force_pointer_for_node", return_value=True),
            patch("app.session.accessibility.perform_action") as perform_action,
        ):
            result = manager._try_ax_click_node(session, node, 0, button="left", count=1)

        self.assertIsNone(result)
        perform_action.assert_not_called()

    def test_prepare_node_for_pointer_click_scrolls_node_into_view(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )
        node = Node(
            index=0,
            role="button",
            label=None,
            states=[],
            description="Tahoe",
            value=None,
            ax_id="Tahoe;",
            secondary_actions=["AXScrollToVisible"],
            depth=0,
            ax_role="AXButton",
            ax_ref=object(),
        )
        refreshed = Node(
            index=0,
            role="button",
            label=None,
            states=[],
            description="Tahoe",
            value=None,
            ax_id="Tahoe;",
            secondary_actions=["AXScrollToVisible"],
            depth=0,
            ax_role="AXButton",
            ax_ref=node.ax_ref,
        )

        with (
            patch.object(manager, "_node_is_visible_in_window", side_effect=[False, True]),
            patch.object(manager, "_node_action_names", return_value={"AXScrollToVisible"}),
            patch("app.session.accessibility.perform_action") as perform_action,
            patch.object(manager, "_verify_ax_contract", return_value=ActionVerificationResult.CONFIRMED) as verify,
            patch.object(manager, "_refresh_live_node_from_ref", return_value=refreshed),
        ):
            result = manager._prepare_node_for_pointer_click(session, node)

        self.assertIs(result, refreshed)
        perform_action.assert_called_once_with(node, "AXScrollToVisible")
        verify.assert_called_once()

    def test_make_selection_click_verifier_for_nonactivatable_button_uses_selected_state(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )
        node = Node(
            index=0,
            role="button",
            label=None,
            states=[],
            description="Tahoe",
            value=None,
            ax_id="Tahoe;",
            secondary_actions=["AXScrollToVisible"],
            depth=1,
            ax_role="AXButton",
            ax_ref=object(),
        )
        container = Node(
            index=1,
            role="list",
            label=None,
            states=[],
            description="Dynamic Wallpapers",
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_role="AXOpaqueProviderGroup",
            ax_ref=object(),
        )
        refreshed = Node(
            index=0,
            role="button",
            label=None,
            states=["selected"],
            description="Tahoe",
            value=None,
            ax_id="Tahoe;",
            secondary_actions=["AXScrollToVisible"],
            depth=1,
            ax_role="AXButton",
            ax_ref=node.ax_ref,
        )

        with (
            patch.object(manager, "_should_force_pointer_for_node", return_value=True),
            patch.object(manager, "_selection_container_node", return_value=container),
            patch.object(manager, "_selected_identities_in_container", return_value=set()),
            patch.object(manager, "_refresh_live_node_from_ref", side_effect=lambda current: refreshed if current is node else current),
        ):
            verifier = manager._make_selection_click_verifier(session, node)
            self.assertIsNotNone(verifier)
            assert verifier is not None
            self.assertTrue(verifier())

    def test_expand_focused_collection_children_inserts_live_children(self) -> None:
        manager = SessionManager()
        root = Node(
            index=0,
            role="standard window",
            label="Wallpaper",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_role="AXWindow",
            ax_ref=object(),
        )
        collection = Node(
            index=1,
            role="collection",
            label=None,
            states=["focused"],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=1,
            ax_role="AXOpaqueProviderGroup",
            ax_ref=object(),
        )
        child = Node(
            index=-1,
            role="button",
            label=None,
            states=[],
            description="Black",
            value=None,
            ax_id="Black;",
            secondary_actions=["AXShowMenu"],
            depth=2,
            ax_role="AXButton",
            ax_ref=object(),
        )

        with patch.object(manager, "_live_collection_children", return_value=[child]):
            expanded = manager._expand_focused_collection_children([root, collection])

        self.assertEqual([node.description for node in expanded], [None, None, "Black"])
        self.assertEqual(expanded[2].depth, 2)
        self.assertEqual(expanded[2].index, 2)

    def test_expand_focused_collection_children_skips_when_descendants_already_present(self) -> None:
        manager = SessionManager()
        collection = Node(
            index=0,
            role="collection",
            label=None,
            states=["focused"],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_role="AXOpaqueProviderGroup",
            ax_ref=object(),
        )
        child = Node(
            index=1,
            role="button",
            label=None,
            states=[],
            description="Black",
            value=None,
            ax_id="Black;",
            secondary_actions=["AXShowMenu"],
            depth=1,
            ax_role="AXButton",
            ax_ref=object(),
        )

        with patch.object(manager, "_live_collection_children") as live_children:
            expanded = manager._expand_focused_collection_children([collection, child])

        self.assertEqual(expanded, [collection, child])
        live_children.assert_not_called()

    def test_expand_focused_collection_children_ignores_scrollbar_only_children(self) -> None:
        manager = SessionManager()
        collection = Node(
            index=0,
            role="collection",
            label=None,
            states=["focused"],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_role="AXOpaqueProviderGroup",
            ax_ref=object(),
        )
        scrollbar = Node(
            index=1,
            role="scroll bar",
            label="0",
            states=["settable", "float"],
            description=None,
            value="0",
            ax_id=None,
            secondary_actions=[],
            depth=1,
            ax_role="AXScrollBar",
            ax_ref=object(),
        )
        child = Node(
            index=-1,
            role="button",
            label=None,
            states=[],
            description="Black",
            value=None,
            ax_id="Black;",
            secondary_actions=["AXShowMenu"],
            depth=1,
            ax_role="AXButton",
            ax_ref=object(),
        )

        with patch.object(manager, "_live_collection_children", return_value=[child]):
            expanded = manager._expand_focused_collection_children([collection, scrollbar])

        self.assertEqual([node.description for node in expanded], [None, "Black", None])
        self.assertEqual(expanded[1].depth, 1)

    def test_verify_cgevent_contract_without_transport_monitor_uses_direct_verifier(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )

        result = manager._verify_cgevent_contract(
            session,
            expectation=sentinel.expectation,
            transport_mark=0,
            contract=VerificationContract(direct_verifier=lambda: False),
            notification_mark=None,
            timeout=0.01,
        )

        self.assertEqual(result, ActionVerificationResult.TIMEOUT)

    def test_handle_click_uses_ax_hit_test_after_pointer_miss(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Browser",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.BROWSER),
            app_type=AppType.BROWSER,
        )
        node = Node(
            index=0,
            role="button",
            label="Continue",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
        )

        with (
            patch.object(manager, "_resolve_index", return_value=node),
            patch.object(manager, "_should_prefer_pointer_input", return_value=True),
            patch.object(manager, "_background_click_node", return_value=False) as background_click,
            patch.object(manager, "_try_ax_hit_test_click", return_value="Clicked element 0 (AX hit-test)") as hit_click,
            patch.object(manager, "_try_ax_click_node", return_value=None) as ax_click,
        ):
            result = manager._handle_click(session, {"element_index": "0"})

        self.assertEqual(result, "Clicked element 0 (AX hit-test)")
        background_click.assert_called_once_with(session, node, button="left", count=1)
        hit_click.assert_called_once_with(session, node, 0, button="left", count=1)
        ax_click.assert_not_called()

    def test_handle_click_uses_background_events_only_after_ax_paths_fail(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Native",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.NATIVE_COCOA),
            app_type=AppType.NATIVE_COCOA,
        )
        node = Node(
            index=0,
            role="button",
            label="Submit",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
        )

        with (
            patch.object(manager, "_resolve_index", return_value=node),
            patch.object(manager, "_should_prefer_pointer_input", return_value=False),
            patch.object(manager, "_background_click_node", return_value=True) as background_click,
            patch.object(manager, "_try_ax_hit_test_click", return_value=None) as hit_click,
            patch.object(manager, "_try_ax_click_node", return_value=None) as ax_click,
        ):
            result = manager._handle_click(session, {"element_index": "0"})

        self.assertEqual(result, "Clicked element 0 (CGEventPostToPid)")
        ax_click.assert_called_once_with(session, node, 0, button="left", count=1)
        hit_click.assert_called_once_with(session, node, 0, button="left", count=1)
        background_click.assert_called_once_with(session, node, button="left", count=1)

    def test_handle_coordinate_click_prefers_ax_hit_test_when_strategy_allows(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Native",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.NATIVE_COCOA),
            app_type=AppType.NATIVE_COCOA,
        )

        with (
            patch.object(manager, "_to_screen_coords", return_value=(300.0, 200.0)) as to_screen,
            patch.object(
                manager,
                "_try_ax_hit_test_click_at_point",
                return_value="Clicked at (10.0, 20.0) (AX hit-test)",
            ) as ax_hit_test,
            patch("app.session.cg_input.click_at") as click_at,
        ):
            result = manager._handle_click(session, {"x": 10, "y": 20})

        self.assertEqual(result, "Clicked at (10.0, 20.0) (AX hit-test)")
        to_screen.assert_called_once_with(session, 77, 10.0, 20.0)
        ax_hit_test.assert_called_once_with(
            session,
            300.0,
            200.0,
            display_x=10.0,
            display_y=20.0,
            button="left",
            count=1,
        )
        click_at.assert_not_called()

    def test_handle_coordinate_click_falls_back_to_cgevent_when_ax_hit_test_skips(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.example.Browser",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            ),
            input_strategy=InputStrategy(AppType.BROWSER),
            app_type=AppType.BROWSER,
        )

        with (
            patch.object(manager, "_to_screen_coords", return_value=(300.0, 200.0)),
            patch.object(manager, "_try_ax_hit_test_click_at_point", return_value=None) as ax_hit_test,
            patch("app.session.cg_input.click_at") as click_at,
        ):
            result = manager._handle_click(session, {"x": 10, "y": 20})

        self.assertEqual(result, "Clicked at (10, 20) (CGEventPostToPid)")
        ax_hit_test.assert_called_once_with(
            session,
            300.0,
            200.0,
            display_x=10.0,
            display_y=20.0,
            button="left",
            count=1,
        )
        click_at.assert_called_once_with(
            111,
            77,
            10.0,
            20.0,
            button="left",
            count=1,
            screenshot_size=None,
        )

    def test_click_point_for_node_uses_visible_intersection(self) -> None:
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
        node = Node(
            index=0,
            role="button",
            label="Offscreen",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
        )

        with (
            patch("app.session.accessibility.get_element_frame", return_value=(50.0, 60.0, 120.0, 80.0)),
            patch("app.session.screenshot.get_window_bounds", return_value=(100.0, 100.0, 100.0, 100.0)),
        ):
            point = manager._click_point_for_node(session, node)

        self.assertEqual(point, (135.0, 120.0))

    def test_handle_secondary_action_show_menu_does_not_fallback_to_axpress(self) -> None:
        manager = SessionManager()
        session = AppSession(
            target=AppTarget(
                bundle_id="com.apple.systempreferences",
                pid=111,
                window_id=77,
                window_pid=111,
                ax_app=object(),
                ax_window=object(),
            )
        )
        node = Node(
            index=0,
            role="button",
            label=None,
            states=[],
            description="Tahoe",
            value=None,
            ax_id="Tahoe;",
            secondary_actions=["AXScrollToVisible"],
            depth=0,
            ax_role="AXButton",
            ax_ref=object(),
        )

        with (
            patch.object(manager, "_resolve_index", return_value=node),
            patch("app.session.accessibility.perform_action", side_effect=AutomationError("unsupported")) as perform_action,
        ):
            with self.assertRaisesRegex(AutomationError, "Action 'AXShowMenu' failed on element 0"):
                manager._handle_secondary_action(session, {"element_index": "0", "action": "AXShowMenu"})

        perform_action.assert_called_once_with(node, "AXShowMenu")



if __name__ == "__main__":
    unittest.main()
