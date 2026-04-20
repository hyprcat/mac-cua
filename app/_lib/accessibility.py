from __future__ import annotations

import logging
import re
import time
from typing import Any

from ApplicationServices import (
    AXIsProcessTrustedWithOptions,
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    AXUIElementCopyMultipleAttributeValues,
    AXUIElementCopyAttributeNames,
    AXUIElementCopyActionNames,
    AXUIElementPerformAction,
    AXUIElementSetAttributeValue,
    AXUIElementIsAttributeSettable,
    kAXErrorSuccess,
    kAXFocusedUIElementAttribute,
    kAXWindowsAttribute,
    kAXMainWindowAttribute,
    kAXFocusedWindowAttribute,
    kAXRoleAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXPositionAttribute,
    kAXSizeAttribute,
    kAXValueAttribute,
    kAXChildrenAttribute,
    kAXSubroleAttribute,
    kAXIdentifierAttribute,
    kAXEnabledAttribute,
    kAXSelectedAttribute,
    kAXExpandedAttribute,
    kAXFocusedAttribute,
    kAXRoleDescriptionAttribute,
    kAXPressAction,
)
from Foundation import CFEqual

from app.response import Node
from app._lib.errors import AXError, StaleReferenceError, ax_error
from app._lib.observer import AXEnablementKind, AssertionTracker

logger = logging.getLogger(__name__)


_BATCH_ATTRS = [
    kAXRoleAttribute,
    kAXTitleAttribute,
    kAXDescriptionAttribute,
    kAXValueAttribute,
    kAXSubroleAttribute,
    kAXIdentifierAttribute,
    kAXRoleDescriptionAttribute,
    kAXEnabledAttribute,
    kAXSelectedAttribute,
    kAXExpandedAttribute,
    kAXFocusedAttribute,
    kAXChildrenAttribute,
]

_SKIP_ROLES = frozenset([
    "AXGroup", "AXSplitGroup", "AXSplitter", "AXScrollBar",
    "AXGrowArea", "AXUnknown",
])

_INTERACTIVE_ROLES = frozenset([
    "AXButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
    "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
    "AXComboBox", "AXIncrementor", "AXLink", "AXRow",
    "AXMenuItem", "AXTab", "AXDisclosureTriangle",
])

_ACTIONABLE_ROLES = _INTERACTIVE_ROLES | frozenset([
    "AXWindow", "AXScrollArea", "AXOutline", "AXTable", "AXList", "AXSplitter",
    "AXMenuBarItem", "AXToolbar",
])

_STATE_MAP = {
    kAXEnabledAttribute: ("disabled", True),
    kAXSelectedAttribute: ("selected", False),
    kAXExpandedAttribute: ("expanded", False),
    kAXFocusedAttribute: ("focused", False),
}


def check_accessibility_permission(prompt: bool = False) -> bool:
    """Check (and optionally prompt for) Accessibility permission.

    ``AXIsProcessTrustedWithOptions`` shows the system dialog when *prompt*
    is True but always returns the **current** trust state immediately —
    it never blocks waiting for the user to grant access.
    """
    opts = {str("AXTrustedCheckOptionPrompt"): prompt}
    return AXIsProcessTrustedWithOptions(opts)


def create_ax_app(pid: int) -> Any:
    return AXUIElementCreateApplication(pid)


def get_key_window(ax_app: Any) -> Any | None:
    err, val = AXUIElementCopyAttributeValue(ax_app, kAXFocusedWindowAttribute, None)
    if err == kAXErrorSuccess and val is not None:
        return val
    err, val = AXUIElementCopyAttributeValue(ax_app, kAXMainWindowAttribute, None)
    if err == kAXErrorSuccess and val is not None:
        return val
    err, val = AXUIElementCopyAttributeValue(ax_app, kAXWindowsAttribute, None)
    if err == kAXErrorSuccess and val and len(val) > 0:
        return val[0]
    return None


