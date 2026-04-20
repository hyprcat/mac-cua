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
    kAXParentAttribute,
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
    "AXValueDescription",
    "AXPlaceholderValue",
    "AXHelp",
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

_SUBROLE_DISPLAY_OVERRIDES = {
    "AXStandardWindow": "standard window",
    "AXCollectionList": "collection",
    "AXSectionList": "section",
    "AXSearchField": "search text field",
    "AXOutlineRow": "row",
    "AXCloseButton": "close button",
    "AXMinimizeButton": "minimise button",
    "AXFullScreenButton": "full screen button",
    "AXIncrementArrow": "increment arrow button",
    "AXDecrementArrow": "decrement arrow button",
    "AXIncrementPage": "increment page button",
    "AXDecrementPage": "decrement page button",
}

_ROLE_DISPLAY_OVERRIDES = {
    "AXApplication": "application",
    "AXBusyIndicator": "busy indicator",
    "AXButton": "button",
    "AXCell": "cell",
    "AXCheckBox": "checkbox",
    "AXCollection": "collection",
    "AXDialog": "dialog",
    "AXDisclosureTriangle": "disclosure triangle",
    "AXGroup": "container",
    "AXHeading": "heading",
    "AXImage": "image",
    "AXIncrementor": "incrementor",
    "AXLayoutArea": "layout area",
    "AXLink": "link",
    "AXList": "list",
    "AXMenu": "menu",
    "AXMenuBar": "menu bar",
    "AXMenuBarItem": "menu bar item",
    "AXMenuButton": "menu button",
    "AXMenuItem": "menu item",
    "AXOutline": "outline",
    "AXPopUpButton": "popup button",
    "AXProgressIndicator": "progress indicator",
    "AXRadioButton": "radio button",
    "AXRow": "row",
    "AXScrollArea": "scroll area",
    "AXScrollBar": "scroll bar",
    "AXSlider": "slider",
    "AXSplitGroup": "split group",
    "AXSplitter": "splitter",
    "AXStaticText": "text",
    "AXTab": "tab",
    "AXTable": "table",
    "AXTextArea": "text area",
    "AXTextField": "text field",
    "AXToolbar": "toolbar",
    "AXUnknown": "unknown",
    "AXValueIndicator": "value indicator",
    "AXWebArea": "web area",
    "AXWindow": "standard window",
}

_CUSTOM_ACTION_NAME_MAP = {
    "Move previous": "AXMovePrevious",
    "Move next": "AXMoveNext",
    "Remove from toolbar": "AXRemoveFromToolbar",
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


def get_menu_bar(ax_app: Any) -> Any | None:
    err, menu_bar = AXUIElementCopyAttributeValue(ax_app, "AXMenuBar", None)
    if err == kAXErrorSuccess and menu_bar is not None:
        return menu_bar
    return None


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


def _clean_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, float):
        if value.is_integer():
            text = str(int(value))
        else:
            text = f"{value}".rstrip("0").rstrip(".")
    else:
        text = str(value)
    text = text.strip()
    return text or None


def _value_type_name(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, float):
        return "float"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, str):
        return "string"
    return None


def _display_role(attrs: dict[str, Any], role: str) -> str:
    subrole = _clean_text(attrs.get(kAXSubroleAttribute))
    if subrole in _SUBROLE_DISPLAY_OVERRIDES:
        return _SUBROLE_DISPLAY_OVERRIDES[subrole]
    mapped = _ROLE_DISPLAY_OVERRIDES.get(role)
    if mapped:
        return mapped
    role_desc = _clean_text(attrs.get(kAXRoleDescriptionAttribute))
    if role_desc and role not in {"AXWindow", "AXRow", "AXUnknown"}:
        return role_desc
    return role.removeprefix("AX").lower()


def _normalize_action_name(action: Any) -> str | None:
    raw = str(action).strip()
    if not raw:
        return None
    if raw.startswith("AX"):
        return raw
    if "\n" in raw:
        first_line = raw.splitlines()[0].strip()
        if first_line.startswith("Name:"):
            raw = first_line.removeprefix("Name:").strip()
    mapped = _CUSTOM_ACTION_NAME_MAP.get(raw)
    if mapped is not None:
        return mapped
    if raw.startswith("Name:"):
        mapped = _CUSTOM_ACTION_NAME_MAP.get(raw.removeprefix("Name:").strip())
        if mapped is not None:
            return mapped
    return None


