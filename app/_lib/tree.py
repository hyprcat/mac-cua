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


def _format_node(node: Node, *, indent: bool = True) -> str:
    """Format a single node into its text representation."""
    parts: list[str] = []

    if indent:
        parts.append("  " * node.depth)

    parts.append(str(node.index))
    parts.append(" ")
    # Use lm_role if available (token-efficient), fall back to display role
    parts.append(node.lm_role if node.lm_role else node.role)

    if node.states:
        parts.append(f" ({', '.join(node.states)})")

    if node.label is not None:
        parts.append(f" {node.label}")

    if node.description is not None and node.description != node.label:
        parts.append(f" Description: {node.description}")

    role_for_value = node.lm_role if node.lm_role else node.role
    if node.value is not None and role_for_value in _VALUE_ROLES:
        parts.append(f" Value: {node.value}")

    if node.ax_id is not None:
        parts.append(f" ID: {node.ax_id}")

    if node.secondary_actions:
        parts.append(f" Actions: [{', '.join(node.secondary_actions)}]")

    # Web area URL
    if node.web_area_url:
        parts.append(f" URL: {node.web_area_url}")

    result = "".join(parts)
    # Strip leaked AXUIElement pointer strings — useless to the LLM
    result = _AX_ELEMENT_RE.sub("", result)
    return result


def serialize(
    nodes: list[Node],
    focused_index: int | None = None,
    *,
    enable_pruning: bool = True,
    max_depth: int | None = None,
    collapse_threshold: int | None = None,
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
    for node in nodes:
        lines.append(_format_node(node))
        # Web/rich text content inline
        if node.web_content:
            content_indent = "  " * (node.depth + 1)
            for content_line in node.web_content.split("\n"):
                lines.append(f"{content_indent}{content_line}")
        # SubtreeCollapse: if this node has collapsed children, add summary
        if node.index in collapse_info:
            total = collapse_info[node.index]
            # The first 5 children are already in the list; total is original count
            hidden = max(0, total - 5)
            if hidden > 0:
                indent = "  " * (node.depth + 1)
                lines.append(f"{indent}... ({hidden} more items hidden)")
        # Depth collapse: children exceeded max depth threshold
        if node.index in depth_collapsed_parents:
            indent = "  " * (node.depth + 1)
            lines.append(f"{indent}<summary>(collapsed content is hidden)</summary>")

    if focused_index is not None and 0 <= focused_index < len(nodes):
        focused = nodes[focused_index]
        summary = _format_node(focused, indent=False)
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