def get_windows(ax_app: Any) -> list[Any]:
    windows: list[Any] = []

    err, all_windows = AXUIElementCopyAttributeValue(ax_app, kAXWindowsAttribute, None)
    if err == kAXErrorSuccess and all_windows:
        windows.extend(all_windows)

    for attr in (kAXFocusedWindowAttribute, kAXMainWindowAttribute):
        err, window = AXUIElementCopyAttributeValue(ax_app, attr, None)
        if err != kAXErrorSuccess or window is None:
            continue
        if any(CFEqual(existing, window) for existing in windows):
            continue
        windows.insert(0, window)

    return windows


def _is_ax_error_value(v: Any) -> bool:
    s = str(type(v))
    if "AXValue" in s or "error" in str(v):
        return True
    return False


def _read_attrs(element: Any) -> dict[str, Any]:
    err, values = AXUIElementCopyMultipleAttributeValues(element, _BATCH_ATTRS, 0, None)
    result = {}
    if err != kAXErrorSuccess or values is None:
        if err != kAXErrorSuccess:
            logger.debug("AXUIElementCopyMultipleAttributeValues failed: %d", err)
        return result
    for i, attr in enumerate(_BATCH_ATTRS):
        v = values[i]
        if v is None:
            continue
        if isinstance(v, (str, int, float, bool)):
            result[attr] = v
        elif isinstance(v, (list, tuple)):
            result[attr] = v
        elif hasattr(v, "objCType"):
            try:
                result[attr] = v.boolValue() if v.objCType() == b"B" else v.intValue()
            except Exception:
                logger.debug("Failed to extract NSNumber value for attr %s", attr)
        elif _is_ax_error_value(v):
            logger.debug("AX error value for attr %s: %s", attr, v)
        else:
            result[attr] = v
    return result


def _get_actions(element: Any, role: str) -> list[str]:
    if role not in _ACTIONABLE_ROLES:
        return []
    err, actions = AXUIElementCopyActionNames(element, None)
    if err != kAXErrorSuccess or actions is None:
        return []
    skip = {"AXPress", "AXCancel", "AXConfirm", "AXShowMenu"}
    return [str(a) for a in actions if str(a) not in skip]


def _resolve_label(attrs: dict[str, Any], role: str) -> str | None:
    title = attrs.get(kAXTitleAttribute)
    if title and str(title).strip():
        return str(title).strip()
    desc = attrs.get(kAXDescriptionAttribute)
    if desc and str(desc).strip():
        return str(desc).strip()
    value = attrs.get(kAXValueAttribute)
    if value is not None and role in ("AXStaticText", "AXMenuItem", "AXLink"):
        s = str(value).strip()
        if s:
            return s
    return None


def _build_states(element: Any, attrs: dict[str, Any]) -> list[str]:
    states = []
    for attr, (state_name, invert) in _STATE_MAP.items():
        val = attrs.get(attr)
        if val is None:
            continue
        if invert:
            if not val:
                states.append(state_name)
        else:
            if val:
                states.append(state_name)
    err, settable = AXUIElementIsAttributeSettable(element, kAXValueAttribute, None)
    if err == kAXErrorSuccess and settable:
        states.append("settable")
    role = attrs.get(kAXRoleAttribute, "")
    if role == "AXRow":
        err2, selectable = AXUIElementIsAttributeSettable(element, kAXSelectedAttribute, None)
        if err2 == kAXErrorSuccess and selectable:
            if "selected" not in states:
                states.append("selectable")
    states.sort()
    return states


_MAX_CHILDREN_PER_ELEMENT = 100


