from __future__ import annotations

import base64
import io
import logging
import re
import time
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Window list cache — avoids redundant CGWindowListCopyWindowInfo calls
# within the same tool execution (~50ms each on a busy desktop).
# ---------------------------------------------------------------------------
_window_list_cache: list | None = None
_window_list_cache_time: float = 0.0
_WINDOW_LIST_CACHE_TTL = 0.2  # 200ms — covers a burst of lookups within one step


def _get_window_list() -> list:
    """Return the CGWindowList, cached for up to _WINDOW_LIST_CACHE_TTL."""
    global _window_list_cache, _window_list_cache_time
    now = time.monotonic()
    if _window_list_cache is not None and (now - _window_list_cache_time) < _WINDOW_LIST_CACHE_TTL:
        return _window_list_cache
    wl = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID)
    _window_list_cache = wl if wl is not None else []
    _window_list_cache_time = now
    return _window_list_cache


def invalidate_window_list_cache() -> None:
    """Force a fresh window list on the next call."""
    global _window_list_cache, _window_list_cache_time
    _window_list_cache = None
    _window_list_cache_time = 0.0

from Quartz import (
    CGWindowListCopyWindowInfo,
    CGWindowListCreateImage,
    CGRectNull,
    kCGWindowListOptionIncludingWindow,
    kCGWindowImageBoundsIgnoreFraming,
    kCGWindowListOptionAll,
    kCGNullWindowID,
    CGImageGetWidth,
    CGImageGetHeight,
    CGImageGetDataProvider,
    CGDataProviderCopyData,
    CGImageGetBytesPerRow,
)
from PIL import Image

from app._lib.errors import ScreenshotError


_FLOAT_RE = r"-?\d+(?:\.\d+)?"


@dataclass(frozen=True)
class WindowInfo:
    window_id: int
    owner_pid: int
    owner_name: str | None
    title: str | None
    x: float
    y: float
    width: float
    height: float
    onscreen: bool


@dataclass
class ApplicationWindow:
    """Permanent CG + AX window association.

    Updated on window notifications.
    """

    cg_window_info: WindowInfo
    ax_window: Any  # AXUIElement
    ax_application: Any  # AXUIElement

    @property
    def window_id(self) -> int:
        return self.cg_window_info.window_id

    @property
    def owner_pid(self) -> int:
        return self.cg_window_info.owner_pid

    @property
    def frame(self) -> tuple[float, float, float, float]:
        w = self.cg_window_info
        return (w.x, w.y, w.width, w.height)

    @property
    def can_become_key_window(self) -> bool:
        """Check if this window can become key."""
        if self.ax_window is None:
            return False
        try:
            from ApplicationServices import AXUIElementCopyAttributeValue, kAXErrorSuccess
            err, _ = AXUIElementCopyAttributeValue(self.ax_window, "AXMain", None)
            return err == kAXErrorSuccess
        except Exception:
            return False

    def ax_frame(self) -> tuple[float, float, float, float] | None:
        """Get window frame from AX (may differ from CG during animation)."""
        if self.ax_window is None:
            return None
        sig = _get_ax_window_signature(self.ax_window)
        _, position, size = sig
        if position is not None and size is not None:
            return (position[0], position[1], size[0], size[1])
        return None

    def refresh_cg_info(self) -> bool:
        """Update CGWindow fields from current state. Returns False if window gone."""
        window_list = _get_window_list()
        if not window_list:
            return False
        for w in window_list:
            if w.get("kCGWindowNumber") == self.cg_window_info.window_id:
                bounds = w.get("kCGWindowBounds", {})
                width = float(bounds.get("Width", 0) or 0)
                height = float(bounds.get("Height", 0) or 0)
                if width <= 0 or height <= 0:
                    return False
                self.cg_window_info = WindowInfo(
                    window_id=self.cg_window_info.window_id,
                    owner_pid=int(w.get("kCGWindowOwnerPID", 0) or 0),
                    owner_name=str(w.get("kCGWindowOwnerName")) if w.get("kCGWindowOwnerName") else None,
                    title=str(w.get("kCGWindowName")) if w.get("kCGWindowName") else None,
                    x=float(bounds.get("X", 0) or 0),
                    y=float(bounds.get("Y", 0) or 0),
                    width=width,
                    height=height,
                    onscreen=bool(w.get("kCGWindowIsOnscreen")),
                )
                return True
        return False

    def is_valid(self) -> bool:
        """Check if both CG and AX refs still valid."""
        # Check CG side
        wl = _get_window_list()
        if not wl:
            return False
        cg_found = any(
            w.get("kCGWindowNumber") == self.cg_window_info.window_id
            for w in wl
        )
        if not cg_found:
            return False
        # Check AX side
        if self.ax_window is None:
            return False
        try:
            from ApplicationServices import AXUIElementCopyAttributeValue, kAXErrorSuccess, kAXRoleAttribute
            err, _ = AXUIElementCopyAttributeValue(self.ax_window, kAXRoleAttribute, None)
            return err == kAXErrorSuccess
        except Exception:
            return False

    @classmethod
    def create(cls, pid: int, ax_window: Any, ax_application: Any) -> ApplicationWindow | None:
        """Create an ApplicationWindow by matching AX window to CG window."""
        window_id = find_window_id_for_ax_window(pid, ax_window)
        if window_id is None:
            return None
        windows = list_windows(owner_pid=pid)
        for w in windows:
            if w.window_id == window_id:
                return cls(
                    cg_window_info=w,
                    ax_window=ax_window,
                    ax_application=ax_application,
                )
        return None


