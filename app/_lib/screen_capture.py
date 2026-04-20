"""GPU-accelerated window capture via ScreenCaptureKit.

Pipeline:
- SCShareableContent -> filter for target window
- SCScreenshotManager.captureImageWithFilter -> GPU-accelerated capture
- Fallback to CGWindowListCreateImage when SCK unavailable

Feature flags:
- screen_capture_kit: use SCK (default True, fallback to CGWindowListCreateImage)
- screenshot_classifier: run ScreenshotClassifier on captures (default False)
"""

from __future__ import annotations

import logging
import os
import tempfile
import threading
from typing import Any

from PIL import Image

from app._lib.errors import ScreenshotError
from app._lib.tracing import controller_tracer

logger = logging.getLogger(__name__)

# Whether ScreenCaptureKit is available at import time
_sck_available: bool | None = None


def _get_backing_scale_for_rect(frame: Any) -> float:
    """Get the backing scale factor for the screen containing a given rect.

    Falls back to mainScreen, then to 2.0 (Retina default).
    """
    try:
        from AppKit import NSScreen
        from Foundation import NSRect, NSPoint, NSSize

        # Build an NSRect from the SCWindow frame
        origin = NSPoint(float(frame.origin.x), float(frame.origin.y))
        size = NSSize(float(frame.size.width), float(frame.size.height))
        ns_rect = NSRect(origin, size)

        # Find the screen with the most overlap
        best_screen = None
        best_area = 0.0
        for screen in NSScreen.screens():
            sf = screen.frame()
            # Calculate intersection
            ix = max(float(sf.origin.x), float(ns_rect.origin.x))
            iy = max(float(sf.origin.y), float(ns_rect.origin.y))
            iw = min(
                float(sf.origin.x) + float(sf.size.width),
                float(ns_rect.origin.x) + float(ns_rect.size.width),
            ) - ix
            ih = min(
                float(sf.origin.y) + float(sf.size.height),
                float(ns_rect.origin.y) + float(ns_rect.size.height),
            ) - iy
            if iw > 0 and ih > 0:
                area = iw * ih
                if area > best_area:
                    best_area = area
                    best_screen = screen

        if best_screen is not None:
            return float(best_screen.backingScaleFactor())

        main_screen = NSScreen.mainScreen()
        if main_screen is not None:
            return float(main_screen.backingScaleFactor())
    except Exception:
        pass
    return 2.0


def is_sck_available() -> bool:
    """Check if ScreenCaptureKit is available (macOS 12.3+)."""
    global _sck_available
    if _sck_available is not None:
        return _sck_available
    try:
        import ScreenCaptureKit  # noqa: F401
        _sck_available = True
    except ImportError:
        _sck_available = False
    return _sck_available


class ScreenCapturer:
    """GPU-accelerated window capture via ScreenCaptureKit.

    Pipeline:
    1. SCShareableContent.getShareableContent -> available windows
    2. Filter for target window (SCWindow matching PID + window ID)
    3. SCScreenshotManager.captureImage with SCContentFilter
    4. CGImage -> PIL Image
    """

    def capture(self, window_id: int, pid: int) -> Image.Image | None:
        """Capture a window screenshot via ScreenCaptureKit.

        Returns PIL Image or None on failure.
        """
        if not is_sck_available():
            return None

        with controller_tracer.interval("SCK Window Capture"):
            try:
                return self._capture_impl(window_id, pid)
            except Exception as e:
                logger.debug(
                    "Screen capture worker failed for display %u: %s.",
                    window_id, e,
                )
                return None

    def _capture_impl(self, window_id: int, pid: int) -> Image.Image | None:
        import ScreenCaptureKit as SCK

        # Step 1: Get shareable content
        sc_windows = self._get_shareable_windows()
        if sc_windows is None:
            return None

        # Step 2: Find matching SCWindow
        target_window = None
        for w in sc_windows:
            try:
                w_id = w.windowID()
                w_pid = w.owningApplication().processID() if w.owningApplication() else 0
            except Exception:
                continue
            if w_id == window_id and w_pid == pid:
                target_window = w
                break

        # If we can't match by both window_id and pid, fall back to window_id only
        if target_window is None:
            for w in sc_windows:
                try:
                    if w.windowID() == window_id:
                        target_window = w
                        break
                except Exception:
                    continue

        if target_window is None:
            logger.debug("SCK: No matching window for id=%d pid=%d", window_id, pid)
            return None

        # Step 3: Create content filter and configuration
        content_filter = SCK.SCContentFilter.alloc().initWithDesktopIndependentWindow_(target_window)

        config = SCK.SCStreamConfiguration.alloc().init()
        # Match the window's dimensions at native resolution
        try:
            frame = target_window.frame()
            width = int(frame.size.width)
            height = int(frame.size.height)
            if width <= 0 or height <= 0:
                logger.debug(
                    "Skipping screenshot capture with invalid size (%dx%d)",
                    width, height,
                )
                return None
            # Scale to backing (Retina) resolution — use the screen
            # containing the target window, not just mainScreen
            scale = _get_backing_scale_for_rect(frame)
            config.setWidth_(int(width * scale))
            config.setHeight_(int(height * scale))
        except Exception:
            pass

        config.setShowsCursor_(False)

        # Step 4: Capture image (synchronous wrapper around async API)
        cg_image = self._capture_image_sync(content_filter, config)
        if cg_image is None:
            logger.debug("The screen capture failed.")
            return None

        # Step 5: CGImage → PIL Image
        return self._cgimage_to_pil(cg_image)

    def _get_shareable_windows(self) -> list[Any] | None:
        """Get available windows via SCShareableContent."""
        import ScreenCaptureKit as SCK

        result: list[Any] | None = None
        error_ref: list[Exception] = []
        event = threading.Event()

        def handler(content: Any, error: Any) -> None:
            nonlocal result
            if error is not None:
                error_ref.append(Exception(str(error)))
            elif content is not None:
                try:
                    result = list(content.windows())
                except Exception as e:
                    error_ref.append(e)
            event.set()

        SCK.SCShareableContent.getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler_(
            True,  # excludeDesktopWindows
            True,  # onScreenWindowsOnly
            handler,
        )

        event.wait(timeout=5.0)
        if error_ref:
            logger.debug("Fetching on-screen shareable content failed: %s", error_ref[0])
            return None
        return result

    def _capture_image_sync(self, content_filter: Any, config: Any) -> Any | None:
        """Synchronous wrapper for SCScreenshotManager.captureImageWithFilter."""
        import ScreenCaptureKit as SCK

        cg_image_result: list[Any] = []
        error_ref: list[Exception] = []
        event = threading.Event()

        def handler(image: Any, error: Any) -> None:
            if error is not None:
                error_ref.append(Exception(str(error)))
            elif image is not None:
                cg_image_result.append(image)
            event.set()

        SCK.SCScreenshotManager.captureImageWithFilter_configuration_completionHandler_(
            content_filter,
            config,
            handler,
        )

        event.wait(timeout=10.0)
        if error_ref:
            logger.debug("SCK capture error: %s", error_ref[0])
            return None
        return cg_image_result[0] if cg_image_result else None

    def _cgimage_to_pil(self, cg_image: Any) -> Image.Image | None:
        """Convert CGImage to PIL Image."""
        from Quartz import (
            CGImageGetWidth,
            CGImageGetHeight,
            CGImageGetDataProvider,
            CGDataProviderCopyData,
            CGImageGetBytesPerRow,
        )

        width = CGImageGetWidth(cg_image)
        height = CGImageGetHeight(cg_image)
        if width == 0 or height == 0:
            logger.debug(
                "The screen capture size is invalid: %dx%d", width, height,
            )
            return None

        try:
            provider = CGImageGetDataProvider(cg_image)
            data = CGDataProviderCopyData(provider)
            bytes_per_row = CGImageGetBytesPerRow(cg_image)
            img = Image.frombytes(
                "RGBA", (width, height), bytes(data), "raw", "BGRA", bytes_per_row, 1,
            )
            return img.convert("RGB")
        except Exception as e:
            logger.warning("Failed to decode SCK screenshot: %s", e)
            return None