def _get_actions(element: Any, role: str) -> list[str]:
    if role not in _ACTIONABLE_ROLES:
        return []
    err, actions = AXUIElementCopyActionNames(element, None)
    if err != kAXErrorSuccess or actions is None:
        return []
    normalized_actions: list[str] = []
    for action in actions:
        normalized = _normalize_action_name(action)
        if normalized is None:
            continue
        normalized_actions.append(normalized)

    has_primary_activation = any(
        action in {"AXPress", "AXConfirm", "AXPick"}
        for action in normalized_actions
    )
    raw_actions: list[str] = []
    for action in normalized_actions:
        if action in {"AXPress", "AXCancel", "AXConfirm", "AXPick", "AXShowDefaultUI", "AXShowAlternateUI"}:
            continue
        if action == "AXShowMenu" and has_primary_activation:
            continue
        raw_actions.append(action)
    if role in {"AXScrollArea", "AXCollection", "AXList", "AXOutline", "AXTable"}:
        return [
            action
            for action in raw_actions
            if action in {"AXScrollUpByPage", "AXScrollDownByPage"}
        ]
    return raw_actions


_CHILDREN_FALLBACK_ROLES = frozenset({
    "AXCollection",
    "AXGroup",
    "AXLayoutArea",
    "AXList",
    "AXOpaqueProviderGroup",
    "AXOutline",
    "AXScrollArea",
    "AXSplitGroup",
    "AXTable",
    "AXToolbar",
    "AXWindow",
})


def _children_for_walk(element: Any, attrs: dict[str, Any], role: str) -> list[Any] | None:
    children = attrs.get(kAXChildrenAttribute)
    if children:
        return children
    if role not in _CHILDREN_FALLBACK_ROLES:
        return children
    try:
        err, direct_children = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, None)
    except Exception:
        return children
    if err != kAXErrorSuccess or direct_children is None:
        return children
    return direct_children


def get_action_names_for_ref(element: Any) -> list[str]:
    """Return raw AX action names for an element reference."""
    try:
        err, actions = AXUIElementCopyActionNames(element, None)
    except Exception:
        return []
    if err != kAXErrorSuccess or actions is None:
        return []
    return [str(action) for action in actions]


def get_parent_ref(element: Any) -> Any | None:
    """Return the AX parent element if available."""
    try:
        err, parent = AXUIElementCopyAttributeValue(element, kAXParentAttribute, None)
    except Exception:
        return None
    if err == kAXErrorSuccess and parent is not None:
        return parent
    return None


def has_scrollbar_ref(element: Any) -> bool:
    """Whether an element exposes a vertical or horizontal scrollbar."""
    for attr in ("AXVerticalScrollBar", "AXHorizontalScrollBar"):
        try:
            err, scrollbar = AXUIElementCopyAttributeValue(element, attr, None)
        except Exception:
            continue
        if err == kAXErrorSuccess and scrollbar is not None:
            return True
    return False


def _resolve_label(attrs: dict[str, Any], role: str) -> str | None:
    title = _clean_text(attrs.get(kAXTitleAttribute))
    if title:
        return title
    description = _clean_text(attrs.get(kAXDescriptionAttribute))
    value = _clean_text(attrs.get(kAXValueAttribute))
    subrole = _clean_text(attrs.get(kAXSubroleAttribute))
    if description is not None and role == "AXList" and subrole in {"AXCollectionList", "AXSectionList"}:
        return description
    if role == "AXHeading" and value is not None and value == description:
        return value
    if value is not None and (description is None or role in ("AXStaticText", "AXMenuItem", "AXLink")):
        return value
    return None


