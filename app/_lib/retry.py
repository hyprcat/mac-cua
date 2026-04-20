"""Retry policy with exponential backoff.

Applied to: AX operations, screenshot capture, event posting.
"""

from __future__ import annotations

import logging
import random
import time
from dataclasses import dataclass
from typing import Callable, Iterator, TypeVar

logger = logging.getLogger(__name__)

T = TypeVar("T")


@dataclass(frozen=True)
class RetryPolicy:
    """Configurable retry with exponential backoff."""

    max_retries: int = 3
    base_interval: float = 0.5
    backoff_multiplier: float = 2.0
    max_interval: float = 10.0
    jitter: bool = True

    def intervals(self) -> Iterator[float]:
        """Generate retry intervals with exponential backoff."""
        interval = self.base_interval
        for _ in range(self.max_retries):
            if self.jitter:
                yield interval * (0.5 + random.random())
            else:
                yield interval
            interval = min(interval * self.backoff_multiplier, self.max_interval)


def with_retry(
    policy: RetryPolicy,
    operation: Callable[[], T],
    retryable: type[Exception] | tuple[type[Exception], ...] = Exception,
    *,
    context: str = "",
) -> T:
    """Execute operation with retry policy.

    Args:
        policy: Retry configuration.
        operation: Callable to execute (no args, returns T).
        retryable: Exception type(s) that trigger a retry.
        context: Label for log messages.

    Returns:
        Result of the first successful call.

    Raises:
        The last exception if all retries are exhausted.
    """
    last_error: Exception | None = None
    attempt = 0

    # First attempt (not a retry)
    try:
        return operation()
    except retryable as e:
        last_error = e
        attempt = 1
        if context:
            logger.debug("Retry %d/%d for %s: %s", attempt, policy.max_retries, context, e)
        else:
            logger.debug("Retry %d/%d: %s", attempt, policy.max_retries, e)

    # Retry attempts
    for interval in policy.intervals():
        time.sleep(interval)
        try:
            return operation()
        except retryable as e:
            last_error = e
            attempt += 1
            if context:
                logger.debug("Retry %d/%d for %s: %s", attempt, policy.max_retries, context, e)
            else:
                logger.debug("Retry %d/%d: %s", attempt, policy.max_retries, e)

    raise last_error  # type: ignore[misc]


# Pre-configured policies for different operation types
AX_RETRY_POLICY = RetryPolicy(max_retries=2, base_interval=0.1, backoff_multiplier=2.0, jitter=False)
SCREENSHOT_RETRY_POLICY = RetryPolicy(max_retries=2, base_interval=0.2, backoff_multiplier=2.0, jitter=False)
EVENT_RETRY_POLICY = RetryPolicy(max_retries=1, base_interval=0.05, backoff_multiplier=1.0, jitter=False)