class TemporaryScreenshotFile:
    """RAII: auto-deletes screenshot file on deinit."""

    def __init__(self, image: Image.Image) -> None:
        fd, self.path = tempfile.mkstemp(suffix=".png")
        os.close(fd)
        image.save(self.path, format="PNG")

    def __del__(self) -> None:
        try:
            if os.path.exists(self.path):
                os.unlink(self.path)
        except Exception as e:
            logger.debug("[TempFile] Could not delete screenshot at %s", self.path)

    def __enter__(self) -> TemporaryScreenshotFile:
        return self

    def __exit__(self, *args: Any) -> None:
        try:
            if os.path.exists(self.path):
                os.unlink(self.path)
        except Exception:
            pass


class ScreenshotClassifier:
    """Determine if screenshot has meaningful content.

    Feature flag: screenshot_classifier (default False).

    Heuristics:
    - Image entropy check (solid color = not meaningful)
    - Edge density (blank screen = no edges)
    """

    def is_meaningful(self, image: Image.Image) -> bool:
        """Return True if the image likely has actionable visual content."""
        if image.width == 0 or image.height == 0:
            return False

        # Sample pixels to check for solid color
        try:
            # Downsample for fast analysis
            thumb = image.resize((32, 32), Image.Resampling.NEAREST)
            pixels = list(thumb.getdata())

            if not pixels:
                return False

            # Check if all pixels are nearly the same (solid color)
            first = pixels[0]
            if all(
                abs(p[0] - first[0]) < 5
                and abs(p[1] - first[1]) < 5
                and abs(p[2] - first[2]) < 5
                for p in pixels
            ):
                return False

            # Check color variance — very low variance means likely blank/loading
            r_vals = [p[0] for p in pixels]
            g_vals = [p[1] for p in pixels]
            b_vals = [p[2] for p in pixels]
            r_var = sum((v - sum(r_vals) / len(r_vals)) ** 2 for v in r_vals) / len(r_vals)
            g_var = sum((v - sum(g_vals) / len(g_vals)) ** 2 for v in g_vals) / len(g_vals)
            b_var = sum((v - sum(b_vals) / len(b_vals)) ** 2 for v in b_vals) / len(b_vals)

            total_var = r_var + g_var + b_var
            if total_var < 50:  # Very low variance — likely blank
                return False

            return True
        except Exception:
            # If analysis fails, assume meaningful
            return True


# Module-level singleton
_screen_capture_worker: ScreenCapturer | None = None
_screenshot_classifier: ScreenshotClassifier | None = None


def get_screen_capture_worker() -> ScreenCapturer:
    """Get or create the singleton ScreenCapturer."""
    global _screen_capture_worker
    if _screen_capture_worker is None:
        _screen_capture_worker = ScreenCapturer()
    return _screen_capture_worker


def get_screenshot_classifier() -> ScreenshotClassifier:
    """Get or create the singleton ScreenshotClassifier."""
    global _screenshot_classifier
    if _screenshot_classifier is None:
        _screenshot_classifier = ScreenshotClassifier()
    return _screenshot_classifier