def _build_states(element: Any, attrs: dict[str, Any]) -> list[str]:
    states: list[str] = []
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
        value_type = _value_type_name(attrs.get(kAXValueAttribute))
        if value_type is not None:
            states.append(value_type)
    role = attrs.get(kAXRoleAttribute, "")
    if role == "AXRow":
        err2, selectable = AXUIElementIsAttributeSettable(element, kAXSelectedAttribute, None)
        if err2 == kAXErrorSuccess and selectable:
            if "selected" not in states:
                states.append("selectable")
    state_order = {
        "disabled": 0,
        "selected": 1,
        "selectable": 2,
        "expanded": 3,
        "focused": 4,
        "settable": 5,
        "string": 6,
        "float": 7,
        "integer": 8,
        "boolean": 9,
    }
    states.sort(key=lambda state: (state_order.get(state, 100), state))
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
    # Track AX read assertion for coordinated access
    if target_pid is not None:
        AssertionTracker.acquire(target_pid, AXEnablementKind.READ_ATTRIBUTES)

    nodes: list[Node] = []
    stack: list[tuple[Any, int]] = [(ax_element, 0)]

    while stack and len(nodes) < max_nodes:
        element, depth = stack.pop()
        if depth > max_depth:
            continue

        attrs = _read_attrs(element)
        role = str(attrs.get(kAXRoleAttribute, "AXUnknown"))
        display_role = _display_role(attrs, role)

        label = _resolve_label(attrs, role)
        states = _build_states(element, attrs) if include_states else []
        description = _clean_text(attrs.get(kAXDescriptionAttribute))
        value = _clean_text(attrs.get(kAXValueAttribute))
        placeholder = _clean_text(attrs.get("AXPlaceholderValue"))
        help_text = _clean_text(attrs.get("AXHelp"))
        value_description = _clean_text(attrs.get("AXValueDescription"))
        ax_id = _clean_text(attrs.get(kAXIdentifierAttribute))
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
            placeholder=placeholder,
            help_text=help_text,
            value_description=value_description,
            ax_id=ax_id,
            secondary_actions=secondary_actions,
            depth=depth,
            ax_ref=element,
            ax_role=role,
            subrole=_clean_text(attrs.get(kAXSubroleAttribute)),
            is_web_area=is_web_area,
            is_oop=is_oop,
            element_pid=element_pid,
            url=link_url,
        ))

        children = _children_for_walk(element, attrs, role)
        if children:
            # Depth-first preorder traversal. Reverse push keeps AX child order
            # stable in the final flat list, which the pruning/indexing passes
            # rely on when reconstructing parent/child relationships.
            capped_children = list(children[:_MAX_CHILDREN_PER_ELEMENT])
            for child in reversed(capped_children):
                stack.append((child, depth + 1))

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


def node_from_ref(element: Any, *, depth: int = 0, index: int = -1) -> Node:
    """Build a lightweight Node wrapper around a live AX element reference."""
    attrs = _read_attrs(element)
    role = str(attrs.get(kAXRoleAttribute, "AXUnknown"))
    display_role = _display_role(attrs, role)
    return Node(
        index=index,
        role=display_role,
        label=_resolve_label(attrs, role),
        states=_build_states(element, attrs),
        description=_clean_text(attrs.get(kAXDescriptionAttribute)),
        value=_clean_text(attrs.get(kAXValueAttribute)),
        placeholder=_clean_text(attrs.get("AXPlaceholderValue")),
        help_text=_clean_text(attrs.get("AXHelp")),
        value_description=_clean_text(attrs.get("AXValueDescription")),
        ax_id=_clean_text(attrs.get(kAXIdentifierAttribute)),
        secondary_actions=_get_actions(element, role),
        depth=depth,
        ax_ref=element,
        ax_role=role,
        subrole=_clean_text(attrs.get(kAXSubroleAttribute)),
        is_web_area=(role == "AXWebArea"),
        element_pid=_get_element_pid(element),
    )


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


def get_element_frame(node: Node) -> tuple[float, float, float, float] | None:
    """Get the screen-coordinate frame of an element via AXPosition + AXSize."""
    if node.ax_ref is None:
        return None

    err_p, pos_val = AXUIElementCopyAttributeValue(node.ax_ref, kAXPositionAttribute, None)
    err_s, size_val = AXUIElementCopyAttributeValue(node.ax_ref, kAXSizeAttribute, None)
    if err_p != kAXErrorSuccess or err_s != kAXErrorSuccess:
        return None
    if pos_val is None or size_val is None:
        return None

    point = _extract_point(pos_val)
    size = _extract_size(size_val)
    if point is None or size is None:
        return None

    return (point[0], point[1], size[0], size[1])


def get_element_position(node: Node) -> tuple[float | None, float | None]:
    """Get the screen-coordinate center of an element via AXPosition + AXSize."""
    frame = get_element_frame(node)
    if frame is None:
        return (None, None)

    px, py, sw, sh = frame
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
