"""Performance tracing -- structured timing spans.

Three tracer instances across the codebase:
1. controller_tracer -- traces action execution, snapshot capture
2. server_tracer -- traces MCP request handling
3. tree_tracer -- traces element refetch operations
"""

from __future__ import annotations

import logging
import time
from contextlib import contextmanager
from uuid import uuid4

logger = logging.getLogger(__name__)

# Whether tracing is enabled globally. Toggle at runtime.
_enabled = True


def set_tracing_enabled(enabled: bool) -> None:
    global _enabled
    _enabled = enabled


def is_tracing_enabled() -> bool:
    return _enabled


class Tracer:
    """Structured timing spans, equivalent to OSSignposter.

    Usage::

        tracer = Tracer("com.mac-cua", "Controller")

        with tracer.interval("Action"):
            do_stuff()

        # Or capture the span for extra metadata:
        with tracer.interval("Capture Screenshot") as span:
            img = capture()
    """

    def __init__(self, subsystem: str, category: str) -> None:
        self.subsystem = subsystem
        self.category = category
        self._logger = logging.getLogger(f"{subsystem}.{category}")

    @contextmanager
    def interval(self, name: str):
        """Trace a named interval. Yields a Span object."""
        if not _enabled:
            yield _NullSpan(name)
            return

        span = Span(name, self.subsystem, self.category)
        self._logger.debug("begin %s [%s]", name, span.span_id)
        try:
            yield span
        finally:
            span._end()
            self._logger.debug(
                "end %s [%s] elapsed=%.3fms",
                name,
                span.span_id,
                span.elapsed_ms,
            )


class Span:
    """A single tracing interval with timing data."""

    __slots__ = ("name", "subsystem", "category", "span_id", "start_ns", "elapsed_ns", "elapsed_ms")

    def __init__(self, name: str, subsystem: str, category: str) -> None:
        self.name = name
        self.subsystem = subsystem
        self.category = category
        self.span_id = uuid4().hex[:12]
        self.start_ns = time.perf_counter_ns()
        self.elapsed_ns: int = 0
        self.elapsed_ms: float = 0.0

    def _end(self) -> None:
        self.elapsed_ns = time.perf_counter_ns() - self.start_ns
        self.elapsed_ms = self.elapsed_ns / 1_000_000


class _NullSpan:
    """No-op span when tracing is disabled."""

    __slots__ = ("name", "elapsed_ns", "elapsed_ms", "span_id")

    def __init__(self, name: str) -> None:
        self.name = name
        self.elapsed_ns = 0
        self.elapsed_ms = 0.0
        self.span_id = ""


controller_tracer = Tracer("com.mac-cua", "Controller")
server_tracer = Tracer("com.mac-cua", "MCPServer")
tree_tracer = Tracer("com.mac-cua", "RefetchableTree")
