"""VirtualCursor protocol, BackgroundCursor, InputStrategy, AppType detection,
VirtualKeyPress, and WindowUIElement.

Classes:
- VirtualKeyPress: validated key press
- AppType: heuristic app type detection for input strategy selection
- InputStrategy: per-app-type input strategy matrix
- VirtualCursor (Protocol): abstract cursor operations
- BackgroundCursor: invisible cursor for headless MCP operation
- WindowUIElement: programmatic window control via AX attributes
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# VirtualKeyPress — validated key press
# ---------------------------------------------------------------------------

class KeyPressError(Enum):
    """Key validation error codes."""
    MULTIPLE_NON_MODIFIER_KEYS = "multiple_non_modifier_keys"
    NO_NON_MODIFIER_KEYS = "no_non_modifier_keys"
    FAILED_TO_TRANSLATE = "unknown_key"


@dataclass(frozen=True)
class VirtualKeyPress:
    """Validated key press.

    Created from a key combo string; validates that the combo has exactly
    one non-modifier key and all keys translate to valid keycodes.
    """
    keycode: int
    modifier_mask: int
    description: str

    @classmethod
    def from_combo(cls, combo: str) -> VirtualKeyPress:
        """Parse and validate key combo string.

        Raises ValueError on validation failure.
        """
        from app._lib.keys import parse_key_combo
        keycode, mask = parse_key_combo(combo)
        return cls(keycode=keycode, modifier_mask=mask, description=combo)


# ---------------------------------------------------------------------------
# AppType — heuristic app type detection
# ---------------------------------------------------------------------------

class AppType(Enum):
    """Application framework type, used for input strategy selection."""
    NATIVE_COCOA = "cocoa"
    ELECTRON = "electron"
    BROWSER = "browser"
    JAVA = "java"
    QT = "qt"
    UNKNOWN = "unknown"


class DeliveryMethod(Enum):
    """Primary event delivery pipeline."""
    CGEVENT_PID = "cgevent_pid"      # CGEventPostToPid — works for native Cocoa
    SKYLIGHT_SPI = "skylight_spi"    # CGSPostKeyboardEventToProcess — works for Electron/browser/Java/Qt


class ActivationPolicy(Enum):
    """When to use invisible micro-activation."""
    NEVER = "never"            # Never micro-activate (AX actions, native Cocoa CGEvent)
    RETRY_ONLY = "retry_only"  # Only on retry after background delivery failed


# Known browser bundle IDs
_BROWSER_BUNDLES: frozenset[str] = frozenset({
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Dev",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "com.operasoftware.Opera",
    "company.thebrowser.Browser",  # Arc
})

# Known Electron apps
_ELECTRON_BUNDLES: frozenset[str] = frozenset({
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
    "com.spotify.client",
    "com.github.GitHubClient",
    "com.todesktop.230313mzl4w4u92",  # Cursor
    "notion.id",
    "com.figma.Desktop",
    "com.linear",
    "com.obsproject.obs-studio",
})


def detect_app_type(bundle_id: str, pid: int) -> AppType:
    """Heuristic app type detection based on bundle ID and process info.

    Detection order:
    1. Known browser bundle IDs
    2. Known Electron bundle IDs
    3. Check for Electron Framework in loaded libraries
    4. Check for Java/Qt frameworks
    5. Default to NATIVE_COCOA
    """
    if bundle_id in _BROWSER_BUNDLES:
        return AppType.BROWSER

    if bundle_id in _ELECTRON_BUNDLES:
        return AppType.ELECTRON

    # Try to detect framework from process info
    try:
        import subprocess
        # Check loaded libraries for framework detection (fast, cached by OS)
        result = subprocess.run(
            ["lsof", "-p", str(pid), "-Fn"],
            capture_output=True, text=True, timeout=2,
        )
        libs = result.stdout

        if "Electron Framework" in libs or "electron" in libs.lower():
            return AppType.ELECTRON
        if "libjvm" in libs or "JavaNativeFoundation" in libs:
            return AppType.JAVA
        if "QtCore" in libs or "QtWidgets" in libs:
            return AppType.QT
    except Exception:
        pass

    return AppType.NATIVE_COCOA


# ---------------------------------------------------------------------------
# InputStrategy — per-app-type input strategy selection
# ---------------------------------------------------------------------------

class InputStrategy:
    """Per-app-type input strategy selection.

    Strategy matrix (from spec):
    | App Type      | Click         | Type          | Scroll      | Focus     |
    |---------------|---------------|---------------|-------------|-----------|
    | Native Cocoa  | AX preferred  | AX set value  | AX scroll   | AX focus  |
    | Electron      | CGEvent pref  | CGEvent keys  | CGEvent whl | CGEvent   |
    | Browser (web) | CGEvent always| CGEvent keys  | CGEvent whl | CGEvent   |
    | Browser (UI)  | AX preferred  | AX set value  | AX scroll   | AX focus  |
    | Java/Qt       | CGEvent always| CGEvent keys  | CGEvent whl | CGEvent   |
    """

    def __init__(self, app_type: AppType, force_simulate: bool = False) -> None:
        self._app_type = app_type
        self._force_simulate = force_simulate
        self._ax_failure_count = 0

    @property
    def app_type(self) -> AppType:
        return self._app_type

    def should_use_ax_action(self, action: str, is_web_area: bool = False) -> bool:
        """Whether to prefer AX action or CGEvent for this action type.

        Args:
            action: The action type ("click", "type", "scroll", "focus")
            is_web_area: Whether the target element is inside a web area
        """
        if self._force_simulate:
            return False

        if self._ax_failure_count >= 2:
            return False  # Auto-escalate after repeated failures

        # Browser web content always uses CGEvent
        if self._app_type == AppType.BROWSER and is_web_area:
            return False

        # Java/Qt always use CGEvent
        if self._app_type in (AppType.JAVA, AppType.QT, AppType.UNKNOWN):
            return False

        # Electron prefers CGEvent for most operations
        if self._app_type == AppType.ELECTRON:
            # Electron AX click is unreliable — prefer CGEvent
            return action in ("focus",)  # Only AX focus works well in Electron

        # Native Cocoa and browser chrome: AX preferred
        return True

    def record_ax_failure(self) -> None:
        """Record an AX action failure for auto-escalation."""
        self._ax_failure_count += 1
        logger.debug(
            "[InputStrategy] AX failure count: %d (app_type=%s)",
            self._ax_failure_count, self._app_type.value,
        )

    def reset_failures(self) -> None:
        """Reset failure count (e.g., on new session)."""
        self._ax_failure_count = 0

    @property
    def delivery_method(self) -> DeliveryMethod:
        """Primary delivery pipeline for this app type."""
        if self._app_type in (AppType.NATIVE_COCOA, AppType.UNKNOWN):
            return DeliveryMethod.CGEVENT_PID
        return DeliveryMethod.SKYLIGHT_SPI

    @property
    def alternate_delivery_method(self) -> DeliveryMethod:
        """Fallback delivery pipeline."""
        if self.delivery_method == DeliveryMethod.CGEVENT_PID:
            return DeliveryMethod.SKYLIGHT_SPI
        return DeliveryMethod.CGEVENT_PID

    @property
    def activation_policy(self) -> ActivationPolicy:
        """When to use micro-activation for regular actions."""
        if self._app_type in (AppType.NATIVE_COCOA, AppType.UNKNOWN):
            return ActivationPolicy.NEVER
        return ActivationPolicy.RETRY_ONLY

    @property
    def activation_policy_for_popup(self) -> ActivationPolicy:
        """Popups always qualify for micro-activation retry."""
        return ActivationPolicy.RETRY_ONLY


# ---------------------------------------------------------------------------
# VirtualCursor — abstract cursor operations protocol
# ---------------------------------------------------------------------------

@runtime_checkable
class VirtualCursor(Protocol):
    """Abstract cursor operations. Decoupled from controller."""

    @property
    def position(self) -> tuple[float, float]:
        """Current cursor position in screen coordinates."""
        ...

    @property
    def position_in_scaled_coordinates(self) -> tuple[float, float]:
        """Current position in scaled (screenshot) coordinates."""
        ...

    def move_to(self, position: tuple[float, float], animated: bool = False) -> None:
        """Move cursor to position."""
        ...

    def click_at(self, position: tuple[float, float]) -> None:
        """Single left click at position."""
        ...

    def double_click_at(self, position: tuple[float, float]) -> None:
        """Double click at position."""
        ...

    def right_click_at(self, position: tuple[float, float]) -> None:
        """Right click at position."""
        ...

    def drag(self, from_pos: tuple[float, float], to_pos: tuple[float, float]) -> None:
        """Drag from one position to another."""
        ...


# ---------------------------------------------------------------------------
# BackgroundCursor — invisible cursor for headless MCP operation
# ---------------------------------------------------------------------------

class BackgroundCursor:
    """Invisible cursor for headless MCP operation.

    Uses CGEventPostToPid for all operations — no visual feedback,
    no user interference. This is the primary cursor for our MCP server.
    """

    def __init__(self, pid: int, window_id: int) -> None:
        self._pid = pid
        self._window_id = window_id
        self._position: tuple[float, float] = (0.0, 0.0)
        self._scale_factor: float = 1.0
        self._screenshot_size: tuple[int, int] | None = None

    @property
    def position(self) -> tuple[float, float]:
        return self._position

    @property
    def position_in_scaled_coordinates(self) -> tuple[float, float]:
        return (
            self._position[0] / self._scale_factor,
            self._position[1] / self._scale_factor,
        )

    def set_screenshot_size(self, size: tuple[int, int]) -> None:
        """Set screenshot dimensions for coordinate conversion."""
        self._screenshot_size = size

    def move_to(self, position: tuple[float, float], animated: bool = False) -> None:
        """Move cursor position (no visual, just track internally)."""
        self._position = position

    def click_at(self, position: tuple[float, float]) -> None:
        """Click via CGEventPostToPid."""
        from app._lib import input as cg_input
        self._position = position
        cg_input.click_at(
            self._pid, self._window_id,
            position[0], position[1],
            button="left", count=1,
            screenshot_size=self._screenshot_size,
        )

    def double_click_at(self, position: tuple[float, float]) -> None:
        """Double-click via CGEventPostToPid."""
        from app._lib import input as cg_input
        self._position = position
        cg_input.click_at(
            self._pid, self._window_id,
            position[0], position[1],
            button="left", count=2,
            screenshot_size=self._screenshot_size,
        )

    def right_click_at(self, position: tuple[float, float]) -> None:
        """Right-click via CGEventPostToPid."""
        from app._lib import input as cg_input
        self._position = position
        cg_input.click_at(
            self._pid, self._window_id,
            position[0], position[1],
            button="right", count=1,
            screenshot_size=self._screenshot_size,
        )

    def drag(self, from_pos: tuple[float, float], to_pos: tuple[float, float]) -> None:
        """Drag via CGEventPostToPid."""
        from app._lib import input as cg_input
        self._position = to_pos
        cg_input.drag(
            self._pid, self._window_id,
            from_pos[0], from_pos[1],
            to_pos[0], to_pos[1],
            screenshot_size=self._screenshot_size,
        )


# ---------------------------------------------------------------------------
# WindowUIElement — programmatic window control
# ---------------------------------------------------------------------------

class WindowUIElement:
    """Programmatic window control via AX attributes.

    Properties / methods:
    - window_id, is_minimized, is_full_screen
    - set_position, set_size, raise_window
    """

    def __init__(self, ax_window: Any, window_id: int) -> None:
        self._ax_window = ax_window
        self._window_id = window_id

    @property
    def window_id(self) -> int:
        return self._window_id

    @property
    def is_minimized(self) -> bool:
        try:
            from ApplicationServices import AXUIElementCopyAttributeValue
            err, val = AXUIElementCopyAttributeValue(self._ax_window, "AXMinimized", None)
            return bool(val) if err == 0 else False
        except Exception:
            return False

    @property
    def is_full_screen(self) -> bool:
        try:
            from ApplicationServices import AXUIElementCopyAttributeValue
            err, val = AXUIElementCopyAttributeValue(self._ax_window, "AXFullScreen", None)
            return bool(val) if err == 0 else False
        except Exception:
            return False

    def set_position(self, point: tuple[float, float]) -> None:
        """Set window position via AXPosition."""
        try:
            from ApplicationServices import AXUIElementSetAttributeValue
            from CoreFoundation import CGPointMake
            from ApplicationServices import AXValueCreate, kAXValueCGPointType
            ax_point = AXValueCreate(kAXValueCGPointType, CGPointMake(point[0], point[1]))
            AXUIElementSetAttributeValue(self._ax_window, "AXPosition", ax_point)
        except Exception as e:
            logger.debug("[WindowUIElement] Failed to set position: %s", e)

    def set_size(self, size: tuple[float, float]) -> None:
        """Set window size via AXSize."""
        try:
            from ApplicationServices import AXUIElementSetAttributeValue
            from CoreFoundation import CGSizeMake
            from ApplicationServices import AXValueCreate, kAXValueCGSizeType
            ax_size = AXValueCreate(kAXValueCGSizeType, CGSizeMake(size[0], size[1]))
            AXUIElementSetAttributeValue(self._ax_window, "AXSize", ax_size)
        except Exception as e:
            logger.debug("[WindowUIElement] Failed to set size: %s", e)

    def raise_window(self) -> None:
        """Bring window to front via AXRaise."""
        try:
            from ApplicationServices import AXUIElementPerformAction
            AXUIElementPerformAction(self._ax_window, "AXRaise")
        except Exception as e:
            logger.debug("[WindowUIElement] Failed to raise: %s", e)
