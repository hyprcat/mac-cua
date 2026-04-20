"""AX tree → indexed text serialization (pure, no macOS deps)."""

from __future__ import annotations

import re

from app.response import AppState, Node
from app._lib.pruning import prune

# Matches raw AXUIElement pointer strings like (<AXUIElement 0x600003abc123 {pid=29221}>)
# These leak through from pyobjc str() on AX element references and are useless to the LLM.
_AX_ELEMENT_RE = re.compile(r'\s*\(?<AXUIElement\s+0x[0-9a-fA-F]+\s*\{pid=\d+\}>\)?')

_VALUE_ROLES = frozenset({
    "slider",
    "text field",
    "text area",
    "combo box",
    "incrementor",
    "level indicator",
})

# Roles that may contain rich/attributed text content
_RICH_TEXT_ROLES = frozenset({
    "text area",
    "text field",
})

_ACTION_DISPLAY_NAMES = {
    "AXRaise": "Raise",
    "AXCollapse": "Collapse",
    "AXMoveNext": "Move next",
    "AXMovePrevious": "Move previous",
    "AXRemoveFromToolbar": "Remove from toolbar",
    "AXScrollUpByPage": "Scroll Up",
    "AXScrollDownByPage": "Scroll Down",
    "AXScrollLeftByPage": "Scroll Left",
    "AXScrollRightByPage": "Scroll Right",
    "AXScrollToVisible": "Scroll To Visible",
    "AXScrollToShowDescendant": "Scroll To Show Descendant",
    "AXOpen": "Open",
    "AXPick": "Pick",
    "AXIncrement": "Increment",
    "AXDecrement": "Decrement",
    "AXZoomWindow": "zoom the window",
}

_VALUELESS_ROLES = frozenset({
    "collection",
    "group",
    "outline",
    "radiogroup",
    "scroll area",
    "section",
    "split group",
    "toolbar",
    "window",
    "standard window",
})


def _display_role(node: Node, *, codex_style: bool) -> str:
    if codex_style and node.role == "web area":
        return "HTML content"
    if codex_style and node.role == "checkbox" and node.subrole == "AXToggleButton":
        return "toggle button"
    if codex_style and node.role == "radio button" and node.subrole == "AXTabButton":
        return "tab"
    if codex_style and node.role == "popup button":
        return "pop-up button"
    if codex_style and node.ax_id and node.role in {"group", "radiogroup", "unknown"} and node.ax_id.startswith("UIA."):
        return node.ax_id
    return node.role


def _display_actions(actions: list[str]) -> list[str]:
    return [_ACTION_DISPLAY_NAMES.get(action, action.removeprefix("AX")) for action in actions]


def _should_inline_value(node: Node) -> bool:
    if node.value is None:
        return False
    if node.label is not None and node.value == node.label:
        return False
    if node.role in _VALUELESS_ROLES:
        return False
    return True


