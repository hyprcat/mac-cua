from __future__ import annotations

import unittest

from app._lib.analytics import AnalyticsLogger


class TestAnalyticsLogger(unittest.TestCase):
    def test_log_event_appends_to_buffer(self) -> None:
        logger = AnalyticsLogger()
        logger.log_event("service_launched")
        self.assertEqual(len(logger.events), 1)
        self.assertEqual(logger.events[0]["event"], "service_launched")

    def test_log_event_with_properties(self) -> None:
        logger = AnalyticsLogger()
        logger.log_event("service_result", tool="click", success=True, duration_ms=42.5)
        event = logger.events[0]
        self.assertEqual(event["event"], "service_result")
        self.assertEqual(event["tool"], "click")
        self.assertTrue(event["success"])
        self.assertEqual(event["duration_ms"], 42.5)

    def test_log_event_has_timestamp(self) -> None:
        logger = AnalyticsLogger()
        logger.log_event("test")
        self.assertIn("timestamp", logger.events[0])

    def test_convenience_methods(self) -> None:
        logger = AnalyticsLogger()
        logger.service_launched()
        logger.mcp_tool_called("click")
        logger.service_result("click", success=True, duration_ms=100.0)
        logger.session_started("com.apple.Music")
        logger.session_ended("com.apple.Music")
        logger.mcp_app_approval_requested("com.apple.Music")
        logger.mcp_app_approval_resolved("com.apple.Music", approved=True)
        self.assertEqual(len(logger.events), 7)

    def test_flush_clears_buffer(self) -> None:
        logger = AnalyticsLogger()
        logger.log_event("test")
        events = logger.flush()
        self.assertEqual(len(events), 1)
        self.assertEqual(len(logger.events), 0)

    def test_disabled_logger_skips_events(self) -> None:
        logger = AnalyticsLogger(enabled=False)
        logger.log_event("test")
        self.assertEqual(len(logger.events), 0)


if __name__ == "__main__":
    unittest.main()
