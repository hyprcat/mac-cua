from __future__ import annotations

import unittest
from unittest.mock import patch, sentinel

from app._lib.action_verification import (
    ActionOutcomeMonitor,
    ActionVerificationResult,
    CGEventOutcomeMonitor,
    VerificationContract,
    expectation_for_click,
)
from app._lib.event_tap import EVENT_LEFT_MOUSE_DOWN, EVENT_LEFT_MOUSE_UP, EVENT_MOUSE_MOVED
from app._lib.graphs import TransientGraphTracker
from app._lib.observer import NotificationBridge, TreeInvalidationMonitor
from app.response import Node


class TestNotificationDrivenVerification(unittest.TestCase):
    def test_transient_tracker_tracks_menu_open_and_close(self) -> None:
        tracker = TransientGraphTracker()
        menu_node = Node(
            index=0,
            role="menu",
            label="View",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_ref=sentinel.menu_ref,
            ax_role="AXMenu",
        )

        with patch("app._lib.graphs.accessibility.node_from_ref", return_value=menu_node):
            tracker.on_notification(None, sentinel.menu_ref, "AXMenuOpened")
            self.assertTrue(tracker.has_active_transient)
            tracker.on_notification(None, sentinel.menu_ref, "AXMenuClosed")
            self.assertFalse(tracker.has_active_transient)

    def test_action_outcome_monitor_reports_transient_open(self) -> None:
        bridge = NotificationBridge()
        invalidation = TreeInvalidationMonitor()
        tracker = TransientGraphTracker()
        bridge.subscribe_detailed("AXMenuOpened", tracker.on_notification)
        monitor = ActionOutcomeMonitor(bridge, invalidation, tracker)

        menu_node = Node(
            index=0,
            role="menu",
            label="View",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            ax_ref=sentinel.menu_ref,
            ax_role="AXMenu",
        )

        with patch("app._lib.graphs.accessibility.node_from_ref", return_value=menu_node):
            mark = monitor.mark()
            bridge.on_notification(None, sentinel.menu_ref, "AXMenuOpened")
            result = monitor.verify(
                contract=VerificationContract(expect_transient_open=True),
                mark=mark,
                timeout=0.05,
            )

        self.assertEqual(result, ActionVerificationResult.TRANSIENT_OPENED)


class TestCGEventOutcomeMonitor(unittest.TestCase):
    def test_verify_transport_matches_expected_click_sequence(self) -> None:
        monitor = CGEventOutcomeMonitor()
        monitor._started = True
        start = monitor.mark()

        monitor._on_event(None, EVENT_MOUSE_MOVED, object())
        monitor._on_event(None, EVENT_LEFT_MOUSE_DOWN, object())
        monitor._on_event(None, EVENT_LEFT_MOUSE_UP, object())

        self.assertTrue(
            monitor.verify_transport(
                start_sequence=start,
                expectation=expectation_for_click("left", 1),
                timeout=0.01,
            )
        )


if __name__ == "__main__":
    unittest.main()
