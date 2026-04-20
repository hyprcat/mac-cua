from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch, call

from app._lib.input import deliver_key_events, DeliveryResult
from app._lib.virtual_cursor import DeliveryMethod, ActivationPolicy


class DeliverKeyEventsTests(unittest.TestCase):
    @patch("app._lib.input._post_key_event")
    def test_cgevent_delivery_confirmed_on_first_try(self, mock_post: MagicMock) -> None:
        mock_tap = MagicMock()
        mock_tap.wait.return_value = True  # transport confirmed

        result = deliver_key_events(
            pid=123,
            keycode=8,
            modifiers=1 << 20,  # cmd
            source=MagicMock(),
            delivery_method=DeliveryMethod.CGEVENT_PID,
            confirmation_tap=mock_tap,
            activation_policy=ActivationPolicy.NEVER,
        )

        self.assertTrue(result.transport_confirmed)
        self.assertFalse(result.fallback_used)

    @patch("app._lib.skylight")
    @patch("app._lib.input._post_key_event")
    def test_falls_back_to_skylight_on_cgevent_timeout(
        self, mock_post: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_tap = MagicMock()
        # First attempt (CGEvent): timeout. Second attempt (SkyLight): confirmed.
        mock_tap.wait.side_effect = [False, False, False, False, True, True, True, True]
        mock_skylight.post_keyboard_event.return_value = True
        mock_skylight.is_available.return_value = True

        result = deliver_key_events(
            pid=123,
            keycode=8,
            modifiers=1 << 20,
            source=MagicMock(),
            delivery_method=DeliveryMethod.CGEVENT_PID,
            confirmation_tap=mock_tap,
            activation_policy=ActivationPolicy.RETRY_ONLY,
        )

        self.assertTrue(result.transport_confirmed)
        self.assertTrue(result.fallback_used)

    @patch("app._lib.input._post_key_event")
    def test_all_pipelines_fail_returns_not_confirmed(self, mock_post: MagicMock) -> None:
        mock_tap = MagicMock()
        mock_tap.wait.return_value = False  # always timeout

        result = deliver_key_events(
            pid=123,
            keycode=36,
            modifiers=0,
            source=MagicMock(),
            delivery_method=DeliveryMethod.CGEVENT_PID,
            confirmation_tap=mock_tap,
            activation_policy=ActivationPolicy.NEVER,
        )

        self.assertFalse(result.transport_confirmed)


if __name__ == "__main__":
    unittest.main()
