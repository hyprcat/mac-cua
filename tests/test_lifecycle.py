from __future__ import annotations

import unittest

from app._lib.lifecycle import SessionLifecycle, TurnMetadata


class TestSessionLifecycle(unittest.TestCase):
    def test_start_turn_initializes_metadata(self) -> None:
        lifecycle = SessionLifecycle()
        lifecycle.start_turn("turn-1")
        self.assertIsNotNone(lifecycle.current_turn)
        self.assertEqual(lifecycle.current_turn.turn_id, "turn-1")
        self.assertEqual(lifecycle.current_turn.step_count, 0)

    def test_increment_step(self) -> None:
        lifecycle = SessionLifecycle()
        lifecycle.start_turn("turn-1")
        lifecycle.increment_step()
        self.assertEqual(lifecycle.current_turn.step_count, 1)

    def test_check_step_limit_below(self) -> None:
        lifecycle = SessionLifecycle(step_limit=20)
        lifecycle.start_turn("turn-1")
        for _ in range(19):
            lifecycle.increment_step()
        self.assertFalse(lifecycle.check_step_limit())

    def test_check_step_limit_at_limit(self) -> None:
        lifecycle = SessionLifecycle(step_limit=20)
        lifecycle.start_turn("turn-1")
        for _ in range(20):
            lifecycle.increment_step()
        self.assertTrue(lifecycle.check_step_limit())

    def test_track_app_used(self) -> None:
        lifecycle = SessionLifecycle()
        lifecycle.start_turn("turn-1")
        lifecycle.track_app_used("com.apple.Music")
        lifecycle.track_app_used("com.apple.Safari")
        self.assertEqual(lifecycle.current_turn.apps_used, {"com.apple.Music", "com.apple.Safari"})

    def test_end_turn_clears_metadata(self) -> None:
        lifecycle = SessionLifecycle()
        lifecycle.start_turn("turn-1")
        lifecycle.increment_step()
        lifecycle.end_turn()
        self.assertIsNone(lifecycle.current_turn)

    def test_end_turn_without_start_is_noop(self) -> None:
        lifecycle = SessionLifecycle()
        lifecycle.end_turn()

    def test_check_step_limit_zero_means_unlimited(self) -> None:
        lifecycle = SessionLifecycle(step_limit=0)
        lifecycle.start_turn("turn-1")
        for _ in range(100):
            lifecycle.increment_step()
        self.assertFalse(lifecycle.check_step_limit())


if __name__ == "__main__":
    unittest.main()
