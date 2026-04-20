from __future__ import annotations

import threading
import unittest
from unittest.mock import MagicMock, patch

from app._lib.delivery_tap import DeliveryConfirmationTap


class DeliveryConfirmationTapTests(unittest.TestCase):
    def test_signal_fires_when_source_id_matches(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        event = MagicMock()

        with patch("app._lib.delivery_tap.CGEventGetIntegerValueField", return_value=42):
            tap._on_event(None, 10, event)  # KEY_DOWN = 10

        self.assertTrue(tap.transport_confirmed.is_set())

    def test_signal_does_not_fire_for_different_source_id(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        event = MagicMock()

        with patch("app._lib.delivery_tap.CGEventGetIntegerValueField", return_value=99):
            tap._on_event(None, 10, event)

        self.assertFalse(tap.transport_confirmed.is_set())

    def test_reset_clears_confirmed_flag(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        tap.transport_confirmed.set()
        tap.reset()
        self.assertFalse(tap.transport_confirmed.is_set())

    def test_wait_returns_false_on_timeout(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        result = tap.wait(timeout=0.001)
        self.assertFalse(result)

    def test_wait_returns_true_when_confirmed(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        tap.transport_confirmed.set()
        result = tap.wait(timeout=0.01)
        self.assertTrue(result)


if __name__ == "__main__":
    unittest.main()