def _format_node(node: Node, *, indent: bool = True, codex_style: bool = False) -> str:
    """Format a single node into its text representation."""
    parts: list[str] = []
    display_label = node.label
    description = node.description
    value = node.value

    if codex_style and node.role == "row" and display_label is None and description is not None and value is None:
        display_label = description
        description = None

    if indent:
        parts.append(("\t" if codex_style else "  ") * node.depth)

    if codex_style and node.role == "menu bar item" and node.label:
        parts.append(str(node.index))
        parts.append(" ")
        parts.append(node.label)
        return "".join(parts)

    if codex_style:
        parts.append(str(node.index))
        parts.append(" ")
        parts.append(_display_role(node, codex_style=True))
    else:
        parts.append(f"[{node.index}] ")
        parts.append(node.lm_role if node.lm_role else node.role)

    if node.states:
        parts.append(f" ({', '.join(node.states)})")

    if display_label is not None:
        parts.append(f" {display_label}")

    extras: list[str] = []
    if description is not None and description != display_label:
        extras.append(f"Description: {description}")

    if value is not None and _should_inline_value(node):
        if node.label is None and display_label is not None and value == display_label:
            pass
        else:
            extras.append(f"Value: {value}")

    if node.placeholder:
        extras.append(f"Placeholder: {node.placeholder}")

    if node.help_text:
        extras.append(f"Help: {node.help_text}")

    if node.value_description:
        extras.append(f"Details: {node.value_description}")

    if node.ax_id is not None:
        display_role = _display_role(node, codex_style=codex_style)
        if not (
            codex_style
            and (
                node.role == "menu bar"
                or (node.ax_id.startswith("UIA.") and display_role == node.ax_id)
            )
        ):
            extras.append(f"ID: {node.ax_id}")

    if not codex_style and node.position is not None and node.size is not None:
        extras.append(
            " Frame: "
            f"({int(round(node.position.x))},{int(round(node.position.y))} "
            f"{max(1, int(round(node.size.w)))}x{max(1, int(round(node.size.h)))})"
        )

    if node.secondary_actions:
        actions = _display_actions(node.secondary_actions)
        if codex_style:
            extras.append(f"Secondary Actions: {', '.join(actions)}")
        else:
            extras.append(f"Actions: [{', '.join(actions)}]")

    # Web area URL
    if node.web_area_url:
        extras.append(f"URL: {node.web_area_url}")

    if extras:
        parts.append(", " if display_label is not None else " ")
        parts.append(extras[0].lstrip())
        for extra in extras[1:]:
            parts.append(f", {extra}")

    result = "".join(parts)
    # Strip leaked AXUIElement pointer strings — useless to the LLM
    result = _AX_ELEMENT_RE.sub("", result)
    return result


def _format_focus_summary(node: Node, *, codex_style: bool = False) -> str:
    if not codex_style:
        return _format_node(node, indent=False, codex_style=False)

    if node.role == "menu bar item" and node.label:
        return f"{node.index} {node.label}"

    parts = [str(node.index), " ", _display_role(node, codex_style=True)]
    if node.states:
        parts.append(f" ({', '.join(node.states)})")
    if node.label is not None and node.role not in {"standard window", "window"}:
        parts.append(f" {node.label}")
    return "".join(parts)


def _has_visible_children(nodes: list[Node], position: int) -> bool:
    """Return True when the node at `position` has serialized descendants."""
    node = nodes[position]
    for candidate in nodes[position + 1:]:
        if candidate.depth <= node.depth:
            break
        return True
    return False


def _should_inline_web_content(
    node: Node,
    nodes: list[Node],
    position: int,
    *,
    codex_style: bool,
) -> bool:
    """Decide whether extracted web/rich text should be rendered inline.

    Codex-style trees preserve the structural hierarchy first. If a web area or
    rich text control already has visible descendants, dumping extracted content
    inline causes the whole tree to collapse into a giant blob, especially for
    Electron apps like VS Code.
    """
    if not node.web_content:
        return False
    if not codex_style:
        return True
    if node.role in {"HTML content", "web area", "text area", "text field"}:
        return not _has_visible_children(nodes, position)
    return True