def _extract_ax_pair(ax_value: Any, kind: str) -> tuple[float, float] | None:
    try:
        try:
            from ApplicationServices import AXValueGetValue
        except ImportError:
            from Quartz import AXValueGetValue

        if kind == "point":
            try:
                from ApplicationServices import kAXValueCGPointType
            except ImportError:
                from Quartz import kAXValueCGPointType
            ok, point = AXValueGetValue(ax_value, kAXValueCGPointType, None)
            if ok:
                return (float(point.x), float(point.y))
        else:
            try:
                from ApplicationServices import kAXValueCGSizeType
            except ImportError:
                from Quartz import kAXValueCGSizeType
            ok, size = AXValueGetValue(ax_value, kAXValueCGSizeType, None)
            if ok:
                return (float(size.width), float(size.height))
    except Exception:
        pass

    if kind == "point":
        patterns = [
            rf"x\s*[:=]\s*({_FLOAT_RE}).*?y\s*[:=]\s*({_FLOAT_RE})",
            rf"\{{\s*x\s*=\s*({_FLOAT_RE}),\s*y\s*=\s*({_FLOAT_RE})\s*\}}",
        ]
    else:
        patterns = [
            rf"(?:w|width)\s*[:=]\s*({_FLOAT_RE}).*?(?:h|height)\s*[:=]\s*({_FLOAT_RE})",
            rf"\{{\s*width\s*=\s*({_FLOAT_RE}),\s*height\s*=\s*({_FLOAT_RE})\s*\}}",
        ]

    text = str(ax_value)
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return (float(match.group(1)), float(match.group(2)))
    return None


def _get_ax_window_signature(ax_window: Any) -> tuple[str | None, tuple[float, float] | None, tuple[float, float] | None]:
    from ApplicationServices import (
        AXUIElementCopyAttributeValue,
        kAXErrorSuccess,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXTitleAttribute,
    )

    title: str | None = None
    err, ax_title = AXUIElementCopyAttributeValue(ax_window, kAXTitleAttribute, None)
    if err == kAXErrorSuccess and ax_title:
        title = str(ax_title)

    position = None
    err, pos_value = AXUIElementCopyAttributeValue(ax_window, kAXPositionAttribute, None)
    if err == kAXErrorSuccess and pos_value is not None:
        position = _extract_ax_pair(pos_value, "point")

    size = None
    err, size_value = AXUIElementCopyAttributeValue(ax_window, kAXSizeAttribute, None)
    if err == kAXErrorSuccess and size_value is not None:
        size = _extract_ax_pair(size_value, "size")

    return title, position, size


def get_window_bounds(window_id: int) -> tuple[float, float, float, float] | None:
    """Return (x, y, width, height) for a window in screen points."""
    window_list = _get_window_list()
    if not window_list:
        return None
    for w in window_list:
        if w.get("kCGWindowNumber") == window_id:
            bounds = w.get("kCGWindowBounds", {})
            width = float(bounds.get("Width", 0) or 0)
            height = float(bounds.get("Height", 0) or 0)
            if width > 0 and height > 0:
                return (
                    float(bounds.get("X", 0) or 0),
                    float(bounds.get("Y", 0) or 0),
                    width,
                    height,
                )
            return None
    return None


def list_windows(owner_pid: int | None = None) -> list[WindowInfo]:
    window_list = _get_window_list()
    if not window_list:
        return []

    windows: list[WindowInfo] = []
    for w in window_list:
        window_id = int(w.get("kCGWindowNumber", 0) or 0)
        if window_id <= 0:
            continue

        pid = int(w.get("kCGWindowOwnerPID", 0) or 0)
        if owner_pid is not None and pid != owner_pid:
            continue

        if int(w.get("kCGWindowLayer", 0) or 0) != 0:
            continue

        bounds = w.get("kCGWindowBounds", {})
        width = float(bounds.get("Width", 0) or 0)
        height = float(bounds.get("Height", 0) or 0)
        if width <= 0 or height <= 0:
            continue

        windows.append(WindowInfo(
            window_id=window_id,
            owner_pid=pid,
            owner_name=str(w.get("kCGWindowOwnerName")) if w.get("kCGWindowOwnerName") else None,
            title=str(w.get("kCGWindowName")) if w.get("kCGWindowName") else None,
            x=float(bounds.get("X", 0) or 0),
            y=float(bounds.get("Y", 0) or 0),
            width=width,
            height=height,
            onscreen=bool(w.get("kCGWindowIsOnscreen")),
        ))

    return windows