def walk_tree(
    ax_element: Any,
    max_depth: int = 50,
    max_nodes: int = 5000,
    *,
    include_actions: bool = True,
    include_states: bool = True,
    target_pid: int | None = None,
) -> list[Node]:
    from collections import deque

    # Track AX read assertion for coordinated access
    if target_pid is not None:
        AssertionTracker.acquire(target_pid, AXEnablementKind.READ_ATTRIBUTES)

    nodes: list[Node] = []
    queue: deque[tuple[Any, int]] = deque([(ax_element, 0)])

    while queue and len(nodes) < max_nodes:
        element, depth = queue.popleft()
        if depth > max_depth:
            continue

        attrs = _read_attrs(element)
        role = str(attrs.get(kAXRoleAttribute, "AXUnknown"))
        role_desc = attrs.get(kAXRoleDescriptionAttribute)
        display_role = str(role_desc) if role_desc else role.removeprefix("AX").lower()

        label = _resolve_label(attrs, role)
        states = _build_states(element, attrs) if include_states else []
        description_raw = attrs.get(kAXDescriptionAttribute)
        description = str(description_raw).strip() if description_raw and str(description_raw).strip() else None
        value_raw = attrs.get(kAXValueAttribute)
        value = str(value_raw) if value_raw is not None else None
        ax_id_raw = attrs.get(kAXIdentifierAttribute)
        ax_id = str(ax_id_raw) if ax_id_raw else None
        secondary_actions = _get_actions(element, role) if include_actions else []

        # Web area detection
        is_web_area = role == "AXWebArea"

        # OOP detection: element PID differs from target PID
        element_pid = _get_element_pid(element)
        is_oop = (
            target_pid is not None
            and element_pid is not None
            and element_pid != target_pid
        )

        # Link URL extraction for AXLink elements
        link_url: str | None = None
        if role == "AXLink":
            link_url = _get_link_url(element)

        index = len(nodes)
        nodes.append(Node(
            index=index,
            role=display_role,
            label=label,
            states=states,
            description=description,
            value=value,
            ax_id=ax_id,
            secondary_actions=secondary_actions,
            depth=depth,
            ax_ref=element,
            ax_role=role,
            is_web_area=is_web_area,
            is_oop=is_oop,
            element_pid=element_pid,
            url=link_url,
        ))

        children = attrs.get(kAXChildrenAttribute)
        if children:
            # Cap children per element so one large table doesn't starve siblings
            for child in children[:_MAX_CHILDREN_PER_ELEMENT]:
                queue.append((child, depth + 1))

    # Release AX read assertion
    if target_pid is not None:
        AssertionTracker.release(target_pid, AXEnablementKind.READ_ATTRIBUTES)

    return nodes


def _get_element_pid(element: Any) -> int | None:
    """Extract the PID of the process owning an AX element."""
    try:
        from ApplicationServices import AXUIElementGetPid
        err, pid = AXUIElementGetPid(element, None)
        if err == kAXErrorSuccess:
            return pid
    except (ImportError, Exception):
        pass
    return None


def get_focused_element(ax_app: Any, tree: list[Node]) -> int | None:
    err, focused = AXUIElementCopyAttributeValue(ax_app, kAXFocusedUIElementAttribute, None)
    if err != kAXErrorSuccess or focused is None:
        return None
    for node in tree:
        if node.ax_ref is not None and CFEqual(node.ax_ref, focused):
            return node.index
    return None


