from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch

from PIL import Image

from app._lib import screenshot


class ScreenshotTests(unittest.TestCase):
    def test_prepare_image_for_transport_downscales_large_images(self) -> None:
        image = Image.new("RGB", (3840, 2160), "white")

        prepared = screenshot.prepare_image_for_transport(image)

        self.assertEqual(prepared.size, (1920, 1080))

    def test_prepare_image_for_transport_keeps_small_images(self) -> None:
        image = Image.new("RGB", (1200, 800), "white")

        prepared = screenshot.prepare_image_for_transport(image)

        self.assertIs(prepared, image)


class SnapshotIntegrityTests(unittest.TestCase):
    @patch("app._lib.screenshot.skylight")
    @patch("app._lib.screenshot.capture_window")
    def test_validate_and_capture_succeeds_for_valid_window(
        self, mock_capture: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_skylight.validate_window_owner.return_value = True
        mock_capture.return_value = MagicMock()  # fake image

        result = screenshot.validate_and_capture(window_id=77, expected_pid=123)

        mock_skylight.validate_window_owner.assert_called_once_with(77, 123)
        mock_capture.assert_called_once_with(77)
        self.assertIsNotNone(result)
        image, wid = result
        self.assertEqual(wid, 77)

    @patch("app._lib.screenshot.skylight")
    @patch("app._lib.screenshot.list_windows")
    @patch("app._lib.screenshot.capture_window")
    def test_validate_and_capture_re_resolves_stale_window_id(
        self, mock_capture: MagicMock, mock_list: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_skylight.validate_window_owner.return_value = False
        mock_list.return_value = [
            MagicMock(window_id=88, owner_pid=123, onscreen=True, width=800, height=600),
        ]
        mock_capture.return_value = MagicMock()

        result = screenshot.validate_and_capture(window_id=77, expected_pid=123)

        self.assertIsNotNone(result)
        image, new_window_id = result
        self.assertEqual(new_window_id, 88)
        mock_capture.assert_called_once_with(88)

    @patch("app._lib.screenshot.skylight")
    @patch("app._lib.screenshot.list_windows")
    def test_validate_and_capture_returns_none_when_no_window_found(
        self, mock_list: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_skylight.validate_window_owner.return_value = False
        mock_list.return_value = []  # no windows for this PID

        result = screenshot.validate_and_capture(window_id=77, expected_pid=123)

        self.assertIsNone(result)


if __name__ == "__main__":
    unittest.main()
