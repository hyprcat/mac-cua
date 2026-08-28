#!/usr/bin/env python3
"""AX tree → spatial 2D matrix, exactly as a human sees the screen.

Standalone script: pass a bundle id, get back a 2D occupancy matrix in
absolute screen coordinates plus an ASCII wireframe of the focused window.

    python scripts/spatial_matrix.py com.apple.Music
    python scripts/spatial_matrix.py com.apple.Music --cols 200 --json out.json

Algorithm
---------
1. Walk the AX tree of the focused window in *pre-order DFS*. Pre-order is
   AppKit's paint order: a parent draws first, its children draw on top,
   later siblings draw above earlier ones. Each element's frame comes from
   AXPosition + AXSize (absolute screen points, top-left origin).
2. Clip: an element's effective rect is its frame intersected with every
   clipping ancestor (window / scroll area / web area) and the window
   viewport. Off-viewport rows in a scrolled table die here.
3. Prune with the repo's cleaning pipeline (same clean output the MCP
   server sends to the model). --no-prune keeps the raw tree.
4. Rasterize painter-style: the viewport becomes a cells grid; each node in
   paint order stamps its index into the cells its effective rect covers.
   Pure layout containers (AXGroup etc.) stamp nothing — they don't draw.
5. A node is human-visible iff it owns >= 1 cell after everyone painted.
   Fully occluded / clipped / zero-size elements own nothing and are not
   rendered — matching what an eye actually sees.

The final grid IS the matrix: cell (row, col) covers the absolute rect
(vx + col*cw, vy + row*ch, cw, ch) and holds the topmost element index
(-1 = bare window-less screen).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

try:
    import ApplicationServices  # noqa: F401
except ModuleNotFoundError:
    sys.exit(
        "pyobjc is not installed in this interpreter.\n"
        "Run via the project environment instead:\n"
        "    uv run python scripts/spatial_matrix.py <bundle-id>"
    )

from ApplicationServices import (  # noqa: E402
    AXUIElementCopyAttributeValue,
    kAXErrorSuccess,
    kAXFocusedWindowAttribute,
    kAXMainWindowAttribute,
    kAXWindowsAttribute,
    kAXRoleAttribute,
    kAXRoleDescriptionAttribute,
    kAXDescriptionAttribute,
    kAXValueAttribute,
    kAXIdentifierAttribute,
    kAXChildrenAttribute,
    kAXPositionAttribute,
    kAXSizeAttribute,
)

from app.response import Node, Rect  # noqa: E402
from app._lib import apps  # noqa: E402
from app._lib.accessibility import (  # noqa: E402
    _build_states,
    _extract_point,
    _extract_size,
    _read_attrs,
    _resolve_label,
)
from app._lib.pruning import prune  # noqa: E402

EMPTY = -1
_MAX_NODES = 5000
_MAX_CHILDREN = 100

# Ancestors that visually clip their descendants.
_CLIPPING_ROLES = frozenset({"AXWindow", "AXScrollArea", "AXWebArea", "AXSheet", "AXDrawer"})

# Pure layout chrome — occupies space in the tree but paints no pixels of
# its own, so it must not occlude siblings underneath it.
_NON_PAINTING_ROLES = frozenset({
    "AXGroup", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXUnknown",
})


@dataclass
class SpatialMatrix:
    grid: list[list[int]]           # grid[row][col] = topmost node index or EMPTY
    viewport: Rect                  # absolute screen rect the grid spans
    cell_w: float                   # cell width in screen points
    cell_h: float                   # cell height in screen points
    visible: set[int]               # node indices owning >= 1 cell
    eff_rects: dict[int, Rect]      # node index -> clipped absolute rect


def _intersect(a: Rect, b: Rect) -> Rect | None:
    x = max(a.x, b.x)
    y = max(a.y, b.y)
    r = min(a.x + a.w, b.x + b.w)
    btm = min(a.y + a.h, b.y + b.h)
    if r - x <= 0 or btm - y <= 0:
        return None
    return Rect(x=x, y=y, w=r - x, h=btm - y)


def _element_frame(element: Any) -> Rect | None:
    err_p, pos = AXUIElementCopyAttributeValue(element, kAXPositionAttribute, None)
    err_s, size = AXUIElementCopyAttributeValue(element, kAXSizeAttribute, None)
    if err_p != kAXErrorSuccess or err_s != kAXErrorSuccess or pos is None or size is None:
        return None
    point = _extract_point(pos)
    dims = _extract_size(size)
    if point is None or dims is None:
        return None
    return Rect(x=point[0], y=point[1], w=dims[0], h=dims[1])


def walk_window(ax_window: Any) -> tuple[list[Node], dict[int, Rect]]:
    """Pre-order DFS over the window's AX tree.

    Returns (nodes, frames). Node.depth reflects tree depth so the flat
    list is depth-ordered — the exact shape prune() expects, and the exact
    paint order the rasterizer needs.
    """
    nodes: list[Node] = []
    frames: dict[int, Rect] = {}
    # Explicit stack of (element, depth); children pushed reversed keeps
    # sibling order left-to-right in the flat list.
    stack: list[tuple[Any, int]] = [(ax_window, 0)]

    while stack and len(nodes) < _MAX_NODES:
        element, depth = stack.pop()
        attrs = _read_attrs(element)
        role = str(attrs.get(kAXRoleAttribute, "AXUnknown"))
        role_desc = attrs.get(kAXRoleDescriptionAttribute)
        display_role = str(role_desc) if role_desc else role.removeprefix("AX").lower()
        description_raw = attrs.get(kAXDescriptionAttribute)
        description = str(description_raw).strip() if description_raw and str(description_raw).strip() else None
        value_raw = attrs.get(kAXValueAttribute)
        ax_id_raw = attrs.get(kAXIdentifierAttribute)

        index = len(nodes)
        nodes.append(Node(
            index=index,
            role=display_role,
            label=_resolve_label(attrs, role),
            states=_build_states(element, attrs),
            description=description,
            value=str(value_raw) if value_raw is not None else None,
            ax_id=str(ax_id_raw) if ax_id_raw else None,
            secondary_actions=[],
            depth=depth,
            ax_ref=element,
            ax_role=role,
        ))
        frame = _element_frame(element)
        if frame is not None:
            frames[index] = frame

        children = attrs.get(kAXChildrenAttribute)
        if children:
            for child in reversed(list(children)[:_MAX_CHILDREN]):
                stack.append((child, depth + 1))

    return nodes, frames


def compute_effective_rects(
    nodes: list[Node],
    frames: dict[int, Rect],
    viewport: Rect,
) -> dict[int, Rect]:
    """Clip each frame by its clipping ancestors and the viewport.

    Walks the depth-ordered list with a stack of (depth, clip_rect) so each
    node inherits the intersection of every clipping ancestor above it.
    """
    eff: dict[int, Rect] = {}
    clip_stack: list[tuple[int, Rect]] = [(-1, viewport)]

    for node in nodes:
        while len(clip_stack) > 1 and clip_stack[-1][0] >= node.depth:
            clip_stack.pop()
        clip = clip_stack[-1][1]

        frame = frames.get(node.index)
        rect = _intersect(frame, clip) if frame is not None else None
        if rect is not None:
            eff[node.index] = rect

        if node.ax_role in _CLIPPING_ROLES:
            # Children see this element's clipped rect; if it clipped to
            # nothing, its subtree is invisible — clip to a zero-ish rect.
            clip_stack.append((node.depth, rect if rect is not None else Rect(x=0, y=0, w=0, h=0)))

    return eff


def rasterize(
    nodes: list[Node],
    eff: dict[int, Rect],
    viewport: Rect,
    cols: int,
) -> SpatialMatrix:
    """Painter's algorithm over a cell grid.

    Terminal characters are ~2x taller than wide, so cell_h = 2 * cell_w
    keeps the rendered wireframe in the window's true proportions.
    """
    cell_w = viewport.w / cols
    cell_h = cell_w * 2.0
    rows = max(1, math.ceil(viewport.h / cell_h))
    grid = [[EMPTY] * cols for _ in range(rows)]

    for node in nodes:  # list order == paint order (pre-order DFS)
        rect = eff.get(node.index)
        if rect is None or node.ax_role in _NON_PAINTING_ROLES:
            continue
        c0 = max(0, int((rect.x - viewport.x) / cell_w))
        c1 = min(cols, math.ceil((rect.x + rect.w - viewport.x) / cell_w))
        r0 = max(0, int((rect.y - viewport.y) / cell_h))
        r1 = min(rows, math.ceil((rect.y + rect.h - viewport.y) / cell_h))
        for r in range(r0, r1):
            row = grid[r]
            for c in range(c0, c1):
                row[c] = node.index

    visible = {idx for row in grid for idx in row if idx != EMPTY}
    return SpatialMatrix(grid=grid, viewport=viewport, cell_w=cell_w, cell_h=cell_h,
                         visible=visible, eff_rects=eff)


def render_ascii(sm: SpatialMatrix, nodes: list[Node]) -> str:
    """Wireframe view: box borders + labels at their true screen positions.

    A character is drawn only into cells the element actually owns in the
    grid, so occluded fragments stay hidden — the render shows exactly what
    the matrix (and a human) sees.
    """
    rows, cols = len(sm.grid), len(sm.grid[0])
    canvas = [["·"] * cols for _ in range(rows)]
    by_index = {n.index: n for n in nodes}

    def cell_span(rect: Rect) -> tuple[int, int, int, int]:
        c0 = max(0, int((rect.x - sm.viewport.x) / sm.cell_w))
        c1 = min(cols, math.ceil((rect.x + rect.w - sm.viewport.x) / sm.cell_w))
        r0 = max(0, int((rect.y - sm.viewport.y) / sm.cell_h))
        r1 = min(rows, math.ceil((rect.y + rect.h - sm.viewport.y) / sm.cell_h))
        return r0, r1, c0, c1

    # Pass 1: fill + borders, ownership-gated.
    for row in range(rows):
        for col in range(cols):
            idx = sm.grid[row][col]
            if idx == EMPTY:
                continue
            rect = sm.eff_rects[idx]
            r0, r1, c0, c1 = cell_span(rect)
            on_border = row in (r0, r1 - 1) or col in (c0, c1 - 1)
            if not on_border:
                canvas[row][col] = " "
            elif (row in (r0, r1 - 1)) and (col in (c0, c1 - 1)):
                canvas[row][col] = "+"
            elif row in (r0, r1 - 1):
                canvas[row][col] = "-"
            else:
                canvas[row][col] = "|"

    # Pass 2: labels, written only into cells the element owns.
    for idx in sorted(sm.visible):
        node = by_index.get(idx)
        if node is None:
            continue
        text = node.label or node.value or ""
        text = f"[{idx}]{text}" if text else f"[{idx}]"
        text = text.replace("\n", " ")[:60]
        rect = sm.eff_rects[idx]
        r0, r1, c0, c1 = cell_span(rect)
        row = min(rows - 1, (r0 + r1 - 1) // 2)  # vertical center of the rect
        placed = False
        for r in (row, r0):  # center row first, top row as fallback
            run = [c for c in range(c0, min(c1, cols)) if sm.grid[r][c] == idx]
            if not run:
                continue
            for i, ch in enumerate(text):
                c = run[0] + i
                if c >= cols or sm.grid[r][c] != idx:
                    break
                canvas[r][c] = ch
            placed = True
            break
        if not placed:
            continue

    return "\n".join("".join(r) for r in canvas)


def build(bundle_id: str, *, cols: int, do_prune: bool) -> tuple[SpatialMatrix, list[Node], str | None]:
    ax_app, pid = apps.get_ax_app_for_bundle(bundle_id)

    window = None
    for attr in (kAXFocusedWindowAttribute, kAXMainWindowAttribute):
        err, window = AXUIElementCopyAttributeValue(ax_app, attr, None)
        if err == kAXErrorSuccess and window is not None:
            break
        window = None
    if window is None:
        err, windows = AXUIElementCopyAttributeValue(ax_app, kAXWindowsAttribute, None)
        if err == kAXErrorSuccess and windows:
            window = windows[0]
    if window is None:
        raise SystemExit(f"{bundle_id} (pid {pid}) has no windows to render")

    nodes, frames = walk_window(window)
    viewport = frames.get(0)
    if viewport is None:
        raise SystemExit("Could not read the window frame (Accessibility permission?)")

    # Clip against the FULL tree first: an ancestor pruned from the clean
    # output still clips its descendants on screen.
    eff = compute_effective_rects(nodes, frames, viewport)

    if do_prune:
        # prune() mutates node.index (filter + reindex), so remap the
        # rect dict through object identity.
        pre_prune_index = {id(n): n.index for n in nodes}
        nodes, _collapse_info, _depth_collapsed = prune(nodes)
        eff = {
            n.index: eff[pre_prune_index[id(n)]]
            for n in nodes
            if pre_prune_index[id(n)] in eff
        }

    err, title = AXUIElementCopyAttributeValue(window, "AXTitle", None)
    window_title = str(title) if err == kAXErrorSuccess and title else None
    return rasterize(nodes, eff, viewport, cols), nodes, window_title


def main() -> None:
    parser = argparse.ArgumentParser(description="Render an app's AX tree as a spatial 2D matrix.")
    parser.add_argument("bundle_id", help="e.g. com.apple.Music")
    parser.add_argument("--cols", type=int, default=160, help="grid width in cells (default 160)")
    parser.add_argument("--no-prune", action="store_true", help="skip the cleaning pipeline, use the raw tree")
    parser.add_argument("--json", metavar="PATH", help="also dump the matrix + element metadata as JSON")
    args = parser.parse_args()

    sm, nodes, window_title = build(args.bundle_id, cols=args.cols, do_prune=not args.no_prune)
    by_index = {n.index: n for n in nodes}

    v = sm.viewport
    print(f"App: {args.bundle_id}  Window: {window_title or '(untitled)'}")
    print(f"Viewport (absolute screen points): x={v.x:.0f} y={v.y:.0f} w={v.w:.0f} h={v.h:.0f}")
    print(f"Grid: {len(sm.grid)} rows x {len(sm.grid[0])} cols, cell = {sm.cell_w:.1f} x {sm.cell_h:.1f} pt")
    print(f"Visible elements: {len(sm.visible)} of {len(nodes)} in the clean tree\n")
    print(render_ascii(sm, nodes))
    print("\nLegend (visible elements only):")
    for idx in sorted(sm.visible):
        node = by_index.get(idx)
        if node is None:
            continue
        r = sm.eff_rects[idx]
        label = f" {node.label}" if node.label else ""
        print(f"  [{idx}] {node.role}{label}  @ ({r.x:.0f}, {r.y:.0f}, {r.w:.0f}x{r.h:.0f})")

    if args.json:
        payload = {
            "bundle_id": args.bundle_id,
            "window_title": window_title,
            "viewport": {"x": v.x, "y": v.y, "w": v.w, "h": v.h},
            "cell_w": sm.cell_w,
            "cell_h": sm.cell_h,
            "grid": sm.grid,
            "elements": {
                str(idx): {
                    "role": by_index[idx].role,
                    "label": by_index[idx].label,
                    "value": by_index[idx].value,
                    "rect": {
                        "x": sm.eff_rects[idx].x,
                        "y": sm.eff_rects[idx].y,
                        "w": sm.eff_rects[idx].w,
                        "h": sm.eff_rects[idx].h,
                    },
                }
                for idx in sorted(sm.visible)
                if idx in by_index
            },
        }
        Path(args.json).write_text(json.dumps(payload, indent=2))
        print(f"\nJSON written to {args.json}")


if __name__ == "__main__":
    main()