def get_window_pid(window_id: int) -> int | None:
    window_list = _get_window_list()
    if not window_list:
        return None
    for w in window_list:
        if w.get("kCGWindowNumber") == window_id:
            owner_pid = w.get("kCGWindowOwnerPID")
            return int(owner_pid) if owner_pid else None
    return None


def find_window_id_for_ax_window(pid: int, ax_window: Any) -> int | None:
    ax_title_str, ax_position, ax_size = _get_ax_window_signature(ax_window)

    window_list = _get_window_list()
    if not window_list:
        return None

    best_window_id = None
    best_score = float("-inf")

    for w in window_list:
        w_pid = w.get("kCGWindowOwnerPID", 0)
        w_id = w.get("kCGWindowNumber", 0)
        if w_id == 0:
            continue
        w_layer = w.get("kCGWindowLayer", 0)
        if w_layer != 0:
            continue
        bounds = w.get("kCGWindowBounds", {})
        width = float(bounds.get("Width", 0) or 0)
        height = float(bounds.get("Height", 0) or 0)
        if width <= 0 or height <= 0:
            continue

        score = 0.0
        window_name = str(w.get("kCGWindowName", "") or "")

        if w_pid == pid:
            score += 200

        if ax_title_str:
            if window_name == ax_title_str:
                score += 1000
            elif window_name.casefold() == ax_title_str.casefold():
                score += 950
            elif window_name and ax_title_str.casefold() in window_name.casefold():
                score += 700

        if ax_position is not None and ax_size is not None:
            dx = abs(float(bounds.get("X", 0) or 0) - ax_position[0])
            dy = abs(float(bounds.get("Y", 0) or 0) - ax_position[1])
            dw = abs(width - ax_size[0])
            dh = abs(height - ax_size[1])
            score += max(0.0, 600.0 - ((dx + dy) * 4.0) - (dw + dh))

        if w.get("kCGWindowIsOnscreen"):
            score += 50
        if window_name:
            score += 10

        if score > best_score:
            best_score = score
            best_window_id = int(w_id)

    return best_window_id


def capture_window(window_id: int) -> Image.Image | None:
    cg_image = CGWindowListCreateImage(
        CGRectNull,
        kCGWindowListOptionIncludingWindow,
        window_id,
        kCGWindowImageBoundsIgnoreFraming,
    )
    if cg_image is None:
        logger.debug(
            "CGWindowListCreateImage returned None for window %d — "
            "Screen Recording permission may not be granted for this process",
            window_id,
        )
        return None

    width = CGImageGetWidth(cg_image)
    height = CGImageGetHeight(cg_image)
    if width == 0 or height == 0:
        logger.debug(
            "CGWindowListCreateImage returned 0x0 image for window %d",
            window_id,
        )
        return None

    try:
        provider = CGImageGetDataProvider(cg_image)
        data = CGDataProviderCopyData(provider)
        bytes_per_row = CGImageGetBytesPerRow(cg_image)

        img = Image.frombytes("RGBA", (width, height), bytes(data), "raw", "BGRA", bytes_per_row, 1)
        img = img.convert("RGB")
    except Exception as e:
        logger.warning(
            "Failed to decode screenshot for window %d: %s", window_id, e
        )
        return None

    return img


def prepare_image_for_transport(image: Image.Image) -> Image.Image:
    """Resize a screenshot to the size that will be shown to the model."""
    max_width = 1920
    width = getattr(image, "width", None)
    height = getattr(image, "height", None)
    if not isinstance(width, (int, float)) or not isinstance(height, (int, float)):
        return image
    if width <= max_width:
        return image

    ratio = max_width / width
    new_size = (max_width, int(height * ratio))
    return image.resize(new_size, Image.LANCZOS)


def image_to_base64(image: Image.Image) -> str:
    buf = io.BytesIO()
    # PNG optimize=True is extremely slow on large images (10-30s+ for Retina).
    # Use unoptimized PNG which is fast (<100ms) with acceptable size.
    image.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


def check_screen_recording_permission() -> bool:
    """Check Screen Recording permission without prompting.

    Uses ``CGPreflightScreenCaptureAccess`` which returns immediately.
    """
    try:
        from Quartz import CGPreflightScreenCaptureAccess
        return CGPreflightScreenCaptureAccess()
    except (ImportError, AttributeError):
        pass

    # Fallback: check if we can read window names (requires Screen Recording)
    try:
        window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID)
        if window_list is None:
            return False
        for w in window_list:
            name = w.get("kCGWindowName")
            if name is not None and len(str(name)) > 0:
                return True
        return False
    except Exception:
        return False


def prompt_screen_recording_permission() -> bool:
    """Prompt for Screen Recording permission and return current state.

    ``CGRequestScreenCaptureAccess`` shows the system dialog and returns
    immediately — it never blocks waiting for the user to grant access.
    """
    try:
        from Quartz import CGRequestScreenCaptureAccess, CGPreflightScreenCaptureAccess
        CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    except (ImportError, AttributeError):
        return check_screen_recording_permission()