def serialize(
    nodes: list[Node],
    focused_index: int | None = None,
    *,
    enable_pruning: bool = True,
    max_depth: int | None = None,
    collapse_threshold: int | None = None,
    codex_style: bool = False,
) -> str:
    """Serialize a list of Node objects into indented indexed text.

    Parameters
    ----------
    nodes:
        Flat list of nodes with depth information for indentation.
    focused_index:
        Index of the currently focused UI element, or None.
    enable_pruning:
        Run the full pruning pipeline (DisplayElement, subtree pruning,
        depth collapse, SubtreeCollapse). Disable for raw output.
    max_depth:
        Override the default max depth for pruning.
    collapse_threshold:
        Override the default SubtreeCollapse threshold.

    Returns
    -------
    The full text block ready to send to the model.
    """
    if enable_pruning and nodes:
        prune_kwargs: dict[str, int] = {}
        if max_depth is not None:
            prune_kwargs["max_depth"] = max_depth
        if collapse_threshold is not None:
            prune_kwargs["collapse_threshold"] = collapse_threshold
        nodes, collapse_info, depth_collapsed_parents = prune(nodes, **prune_kwargs)
    else:
        collapse_info = {}
        depth_collapsed_parents = set()

    lines: list[str] = []
    for position, node in enumerate(nodes):
        lines.append(_format_node(node, codex_style=codex_style))
        # Web/rich text content inline
        if _should_inline_web_content(node, nodes, position, codex_style=codex_style):
            content_indent = ("\t" if codex_style else "  ") * (node.depth + 1)
            for content_line in node.web_content.split("\n"):
                lines.append(f"{content_indent}{content_line}")
        # SubtreeCollapse: if this node has collapsed children, add summary
        if node.index in collapse_info:
            total = collapse_info[node.index]
            # The first 5 children are already in the list; total is original count
            hidden = max(0, total - 5)
            if hidden > 0:
                indent = ("\t" if codex_style else "  ") * (node.depth + 1)
                lines.append(f"{indent}... ({hidden} more items hidden)")
        # Depth collapse: children exceeded max depth threshold
        if node.index in depth_collapsed_parents:
            indent = ("\t" if codex_style else "  ") * (node.depth + 1)
            lines.append(f"{indent}<summary>(collapsed content is hidden)</summary>")

    if focused_index is not None and 0 <= focused_index < len(nodes):
        focused = nodes[focused_index]
        summary = _format_focus_summary(focused, codex_style=codex_style)
        lines.append("")
        lines.append(f"The focused UI element is {summary}.")

    return "\n".join(lines)


def make_header(
    app: str,
    pid: int,
    window_title: str | None,
    window_id: int | None = None,
    window_pid: int | None = None,
    screenshot_size: tuple[int, int] | None = None,
    app_state: AppState | None = None,
    codex_style: bool = False,
) -> str:
    """Produce the header block identifying the app and window.

    Parameters
    ----------
    app:
        Bundle identifier, e.g. ``com.apple.Music``.
    pid:
        Process ID.
    window_title:
        Title of the frontmost window, or None to omit the Window line.
    app_state:
        Geometry metadata (visibleRect, scalingFactor, etc.) if available.
    """
    display_name = app.rsplit(".", 1)[-1]
    lines = [f"App={app} (pid {pid})"]

    if window_title is not None:
        lines.append(f'Window: "{window_title}", App: {display_name}.')
    if codex_style:
        return "\n".join(lines)
    if window_id is not None:
        if window_pid is not None:
            lines.append(f"Target window_id={window_id}, window_pid={window_pid}.")
        else:
            lines.append(f"Target window_id={window_id}.")
    if screenshot_size is not None:
        width, height = screenshot_size
        lines.append(
            "Screenshot: "
            f"{width}x{height}. Coordinates use the screenshot's pixel space with origin at the top-left of the image."
        )
        lines.append("Any Frame hints in the tree use this same screenshot pixel space.")
    if app_state is not None:
        lines.append(f"isRunning: {str(app_state.is_running).lower()}, isActive: {str(app_state.is_active).lower()}")
        if app_state.visible_rect is not None:
            r = app_state.visible_rect
            lines.append(f"visibleRect: ({r.x}, {r.y}, {r.w}x{r.h})")
        lines.append(f"scalingFactor: {app_state.scaling_factor}")
        if app_state.scaled_screen_size is not None:
            s = app_state.scaled_screen_size
            lines.append(f"scaledScreenSize: ({s.w}x{s.h})")
        if app_state.cursor_position is not None:
            c = app_state.cursor_position
            lines.append(f"cursorPositionInScaledCoordinates: ({c.x}, {c.y})")

    return "\n".join(lines)