def _extract_point(ax_value: Any) -> tuple[float, float] | None:
    """Extract (x, y) from an AXValue of type kAXValueCGPointType."""
    try:
        try:
            from ApplicationServices import AXValueGetValue
        except ImportError:
            from Quartz import AXValueGetValue
        from Quartz import kAXValueCGPointType
        ok, point = AXValueGetValue(ax_value, kAXValueCGPointType, None)
        if ok:
            return (float(point.x), float(point.y))
    except Exception:
        pass

    text = str(ax_value)
    patterns = [
        r"x\s*[:=]\s*(-?\d+(?:\.\d+)?).*?y\s*[:=]\s*(-?\d+(?:\.\d+)?)",
        r"\{\s*x\s*=\s*(-?\d+(?:\.\d+)?),\s*y\s*=\s*(-?\d+(?:\.\d+)?)\s*\}",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return (float(match.group(1)), float(match.group(2)))
    return None


def _extract_size(ax_value: Any) -> tuple[float, float] | None:
    """Extract (w, h) from an AXValue of type kAXValueCGSizeType."""
    try:
        try:
            from ApplicationServices import AXValueGetValue
        except ImportError:
            from Quartz import AXValueGetValue
        from Quartz import kAXValueCGSizeType
        ok, size = AXValueGetValue(ax_value, kAXValueCGSizeType, None)
        if ok:
            return (float(size.width), float(size.height))
    except Exception:
        pass

    text = str(ax_value)
    patterns = [
        r"(?:w|width)\s*[:=]\s*(-?\d+(?:\.\d+)?).*?(?:h|height)\s*[:=]\s*(-?\d+(?:\.\d+)?)",
        r"\{\s*width\s*=\s*(-?\d+(?:\.\d+)?),\s*height\s*=\s*(-?\d+(?:\.\d+)?)\s*\}",
    ]
    for pattern in patterns:
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            return (float(match.group(1)), float(match.group(2)))
    return None


def get_element_position(node: Node) -> tuple[float | None, float | None]:
    """Get the screen-coordinate center of an element via AXPosition + AXSize."""
    if node.ax_ref is None:
        return (None, None)

    err_p, pos_val = AXUIElementCopyAttributeValue(node.ax_ref, kAXPositionAttribute, None)
    err_s, size_val = AXUIElementCopyAttributeValue(node.ax_ref, kAXSizeAttribute, None)
    if err_p != kAXErrorSuccess or err_s != kAXErrorSuccess:
        return (None, None)
    if pos_val is None or size_val is None:
        return (None, None)

    point = _extract_point(pos_val)
    size = _extract_size(size_val)
    if point is None or size is None:
        return (None, None)

    px, py = point
    sw, sh = size
    return (px + sw / 2, py + sh / 2)


def perform_action(node: Node, action: str = "AXPress") -> None:
    if node.ax_ref is None:
        raise AXError("Node has no AX reference")
    # Track AX action assertion
    pid = node.element_pid
    if pid is not None:
        AssertionTracker.acquire(pid, AXEnablementKind.PERFORM_ACTIONS)
    try:
        err = AXUIElementPerformAction(node.ax_ref, action)
        if err != kAXErrorSuccess:
            if err in (-25205, -25212):
                raise StaleReferenceError(f"Element reference stale (AX error {err})", code=err)
            raise ax_error(err, f"perform action {action}")
    finally:
        if pid is not None:
            AssertionTracker.release(pid, AXEnablementKind.PERFORM_ACTIONS)


def perform_action_on_ref(ax_ref: Any, action: str = "AXPress") -> None:
    """Perform an AX action on a raw element reference (no Node wrapper)."""
    err = AXUIElementPerformAction(ax_ref, action)
    if err != kAXErrorSuccess:
        raise ax_error(err, f"perform action {action}")


def element_at_position(ax_app: Any, x: float, y: float) -> Any | None:
    """Return the deepest AX element at screen point (x, y) within *ax_app*.

    Works regardless of whether the app is frontmost — the AX framework
    resolves the hit-test against the app's own element tree, not the
    system window stack.
    """
    from ApplicationServices import AXUIElementCopyElementAtPosition
    err, element = AXUIElementCopyElementAtPosition(ax_app, x, y, None)
    if err == kAXErrorSuccess and element is not None:
        return element
    return None


def set_attribute(node: Node, attr: str, value: Any) -> None:
    if node.ax_ref is None:
        raise AXError("Node has no AX reference")
    # Track AX write assertion
    pid = node.element_pid
    if pid is not None:
        AssertionTracker.acquire(pid, AXEnablementKind.WRITE_ATTRIBUTES)
    try:
        err = AXUIElementSetAttributeValue(node.ax_ref, attr, value)
        if err != kAXErrorSuccess:
            if err in (-25205, -25212):
                raise StaleReferenceError(f"Element reference stale (AX error {err})", code=err)
            raise ax_error(err, f"set attribute {attr}")
    finally:
        if pid is not None:
            AssertionTracker.release(pid, AXEnablementKind.WRITE_ATTRIBUTES)


_INTERACTIVE_DISPLAY_ROLES = frozenset(
    r.removeprefix("AX").lower() for r in _INTERACTIVE_ROLES
)


def has_interactive_elements(nodes: list[Node]) -> bool:
    return any(node.role in _INTERACTIVE_DISPLAY_ROLES for node in nodes)


# ---------------------------------------------------------------------------
# EditableTextObject — precise text manipulation via AX
# ---------------------------------------------------------------------------

class EditableTextObject:
    """Precise text manipulation via AX attributes.

    Provides methods for reading and modifying text content, cursor position,
    and text selection on AX text elements (AXTextField, AXTextArea, etc.).

    Properties / methods:
    - text, selected_text, selected_text_range, number_of_characters
    - set_text(), set_selected_text_range(), insert_text()
    """

    def __init__(self, element: Any, pid: int | None = None) -> None:
        self._element = element
        self._pid = pid

    @property
    def text(self) -> str:
        """Full text content of the element."""
        err, value = AXUIElementCopyAttributeValue(self._element, kAXValueAttribute, None)
        if err == kAXErrorSuccess and value is not None:
            return str(value)
        return ""

    @property
    def selected_text(self) -> str | None:
        """Currently selected text, or None."""
        err, value = AXUIElementCopyAttributeValue(self._element, "AXSelectedText", None)
        if err == kAXErrorSuccess and value is not None:
            text = str(value)
            return text if text else None
        return None

    @property
    def selected_text_range(self) -> tuple[int, int] | None:
        """Selected text range as (location, length), or None."""
        err, value = AXUIElementCopyAttributeValue(
            self._element, "AXSelectedTextRange", None,
        )
        if err != kAXErrorSuccess or value is None:
            return None
        try:
            r = value.rangeValue()
            return (r.location, r.length)
        except Exception:
            return None

    @property
    def number_of_characters(self) -> int:
        """Number of characters in the element."""
        err, value = AXUIElementCopyAttributeValue(
            self._element, "AXNumberOfCharacters", None,
        )
        if err == kAXErrorSuccess and value is not None:
            try:
                return int(value)
            except (ValueError, TypeError):
                pass
        # Fallback: measure text length
        return len(self.text)

    def set_text(self, text: str) -> None:
        """Replace entire value of the element."""
        if self._pid is not None:
            AssertionTracker.acquire(self._pid, AXEnablementKind.WRITE_ATTRIBUTES)
        try:
            err = AXUIElementSetAttributeValue(self._element, kAXValueAttribute, text)
            if err != kAXErrorSuccess:
                raise ax_error(err, "set text via AXValue")
        finally:
            if self._pid is not None:
                AssertionTracker.release(self._pid, AXEnablementKind.WRITE_ATTRIBUTES)

    def set_selected_text_range(self, start: int, length: int) -> None:
        """Position cursor (length=0) or set selection (length>0)."""
        from Foundation import NSValue, NSMakeRange
        range_val = NSValue.valueWithRange_(NSMakeRange(start, length))
        if self._pid is not None:
            AssertionTracker.acquire(self._pid, AXEnablementKind.WRITE_ATTRIBUTES)
        try:
            err = AXUIElementSetAttributeValue(
                self._element, "AXSelectedTextRange", range_val,
            )
            if err != kAXErrorSuccess:
                raise ax_error(err, "set selected text range")
        finally:
            if self._pid is not None:
                AssertionTracker.release(self._pid, AXEnablementKind.WRITE_ATTRIBUTES)

    def insert_text(self, text: str) -> None:
        """Insert text at the current cursor position (not replace all).

        Uses AXSelectedText attribute to replace only the current selection
        (which is empty at cursor position, effectively inserting).
        """
        if self._pid is not None:
            AssertionTracker.acquire(self._pid, AXEnablementKind.WRITE_ATTRIBUTES)
        try:
            err = AXUIElementSetAttributeValue(self._element, "AXSelectedText", text)
            if err != kAXErrorSuccess:
                raise ax_error(err, "insert text via AXSelectedText")
        finally:
            if self._pid is not None:
                AssertionTracker.release(self._pid, AXEnablementKind.WRITE_ATTRIBUTES)


# ---------------------------------------------------------------------------
# Web content extraction
# ---------------------------------------------------------------------------

def extract_web_area_text(
    element: Any,
    target_pid: int | None = None,
) -> str | None:
    """Extract rich text from AXWebArea nodes with Markdown formatting.

    Parameters
    ----------
    element:
        An AXUIElement — typically an AXWebArea node detected during tree walk.
    target_pid:
        PID of the target app (for OOP detection).

    Returns
    -------
    Markdown-formatted text content, or None if extraction fails.
    """
    if element is None:
        return None

    # Check for OOP element (cross-process AX, e.g. Safari WebContent)
    element_pid = _get_element_pid(element)
    if target_pid is not None and element_pid is not None and element_pid != target_pid:
        logger.debug(
            "Web area element is OOP (element_pid=%d, target_pid=%d)",
            element_pid, target_pid,
        )

    return _extract_attributed_text(element)


def extract_text_area_content(
    element: Any,
    target_pid: int | None = None,
) -> str | None:
    """Extract rich text from text areas (code editors, rich text fields).

    Parameters
    ----------
    element:
        An AXUIElement — typically an AXTextArea or AXTextField node.
    target_pid:
        PID of the target app (for OOP detection).

    Returns
    -------
    Markdown-formatted text content, or None if extraction fails.
    """
    if element is None:
        return None

    # Check for OOP element
    element_pid = _get_element_pid(element)
    if target_pid is not None and element_pid is not None and element_pid != target_pid:
        logger.debug(
            "Text area element is OOP (element_pid=%d, target_pid=%d)",
            element_pid, target_pid,
        )

    return _extract_attributed_text(element)


def _extract_attributed_text(element: Any) -> str | None:
    """Extract attributed text from an element via text marker APIs.

    Tries AXAttributedStringForTextMarkerRange with full document range,
    then falls back to plain AXValue.
    """
    try:
        from ApplicationServices import AXUIElementCopyParameterizedAttributeValue

        # Try to get the full document text marker range
        err, start_marker = AXUIElementCopyAttributeValue(
            element, "AXStartTextMarker", None,
        )
        err2, end_marker = AXUIElementCopyAttributeValue(
            element, "AXEndTextMarker", None,
        )

        if (
            err == kAXErrorSuccess
            and err2 == kAXErrorSuccess
            and start_marker is not None
            and end_marker is not None
        ):
            # Create a text marker range for the full document
            from ApplicationServices import AXTextMarkerRangeCreate
            full_range = AXTextMarkerRangeCreate(None, start_marker, end_marker)

            if full_range is not None:
                # Get attributed string
                err, attributed = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXAttributedStringForTextMarkerRange",
                    full_range,
                    None,
                )
                if err == kAXErrorSuccess and attributed is not None:
                    from app._lib.markdown_writer import AttributedStringMarkdownWriter
                    writer = AttributedStringMarkdownWriter()
                    text = writer.write(attributed)
                    if text and text.strip():
                        return text.strip()

        # Fallback: try AXStringForTextMarkerRange
        if (
            err == kAXErrorSuccess
            and err2 == kAXErrorSuccess
            and start_marker is not None
            and end_marker is not None
        ):
            from ApplicationServices import AXTextMarkerRangeCreate
            full_range = AXTextMarkerRangeCreate(None, start_marker, end_marker)
            if full_range is not None:
                err, plain = AXUIElementCopyParameterizedAttributeValue(
                    element,
                    "AXStringForTextMarkerRange",
                    full_range,
                    None,
                )
                if err == kAXErrorSuccess and plain is not None:
                    text = str(plain).strip()
                    if text:
                        return text

    except ImportError:
        logger.debug("AXTextMarker APIs not available")
    except Exception as exc:
        logger.debug("Attributed text extraction failed: %s", exc)

    # Final fallback: plain AXValue
    try:
        err, value = AXUIElementCopyAttributeValue(element, kAXValueAttribute, None)
        if err == kAXErrorSuccess and value is not None:
            text = str(value).strip()
            if text:
                return text
    except Exception:
        pass

    return None


def _get_link_url(element: Any) -> str | None:
    """Get the URL of an AXLink element via AXURL attribute."""
    try:
        err, value = AXUIElementCopyAttributeValue(element, "AXURL", None)
        if err == kAXErrorSuccess and value is not None:
            return str(value)
    except Exception:
        pass
    return None


def get_web_url(element: Any) -> str | None:
    """Get the URL of an AXWebArea element."""
    try:
        err, value = AXUIElementCopyAttributeValue(element, "AXURL", None)
        if err == kAXErrorSuccess and value is not None:
            return str(value)
    except Exception:
        pass
    return None
