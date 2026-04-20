"""Session lifecycle — per-turn cleanup and tracking."""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass
class TurnMetadata:
    """Per-turn state tracking."""

    turn_id: str
    started_at: float = field(default_factory=time.time)
    step_count: int = 0
    apps_used: set[str] = field(default_factory=set)


class SessionLifecycle:
    """Per-turn cleanup and tracking."""

    def __init__(self, step_limit: int = 20) -> None:
        self._step_limit = step_limit
        self.current_turn: TurnMetadata | None = None

    def start_turn(self, turn_id: str) -> None:
        self.current_turn = TurnMetadata(turn_id=turn_id)
        logger.debug("Turn started: %s", turn_id)

    def end_turn(self) -> None:
        if self.current_turn is None:
            return
        elapsed = time.time() - self.current_turn.started_at
        logger.debug(
            "Turn ended: %s (steps=%d, apps=%s, elapsed=%.1fs)",
            self.current_turn.turn_id,
            self.current_turn.step_count,
            self.current_turn.apps_used,
            elapsed,
        )
        self.current_turn = None

    def increment_step(self) -> None:
        if self.current_turn is not None:
            self.current_turn.step_count += 1

    def check_step_limit(self) -> bool:
        if self._step_limit <= 0:
            return False
        if self.current_turn is None:
            return False
        return self.current_turn.step_count >= self._step_limit

    def track_app_used(self, bundle_id: str) -> None:
        if self.current_turn is not None:
            self.current_turn.apps_used.add(bundle_id)
