"""Structured analytics/event logging.

Logs service lifecycle, MCP tool calls, app approvals, and session events
as structured dict entries with timestamps.
"""

from __future__ import annotations

import logging
import time
from typing import Any

logger = logging.getLogger(__name__)


class AnalyticsLogger:
    """Structured event logging."""

    def __init__(self, enabled: bool = True) -> None:
        self._enabled = enabled
        self.events: list[dict[str, Any]] = []

    def log_event(self, event: str, **kwargs: Any) -> None:
        if not self._enabled:
            return
        entry: dict[str, Any] = {
            "event": event,
            "timestamp": time.time(),
        }
        entry.update(kwargs)
        self.events.append(entry)
        logger.debug("analytics: %s %s", event, kwargs if kwargs else "")

    def flush(self) -> list[dict[str, Any]]:
        events = self.events
        self.events = []
        return events

    def service_launched(self) -> None:
        self.log_event("service_launched")

    def service_result(self, tool: str, success: bool, duration_ms: float) -> None:
        self.log_event("service_result", tool=tool, success=success, duration_ms=duration_ms)

    def service_idle_timeout_reached(self) -> None:
        self.log_event("service_idle_timeout_reached")

    def session_started(self, bundle_id: str) -> None:
        self.log_event("session_started", bundle_id=bundle_id)

    def session_ended(self, bundle_id: str) -> None:
        self.log_event("session_ended", bundle_id=bundle_id)

    def mcp_tool_called(self, tool_name: str) -> None:
        self.log_event("mcp_tool_called", mcp_tool_name=tool_name)

    def mcp_app_approval_requested(self, bundle_id: str) -> None:
        self.log_event("mcp_app_approval_requested", bundle_id=bundle_id)

    def mcp_app_approval_resolved(self, bundle_id: str, approved: bool) -> None:
        self.log_event(
            "mcp_app_approval_resolved",
            bundle_id=bundle_id,
            mcp_approval_result="approved" if approved else "denied",
        )


analytics = AnalyticsLogger()
