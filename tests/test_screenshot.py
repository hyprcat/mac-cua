from __future__ import annotations

import unittest

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


if __name__ == "__main__":
    unittest.main()
