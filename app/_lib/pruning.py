"""Tree pruning & DisplayElement — pure Python, no macOS deps.

Pruning passes:
- DisplayElement protocol (lm_role, lm_description, lm_children)
- strip_actions
- merge_labels_with_controls
- collapse_into_interactive_parent
- remove_empty_subtrees
- remove_disabled_blanks
- unwrap_single_child_groups
- collapse_redundant_wrappers
- merge_adjacent_text
- inline_links_as_markdown
- combine_text_siblings
- prune_calendar_event_details
- first_nonempty_index
- maxDepth with collapsed content
- SubtreeCollapse (node count threshold per subtree)
- UIElementURLShortener
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import urlparse, urlunparse

from app.response import Node

# ---------------------------------------------------------------------------
# DisplayElement — role normalization
# ---------------------------------------------------------------------------

_LM_ROLE_MAP: dict[str, str] = {
    "AXStaticText": "text",
    "AXTextField": "text field",
    "AXTextArea": "text area",
    "AXButton": "button",
    "AXRadioButton": "radio",
    "AXCheckBox": "checkbox",
    "AXPopUpButton": "popup",
    "AXMenuButton": "menu button",
    "AXDisclosureTriangle": "disclosure",
    "AXSlider": "slider",
    "AXComboBox": "combo box",
    "AXIncrementor": "incrementor",
    "AXLink": "link",
    "AXMenuItem": "menu item",
    "AXMenu": "menu",
    "AXMenuBar": "menu bar",
    "AXMenuBarItem": "menu bar item",
    "AXTab": "tab",
    "AXTabGroup": "tab group",
    "AXToolbar": "toolbar",
    "AXWindow": "window",
    "AXSheet": "sheet",
    "AXDialog": "dialog",
    "AXScrollArea": "scroll area",
    "AXTable": "table",
    "AXOutline": "outline",
    "AXList": "list",
    "AXRow": "row",
    "AXColumn": "column",
    "AXCell": "cell",
    "AXImage": "image",
    "AXWebArea": "web area",
    "AXHeading": "heading",
    "AXProgressIndicator": "progress",
    "AXBusyIndicator": "busy",
    "AXLevelIndicator": "level indicator",
    "AXValueIndicator": "value indicator",
    "AXColorWell": "color well",
    "AXDateField": "date field",
    "AXHelpTag": "help",
    "AXMatte": "matte",
    "AXRuler": "ruler",
    "AXApplication": "application",
}

# Roles that are pure noise and should be skipped entirely
_SKIP_ROLES: frozenset[str] = frozenset({
    "AXLayoutArea",
    "AXLayoutItem",
    "AXMatte",
    "AXGrowArea",
    "AXUnknown",
    "AXSplitter",
    "AXScrollBar",
})

# Roles that are noise ONLY when they have no label and no actions
_SKIP_WHEN_EMPTY_ROLES: frozenset[str] = frozenset({
    "AXGroup",
    "AXSplitGroup",
})

_INTERACTIVE_ROLES: frozenset[str] = frozenset({
    "AXButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
    "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
    "AXComboBox", "AXIncrementor", "AXLink", "AXRow",
    "AXMenuItem", "AXTab", "AXDisclosureTriangle",
})

# Roles considered selectable/clickable (interactive + cell/menu-bar-item)
_SELECTABLE_ROLES: frozenset[str] = _INTERACTIVE_ROLES | frozenset({
    "AXCell", "AXMenuBarItem",
})

# Container roles eligible for single-item group merging
_CONTAINER_ROLES: frozenset[str] = frozenset({
    "AXGroup", "AXSplitGroup", "AXScrollArea",
})

# Text-only roles for merging adjacent siblings
_TEXT_ONLY_ROLES: frozenset[str] = frozenset({
    "AXStaticText", "AXHeading",
})

_CODEX_SKIP_ROLES: frozenset[str] = frozenset({
    "AXColumn",
    "AXLayoutArea",
    "AXLayoutItem",
    "AXMatte",
    "AXGrowArea",
})

_CODEX_EMPTY_WRAPPER_ROLES: frozenset[str] = frozenset({
    "AXGroup",
    "AXToolbar",
})

# Calendar app bundle IDs for prune_calendar_event_details
_CALENDAR_BUNDLES: frozenset[str] = frozenset({
    "com.apple.iCal",
    "com.flexibits.fantastical2",
    "com.flexibits.fantastical",
})

# Default thresholds
DEFAULT_MAX_DEPTH = 30
DEFAULT_MAX_NODES = 5000
DEFAULT_COLLAPSE_THRESHOLD = 200  # children per subtree before collapsing

# Actions useful to the LLM (strip_actions pass)
_USEFUL_ACTIONS: frozenset[str] = frozenset({
    "AXPress", "AXPick", "AXIncrement", "AXDecrement",
    "AXConfirm", "AXCancel", "AXShowMenu", "AXScrollToVisible",
    "AXScrollUpByPage", "AXScrollDownByPage",
    "AXScrollLeftByPage", "AXScrollRightByPage",
    "AXScrollToShowDescendant",
})


def compute_display_role(ax_role: str | None) -> str:
    """Map AX role to a token-efficient display role string."""
    if ax_role is None:
        return "unknown"
    mapped = _LM_ROLE_MAP.get(ax_role)
    if mapped:
        return mapped
    # Fallback: strip AX prefix and lowercase
    return ax_role.removeprefix("AX").lower() if ax_role.startswith("AX") else ax_role.lower()


def compute_display_description(node: Node) -> str | None:
    """Combine label, description, and value intelligently into a single string.

    Unlike the raw _resolve_label which picks first non-null, this merges
    meaningfully: title takes priority, description adds context if different,
    value is appended for relevant roles.
    """
    parts: list[str] = []

    if node.label:
        parts.append(node.label)

    if node.description and node.description != node.label:
        parts.append(node.description)

    # Value is already shown separately for _VALUE_ROLES in serialize,
    # so lm_description doesn't duplicate it
    if not parts and node.value is not None:
        val = str(node.value).strip()
        if val:
            parts.append(val)

    return " — ".join(parts) if parts else None


def apply_display_protocol(nodes: list[Node]) -> None:
    """Apply DisplayElement protocol to all nodes in-place."""
    for node in nodes:
        node.lm_role = compute_display_role(node.ax_role)
        node.lm_description = compute_display_description(node)


# ---------------------------------------------------------------------------
# Tree structure helpers — build parent/children index from flat list
# ---------------------------------------------------------------------------

def _build_tree_index(nodes: list[Node]) -> tuple[dict[int, list[int]], dict[int, int | None]]:
    """Build children-of and parent-of maps from flat depth-ordered list.

    Returns (children_map, parent_map) keyed by list index (not node.index).
    """
    children: dict[int, list[int]] = {i: [] for i in range(len(nodes))}
    parent: dict[int, int | None] = {0: None} if nodes else {}

    # Stack of (list_index, depth)
    stack: list[tuple[int, int]] = []

    for i, node in enumerate(nodes):
        # Pop stack until we find the parent (depth < current)
        while stack and stack[-1][1] >= node.depth:
            stack.pop()
        if stack:
            parent_idx = stack[-1][0]
            children[parent_idx].append(i)
            parent[i] = parent_idx
        else:
            parent[i] = None
        stack.append((i, node.depth))

    return children, parent


def _build_tree_index_excluding(
    nodes: list[Node],
    exclude: set[int],
) -> tuple[dict[int, list[int]], dict[int, int | None]]:
    """Build tree index while reparenting around excluded wrapper nodes.

    The previous implementation rebuilt the tree from raw depths while skipping
    excluded nodes. That breaks sibling relationships when a skipped wrapper
    sits between two visible siblings at the same depth, because descendants of
    the skipped wrapper can become children of the immediately previous visible
    node. Instead, build the full parent chain first and then walk upward to
    the nearest non-excluded ancestor for each kept node.
    """
    full_children, full_parent = _build_tree_index(nodes)
    del full_children  # parent chain is all we need below

    children: dict[int, list[int]] = {i: [] for i in range(len(nodes)) if i not in exclude}
    parent: dict[int, int | None] = {}

    for i in range(len(nodes)):
        if i in exclude:
            continue
        ancestor = full_parent.get(i)
        while ancestor is not None and ancestor in exclude:
            ancestor = full_parent.get(ancestor)
        parent[i] = ancestor
        if ancestor is not None:
            children[ancestor].append(i)

    return children, parent


# ---------------------------------------------------------------------------
# Pass 1: strip_actions
# ---------------------------------------------------------------------------

def strip_actions(nodes: list[Node]) -> None:
    """Remove non-useful AX actions from all nodes in-place."""
    for node in nodes:
        if node.secondary_actions:
            node.secondary_actions = [
                a for a in node.secondary_actions if a in _USEFUL_ACTIONS
            ]


# ---------------------------------------------------------------------------
# Pass 2: merge_labels_with_controls
# ---------------------------------------------------------------------------

def merge_labels_with_controls(nodes: list[Node]) -> set[int]:
    """Associate title text elements with their adjacent interactive targets.

    When AXStaticText appears as a label for an adjacent interactive element
    (e.g., "Name:" + text field), merge the text into the interactive element
    and remove the standalone text node.

    Returns set of indices to remove.
    """
    remove: set[int] = set()
    for i in range(len(nodes) - 1):
        if i in remove:
            continue
        node = nodes[i]
        next_node = nodes[i + 1]
        if (
            node.ax_role == "AXStaticText"
            and node.label
            and next_node.ax_role in _INTERACTIVE_ROLES
            and not next_node.label
            and node.depth == next_node.depth
        ):
            next_node.label = node.label
            remove.add(i)
    return remove


# ---------------------------------------------------------------------------
# Pass 3: collapse_into_interactive_parent
# ---------------------------------------------------------------------------

def collapse_into_interactive_parent(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Flatten non-interactive children into their selectable parent.

    When a clickable element (button, link, cell) contains only non-interactive
    leaf children (text, images), merge their labels into the parent.

    Returns set of child indices to remove.
    """
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if node.ax_role not in _SELECTABLE_ROLES:
            continue
        kids = children_map.get(i, [])
        if not kids:
            continue
        # All children must be non-interactive leaves
        all_non_interactive = all(
            nodes[c].ax_role not in _INTERACTIVE_ROLES
            and not children_map.get(c, [])
            for c in kids
        )
        if not all_non_interactive:
            continue
        # Merge child labels into parent if parent has no label
        child_labels = [nodes[c].label for c in kids if nodes[c].label]
        if child_labels and not node.label:
            node.label = " ".join(child_labels)
        for c in kids:
            remove.add(c)
    return remove


def collapse_row_children_into_row(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Lift leaf text/image content into sidebar-like rows only.

    Codex-style trees keep list rows directly selectable and labeled, but they
    still preserve nested text under richer cells and containers elsewhere. This
    pass only collapses leaf text/image children under AXRow elements.
    """
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if node.ax_role != "AXRow":
            continue

        kids = children_map.get(i, [])
        if not kids:
            continue

        child_texts: list[str] = []
        child_descriptions: list[str] = []
        row_child_indices: set[int] = set()

        for child_idx in kids:
            child = nodes[child_idx]
            if children_map.get(child_idx):
                continue
            if child.ax_role in _TEXT_ONLY_ROLES:
                text = child.label or child.value
                if text:
                    child_texts.append(text)
                row_child_indices.add(child_idx)
            elif child.ax_role == "AXImage":
                text = child.description or child.label or child.value
                if text:
                    child_descriptions.append(text)
                row_child_indices.add(child_idx)

        if not row_child_indices:
            continue

        if child_descriptions and node.description is None and node.label is None:
            if child_texts:
                node.description = child_descriptions[0]
            else:
                node.label = child_descriptions[0]

        if child_texts:
            joined_text = " ".join(child_texts)
            if node.label is None and node.description is None:
                node.label = joined_text
            elif node.value is None and joined_text != node.label:
                node.value = joined_text

        remove |= row_child_indices

    return remove


def flatten_outline_rows(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Collapse outline-row support content into the row itself.

    Native sidebars often expose rows as AXRow -> AXCell -> image/text. Codex's
    tree flattens those into direct row entries, while still keeping richer
    tables and content collections nested. This pass only targets outline rows.
    """
    remove: set[int] = set()

    def _leaf_descendants(idx: int) -> list[int]:
        leaves: list[int] = []
        for child_idx in children_map.get(idx, []):
            grandchildren = children_map.get(child_idx, [])
            if grandchildren:
                leaves.extend(_leaf_descendants(child_idx))
            else:
                leaves.append(child_idx)
        return leaves

    for i, node in enumerate(nodes):
        if node.ax_role != "AXRow" or node.subrole != "AXOutlineRow":
            continue

        descendants = _leaf_descendants(i)
        if not descendants:
            continue

        text_values: list[str] = []
        text_descriptions: list[str] = []
        image_descriptions: list[str] = []
        button_texts: list[str] = []
        merged_actions = list(node.secondary_actions)
        merged_states = list(node.states)
        flattenable = True

        def _merge_state(state: str) -> None:
            if state not in merged_states:
                merged_states.append(state)

        def _merge_action(action: str) -> None:
            if action not in merged_actions:
                merged_actions.append(action)

        for descendant_idx in descendants:
            descendant = nodes[descendant_idx]
            if descendant.ax_role == "AXStaticText":
                text = descendant.label or descendant.value
                if text:
                    text_values.append(text)
                description = descendant.description
                if description and description != text:
                    text_descriptions.append(description)
                remove.add(descendant_idx)
                continue
            if descendant.ax_role == "AXImage":
                description = descendant.description or descendant.label or descendant.value
                if description:
                    image_descriptions.append(description)
                remove.add(descendant_idx)
                continue
            if descendant.ax_role == "AXDisclosureTriangle":
                for state in descendant.states:
                    if state in {"expanded", "selected", "selectable"}:
                        _merge_state(state)
                for action in descendant.secondary_actions:
                    _merge_action(action)
                remove.add(descendant_idx)
                continue
            if descendant.ax_role == "AXButton":
                description = descendant.description or descendant.label or descendant.value
                if description:
                    button_texts.append(description)
                for action in descendant.secondary_actions:
                    _merge_action(action)
                remove.add(descendant_idx)
                continue
            if descendant.ax_role == "AXCell":
                remove.add(descendant_idx)
                continue
            flattenable = False
            break

        if not flattenable:
            continue

        main_text = " ".join(part for part in text_values if part).strip() or None
        icon_description = next((part for part in image_descriptions if part), None)
        button_text = next((part for part in button_texts if part), None)
        text_description = next((part for part in text_descriptions if part), None)
        existing_label = node.label
        existing_description = node.description

        if main_text is None and icon_description is None:
            continue

        node.secondary_actions = merged_actions
        node.states = merged_states

        if main_text and icon_description and icon_description != main_text:
            if node.description is None:
                node.description = icon_description
            if node.value is None:
                node.value = main_text
            if node.label == main_text:
                node.label = None
        elif main_text and button_text and button_text != main_text:
            if node.label is None:
                node.label = button_text
            elif node.label != button_text and node.description is None:
                node.description = button_text
            if node.value is None:
                node.value = main_text
        elif main_text:
            if existing_label and existing_label != main_text and node.description is None:
                node.description = existing_label
                node.label = None
            if existing_description and existing_description != main_text and node.description is None:
                node.description = existing_description
            if (
                node.label is None
                and node.description is None
                and node.value is None
                and ("expanded" in node.states or bool(node.secondary_actions))
            ):
                node.value = main_text
            elif node.label is None and node.description is None and node.value is None:
                node.label = main_text
            elif node.value is None and node.label != main_text:
                node.value = main_text

        if text_description and node.description is None and text_description != node.label and text_description != node.value:
            node.description = text_description

        for child_idx in children_map.get(i, []):
            child = nodes[child_idx]
            if child.ax_role in {"AXCell", "AXImage", "AXStaticText", "AXButton", "AXDisclosureTriangle"}:
                remove.add(child_idx)

    return remove


def collapse_button_title_children(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Collapse wrapper buttons that only host a title button and icon.

    Native collection views sometimes expose each card as an outer button with
    an icon child plus an inner title button. Keeping both bloats the index
    space without improving grounding.
    """
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if node.ax_role != "AXButton":
            continue
        kids = [child_idx for child_idx in children_map.get(i, []) if child_idx not in remove]
        if not kids:
            continue
        title_children = [child_idx for child_idx in kids if nodes[child_idx].ax_role == "AXButton"]
        if len(title_children) != 1:
            continue
        title_idx = title_children[0]
        title_node = nodes[title_idx]
        if children_map.get(title_idx):
            continue
        if any(nodes[child_idx].ax_role not in {"AXButton", "AXImage"} for child_idx in kids):
            continue
        title_text = title_node.label or title_node.value or title_node.description
        if not title_text:
            continue
        if node.label is None:
            node.label = title_text
        elif node.description is None and node.label != title_text:
            node.description = title_text
        if node.value is None and node.label != title_node.value and title_node.value not in {None, node.label}:
            node.value = title_node.value
        if node.description is None and title_node.description and title_node.description != node.label:
            node.description = title_node.description
        for child_idx in kids:
            remove.add(child_idx)
    return remove


def drop_empty_outline_rows(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Remove outline rows that contain no human-usable content.

    Some native sidebars expose decorative/icon-only rows as AXRow -> AXCell ->
    empty hosting views. They add index noise without giving the model any
    actionable grounding. After row flattening, drop outline rows whose subtree
    still contains no label, description, value, actions, or meaningful
    descendants.
    """
    remove: set[int] = set()

    def _subtree_indices(idx: int) -> list[int]:
        result = [idx]
        for child_idx in children_map.get(idx, []):
            result.extend(_subtree_indices(child_idx))
        return result

    for i, node in enumerate(nodes):
        if node.ax_role != "AXRow" or node.subrole != "AXOutlineRow":
            continue
        if node.label or node.description or node.value or node.secondary_actions:
            continue
        descendants = _subtree_indices(i)[1:]
        if not descendants:
            remove.add(i)
            continue
        meaningful = False
        for descendant_idx in descendants:
            descendant = nodes[descendant_idx]
            if descendant.label or descendant.description or descendant.value or descendant.secondary_actions:
                meaningful = True
                break
            if descendant.ax_role not in {"AXCell", "AXGroup"}:
                meaningful = True
                break
        if not meaningful:
            remove.update([i, *descendants])

    return remove


# ---------------------------------------------------------------------------
# Pass 4: remove_empty_subtrees
# ---------------------------------------------------------------------------

def _is_descriptive(node: Node) -> bool:
    """A node is descriptive if it has label, value, actions, or meaningful state."""
    if node.label:
        return True
    if node.value is not None and str(node.value).strip():
        return True
    if node.secondary_actions:
        return True
    if node.ax_role and node.ax_role in _INTERACTIVE_ROLES:
        return True
    for s in node.states:
        if s in ("selected", "focused", "expanded"):
            return True
    return False


def _subtree_is_descriptive(
    idx: int,
    children: dict[int, list[int]],
    nodes: list[Node],
) -> bool:
    """Post-order check: is any node in the subtree descriptive?"""
    if _is_descriptive(nodes[idx]):
        return True
    return any(_subtree_is_descriptive(c, children, nodes) for c in children[idx])


def remove_empty_subtrees(
    nodes: list[Node],
    children: dict[int, list[int]],
) -> set[int]:
    """Return set of list indices to remove (entire non-descriptive subtrees)."""
    remove: set[int] = set()

    def _collect_subtree(idx: int) -> None:
        remove.add(idx)
        for c in children[idx]:
            _collect_subtree(c)

    for i in range(len(nodes)):
        if i in remove:
            continue
        if not _subtree_is_descriptive(i, children, nodes):
            _collect_subtree(i)

    return remove


# ---------------------------------------------------------------------------
# Pass 5: remove_disabled_blanks
# ---------------------------------------------------------------------------

def remove_disabled_blanks(nodes: list[Node]) -> set[int]:
    """Return set of list indices for disabled elements with no label/value."""
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if "disabled" in node.states and not node.label and not node.value:
            remove.add(i)
    return remove


# ---------------------------------------------------------------------------
# Pass 6: unwrap_single_child_groups
# ---------------------------------------------------------------------------

def unwrap_single_child_groups(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Remove groups that contain exactly one child, promoting the child.

    Adjusts the child's depth to the group's depth. Transfers the group's
    label to the child if the child has none.

    Returns set of group indices to remove.
    """
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if i in remove:
            continue
        if node.ax_role not in _CONTAINER_ROLES:
            continue
        kids = children_map.get(i, [])
        if len(kids) != 1:
            continue
        child_idx = kids[0]
        child = nodes[child_idx]
        # Transfer parent's label to child if child has none
        if node.label and not child.label:
            child.label = node.label
        # Promote child (and its descendants) up by adjusting depths
        depth_delta = child.depth - node.depth
        _adjust_subtree_depth(child_idx, nodes, children_map, -depth_delta)
        remove.add(i)
    return remove


def _adjust_subtree_depth(
    idx: int,
    nodes: list[Node],
    children_map: dict[int, list[int]],
    delta: int,
) -> None:
    """Adjust depth of a node and all its descendants."""
    nodes[idx].depth += delta
    for c in children_map.get(idx, []):
        _adjust_subtree_depth(c, nodes, children_map, delta)


# ---------------------------------------------------------------------------
# Pass 7: collapse_redundant_wrappers
# ---------------------------------------------------------------------------

def collapse_redundant_wrappers(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Remove intermediate containers that add no semantic information.

    A container is redundant if it has a single child with the same role
    and the container itself has no label or actions.

    Returns set of indices to remove.
    """
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if i in remove:
            continue
        kids = children_map.get(i, [])
        if len(kids) != 1:
            continue
        child = nodes[kids[0]]
        if (
            node.ax_role == child.ax_role
            and not node.label
            and not node.secondary_actions
        ):
            # Promote child to parent's depth
            depth_delta = child.depth - node.depth
            _adjust_subtree_depth(kids[0], nodes, children_map, -depth_delta)
            remove.add(i)
    return remove


# ---------------------------------------------------------------------------
# Pass 8: merge_adjacent_text
# ---------------------------------------------------------------------------

def merge_adjacent_text(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Merge consecutive AXStaticText siblings into one node.

    Web pages often split text across many <span> elements, producing
    dozens of AXStaticText siblings. This merges them.

    Returns set of indices to remove (all but first in each run).
    """
    remove: set[int] = set()
    for _parent_idx, kids in children_map.items():
        run_start: int | None = None
        for child_idx in kids:
            if child_idx in remove:
                continue
            child = nodes[child_idx]
            if child.ax_role == "AXStaticText":
                if run_start is None:
                    run_start = child_idx
                else:
                    # Merge into run_start
                    first = nodes[run_start]
                    if child.label:
                        first.label = (first.label or "") + " " + child.label
                    remove.add(child_idx)
            else:
                run_start = None
    return remove


# ---------------------------------------------------------------------------
# Pass 9: inline_links_as_markdown
# ---------------------------------------------------------------------------

def inline_links_as_markdown(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Convert link + text children into markdown [text](url).

    Returns set of child indices to remove.
    """
    remove: set[int] = set()
    for i, node in enumerate(nodes):
        if node.ax_role != "AXLink":
            continue
        kids = children_map.get(i, [])
        if not kids:
            continue
        # Collect text from children
        texts: list[str] = []
        all_text = True
        for c in kids:
            if c in remove:
                continue
            child = nodes[c]
            if child.ax_role in ("AXStaticText", "AXHeading") and child.label:
                texts.append(child.label)
            elif child.ax_role == "AXImage":
                pass  # Skip images in links
            else:
                all_text = False
                break
        if all_text and texts:
            link_text = " ".join(texts)
            url = node.url or node.web_area_url or node.description or ""
            if url:
                node.label = f"[{link_text}]({url})"
            else:
                node.label = link_text
            for c in kids:
                remove.add(c)
    return remove


# ---------------------------------------------------------------------------
# Pass 10: combine_text_siblings
# ---------------------------------------------------------------------------

def combine_text_siblings(
    nodes: list[Node],
    children_map: dict[int, list[int]],
) -> set[int]:
    """Merge adjacent text-only siblings (text, heading) into one node.

    Returns set of indices to remove.
    """
    remove: set[int] = set()
    for _parent_idx, kids in children_map.items():
        run_start: int | None = None
        for child_idx in kids:
            if child_idx in remove:
                continue
            child = nodes[child_idx]
            if child.ax_role in _TEXT_ONLY_ROLES and not child.secondary_actions:
                if run_start is None:
                    run_start = child_idx
                else:
                    first = nodes[run_start]
                    if child.label:
                        sep = "\n" if child.ax_role == "AXHeading" else " "
                        first.label = (first.label or "") + sep + child.label
                        if first.ax_role in _TEXT_ONLY_ROLES:
                            first.value = None
                    remove.add(child_idx)
            else:
                run_start = None
    return remove


# ---------------------------------------------------------------------------
# Pass 11: prune_calendar_event_details
# ---------------------------------------------------------------------------

def prune_calendar_event_details(
    nodes: list[Node],
    children_map: dict[int, list[int]],
    bundle_id: str | None = None,
) -> set[int]:
    """Remove verbose subtrees under calendar event containers.

    Only applies to known calendar apps. Keeps the event summary node
    but removes its children to reduce verbosity.

    Returns set of indices to remove.
    """
    if bundle_id and bundle_id not in _CALENDAR_BUNDLES:
        return set()

    remove: set[int] = set()

    def _collect_subtree(idx: int) -> None:
        for c in children_map.get(idx, []):
            remove.add(c)
            _collect_subtree(c)

    for i, node in enumerate(nodes):
        # Heuristic: AXGroup nodes with labels containing date/time-like text
        # in calendar apps are event containers
        if (
            node.ax_role == "AXGroup"
            and node.label
            and node.depth >= 3
            and len(children_map.get(i, [])) >= 3
        ):
            _collect_subtree(i)
    return remove


# ---------------------------------------------------------------------------
# first_nonempty_index
# ---------------------------------------------------------------------------

def first_nonempty_index(nodes: list[Node]) -> int:
    """Find the first node that has a label, value, action, or interactive role."""
    for i, node in enumerate(nodes):
        if _is_descriptive(node):
            return i
    return 0


# ---------------------------------------------------------------------------
# Skip roles (always or conditionally)
# ---------------------------------------------------------------------------

def should_skip_role(node: Node) -> bool:
    """True if this node should be skipped entirely during serialization."""
    ax_role = node.ax_role
    if ax_role in _SKIP_ROLES:
        return True
    if ax_role in _SKIP_WHEN_EMPTY_ROLES:
        if not node.label and not node.secondary_actions:
            return True
    return False


# ---------------------------------------------------------------------------
# maxDepth with collapsed content
# ---------------------------------------------------------------------------

def mark_collapsed_depth(
    nodes: list[Node],
    max_depth: int = DEFAULT_MAX_DEPTH,
) -> set[int]:
    """Return indices of nodes exceeding max_depth (will be collapsed in output)."""
    return {i for i, node in enumerate(nodes) if node.depth > max_depth}


# ---------------------------------------------------------------------------
# SubtreeCollapse — node count threshold
# ---------------------------------------------------------------------------

def mark_collapsed_children(
    nodes: list[Node],
    children: dict[int, list[int]],
    threshold: int = DEFAULT_COLLAPSE_THRESHOLD,
) -> dict[int, int]:
    """For subtrees exceeding threshold, return {parent_idx: total_children}.

    The serializer should show first 5 children then "... (N more items hidden)".
    """
    collapsed: dict[int, int] = {}
    for i, child_list in children.items():
        if len(child_list) > threshold:
            collapsed[i] = len(child_list)
    return collapsed


# ---------------------------------------------------------------------------
# UIElementURLShortener
# ---------------------------------------------------------------------------

@dataclass
class URLShortenerConfig:
    """Configuration for URL shortening in tree output."""
    individual_limit: int = 80
    total_limit: int = 2000
    include_query: bool = False
    include_fragment: bool = False


# Regex to find URLs in text (markdown links or bare URLs)
_URL_RE = re.compile(r'https?://[^\s\)>]+')


def _shorten_single_url(url: str, config: URLShortenerConfig) -> str:
    """Shorten a single URL according to config."""
    try:
        parsed = urlparse(url)
    except Exception:
        return url[:config.individual_limit] if len(url) > config.individual_limit else url

    # Strip query and fragment unless configured to keep
    query = parsed.query if config.include_query else ""
    fragment = parsed.fragment if config.include_fragment else ""

    shortened = urlunparse((
        parsed.scheme,
        parsed.netloc,
        parsed.path,
        parsed.params,
        query,
        fragment,
    ))

    # Enforce individual limit
    if len(shortened) > config.individual_limit:
        shortened = shortened[:config.individual_limit - 3] + "..."

    return shortened


def shorten_urls(nodes: list[Node], config: URLShortenerConfig | None = None) -> None:
    """Shorten URLs across all nodes in-place."""
    if config is None:
        config = URLShortenerConfig()

    accumulated = 0

    for node in nodes:
        # Shorten web_area_url
        if node.web_area_url and accumulated < config.total_limit:
            node.web_area_url = _shorten_single_url(node.web_area_url, config)
            accumulated += len(node.web_area_url)

        # Shorten node.url (link URLs)
        if node.url and accumulated < config.total_limit:
            node.url = _shorten_single_url(node.url, config)
            accumulated += len(node.url)

        # Shorten URLs embedded in labels (e.g., markdown links)
        if node.label and "http" in node.label and accumulated < config.total_limit:
            def _replace_url(match: re.Match[str]) -> str:
                nonlocal accumulated
                url = match.group(0)
                if accumulated >= config.total_limit:
                    return url
                shortened = _shorten_single_url(url, config)
                accumulated += len(shortened)
                return shortened
            node.label = _URL_RE.sub(_replace_url, node.label)


# ---------------------------------------------------------------------------
# Web area node cap — truncate oversized web content subtrees
# ---------------------------------------------------------------------------

# Maximum nodes kept inside any single web area subtree. Nodes beyond this
# are dropped and replaced with a truncation indicator.  Keeping the *last*
# N nodes preserves the most-recently-rendered content (e.g. newest chat
# messages) which is what the agent typically cares about.
WEB_AREA_NODE_CAP = 300


def cap_web_area_nodes(
    nodes: list[Node],
    skip_indices: set[int],
    *,
    cap: int = WEB_AREA_NODE_CAP,
) -> set[int]:
    """Mark excess web area children for removal, keeping the last `cap` nodes.

    Returns a set of additional indices to skip.
    """
    extra_skips: set[int] = set()

    # Find web area root nodes
    web_area_indices: list[int] = []
    for i, node in enumerate(nodes):
        if i in skip_indices:
            continue
        if node.is_web_area:
            web_area_indices.append(i)

    for wa_idx in web_area_indices:
        wa_depth = nodes[wa_idx].depth
        # Collect all descendants (higher depth, until we hit same/lower depth)
        descendants: list[int] = []
        for j in range(wa_idx + 1, len(nodes)):
            if nodes[j].depth <= wa_depth:
                break
            if j not in skip_indices:
                descendants.append(j)

        if len(descendants) <= cap:
            continue

        # Keep last `cap` descendants, skip the rest
        to_remove = descendants[: len(descendants) - cap]
        extra_skips.update(to_remove)

        # Update the web area node label to indicate truncation
        removed_count = len(to_remove)
        trunc_note = f" ({removed_count} earlier elements truncated)"
        if nodes[wa_idx].label:
            nodes[wa_idx].label += trunc_note
        else:
            nodes[wa_idx].label = trunc_note.strip()

    return extra_skips


# ---------------------------------------------------------------------------
# Full pruning pipeline
# ---------------------------------------------------------------------------

def prune(
    nodes: list[Node],
    *,
    max_depth: int = DEFAULT_MAX_DEPTH,
    collapse_threshold: int = DEFAULT_COLLAPSE_THRESHOLD,
    advanced: bool = True,
    bundle_id: str | None = None,
) -> tuple[list[Node], dict[int, int], set[int]]:
    """Run the full pruning pipeline.

    Returns (pruned_nodes, subtree_collapsed_parents, depth_collapsed_parents).

    Pipeline order:
    1. Apply DisplayElement (lm_role, lm_description)
    2. Strip actions
    3. Merge labels with controls
    4. Collapse into interactive parents
    5. Remove always-skip roles
    6. Remove empty subtrees
    7. Remove disabled blanks
    8. Unwrap single-child groups
    9. Collapse redundant wrappers
    10. Merge adjacent text
    11. Inline links as markdown
    12. Combine text siblings
    13. Prune calendar event details
    14. Mark depth-exceeded nodes for collapse
    15. Mark large subtrees for SubtreeCollapse
    16. Filter, reindex, adjust depths
    17. Shorten URLs

    Parameters
    ----------
    nodes : flat list from walk_tree
    max_depth : depth threshold for collapsing
    collapse_threshold : children count threshold for SubtreeCollapse
    advanced : enable passes 2-3, 8-13, 17 (feature flag gating)
    bundle_id : app bundle ID (used for calendar event pass)
    """
    if not nodes:
        return [], {}, set()

    # Step 1: Apply DisplayElement
    apply_display_protocol(nodes)

    skip_indices: set[int] = set()

    if advanced:
        # Step 2: Strip actions
        strip_actions(nodes)

        # Step 3: Merge labels with controls
        skip_indices |= merge_labels_with_controls(nodes)

        # Step 4: Collapse into interactive parents
        children_map, _parent_map = _build_tree_index(nodes)
        skip_indices |= collapse_into_interactive_parent(nodes, children_map)

    # Step 5: Remove always-skip roles
    for i, node in enumerate(nodes):
        if should_skip_role(node):
            skip_indices.add(i)

    # Step 6: Remove empty subtrees
    children_map, parent_map = _build_tree_index(nodes)
    non_desc = remove_empty_subtrees(nodes, children_map)
    skip_indices |= non_desc

    # Step 7: Remove disabled blanks
    empty_disabled = remove_disabled_blanks(nodes)
    skip_indices |= empty_disabled

    if advanced:
        # Step 8: Unwrap single-child groups
        children_map, _pm = _build_tree_index_excluding(nodes, skip_indices)
        skip_indices |= unwrap_single_child_groups(nodes, children_map)

        # Step 9: Collapse redundant wrappers
        children_map, _pm = _build_tree_index_excluding(nodes, skip_indices)
        skip_indices |= collapse_redundant_wrappers(nodes, children_map)

        # Step 10: Merge adjacent text
        children_map, _pm = _build_tree_index_excluding(nodes, skip_indices)
        skip_indices |= merge_adjacent_text(nodes, children_map)

        # Step 11: Inline links as markdown
        # Reuse children_map from step 10 (no structural changes from step 10)
        skip_indices |= inline_links_as_markdown(nodes, children_map)

        # Step 12: Combine text siblings
        children_map, _pm = _build_tree_index_excluding(nodes, skip_indices)
        skip_indices |= combine_text_siblings(nodes, children_map)

        # Step 13: Prune calendar event details
        if bundle_id:
            children_map, _pm = _build_tree_index_excluding(nodes, skip_indices)
            skip_indices |= prune_calendar_event_details(
                nodes, children_map, bundle_id
            )

    # Step 13b: Cap web area subtrees that are still oversized after pruning
    if advanced:
        skip_indices |= cap_web_area_nodes(nodes, skip_indices)

    # Rebuild tree index for depth/collapse passes (excluding all removed nodes)
    children_map, parent_map = _build_tree_index_excluding(nodes, skip_indices)

    # Step 14: Mark depth-exceeded for collapse
    depth_collapsed = mark_collapsed_depth(nodes, max_depth)

    # Track which kept nodes have children hidden by depth collapse
    depth_collapsed_parents_orig: set[int] = set()
    for idx in depth_collapsed:
        p = parent_map.get(idx)
        while p is not None and p in depth_collapsed:
            p = parent_map.get(p)
        if p is not None and p not in skip_indices:
            depth_collapsed_parents_orig.add(p)

    # Step 15: Mark large subtrees for SubtreeCollapse
    collapsed_parents_orig = mark_collapsed_children(nodes, children_map, collapse_threshold)

    # Step 16: Filter and reindex
    kept_nodes: list[Node] = []
    collapse_info: dict[int, int] = {}
    old_to_new: dict[int, int] = {}

    for i, node in enumerate(nodes):
        if i in skip_indices:
            continue
        if i in depth_collapsed:
            continue

        # SubtreeCollapse: if this node's parent is a collapsed parent,
        # only keep first 5 children
        p = parent_map.get(i)
        if p is not None and p in collapsed_parents_orig:
            sibling_list = children_map.get(p, [])
            pos = next((j for j, s in enumerate(sibling_list) if s == i), None)
            if pos is not None and pos >= 5:
                continue  # Hidden by SubtreeCollapse

        new_idx = len(kept_nodes)
        old_to_new[i] = new_idx
        node.index = new_idx
        kept_nodes.append(node)

    # Build collapse info for new indices
    for old_parent, total in collapsed_parents_orig.items():
        if old_parent in old_to_new:
            collapse_info[old_to_new[old_parent]] = total

    # Build depth-collapsed parents for new indices
    depth_collapsed_parents_new: set[int] = set()
    for old_parent in depth_collapsed_parents_orig:
        if old_parent in old_to_new:
            depth_collapsed_parents_new.add(old_to_new[old_parent])

    # Adjust depths: find the first non-empty element and use it as base
    if kept_nodes:
        first_meaningful = first_nonempty_index(kept_nodes)
        if first_meaningful > 0:
            base_depth = kept_nodes[first_meaningful].depth
            for node in kept_nodes:
                node.depth = max(0, node.depth - base_depth)

    # Step 17: Shorten URLs
    if advanced:
        shorten_urls(kept_nodes)

    return kept_nodes, collapse_info, depth_collapsed_parents_new


def prune_for_codex_tree(
    nodes: list[Node],
    *,
    bundle_id: str | None = None,
) -> list[Node]:
    """Light pruning that preserves the raw AX hierarchy more faithfully.

    This keeps the tree close to the source structure while still:
    - removing obvious noise roles
    - lifting labels from adjacent/static text into controls where needed
    - collapsing simple text-only children into interactive parents
    - reindexing the remaining nodes
    """
    if not nodes:
        return []

    apply_display_protocol(nodes)

    skip_indices: set[int] = set()
    skip_indices |= merge_labels_with_controls(nodes)

    children_map, _parent_map = _build_tree_index(nodes)
    skip_indices |= collapse_row_children_into_row(nodes, children_map)
    skip_indices |= flatten_outline_rows(nodes, children_map)
    children_map, _parent_map = _build_tree_index_excluding(nodes, skip_indices)
    skip_indices |= drop_empty_outline_rows(nodes, children_map)
    children_map, _parent_map = _build_tree_index_excluding(nodes, skip_indices)
    skip_indices |= collapse_button_title_children(nodes, children_map)
    children_map, _parent_map = _build_tree_index_excluding(nodes, skip_indices)
    skip_indices |= combine_text_siblings(nodes, children_map)

    for i, node in enumerate(nodes):
        if node.ax_role == "AXList" and node.subrole == "AXCollectionList":
            node.states = [state for state in node.states if state != "focused"]
        if node.ax_role in _TEXT_ONLY_ROLES and node.label:
            node.value = None
        if node.ax_role in _CODEX_SKIP_ROLES:
            skip_indices.add(i)
            continue
        if (
            node.ax_role in _CODEX_EMPTY_WRAPPER_ROLES
            and not node.label
            and not node.description
            and not node.value
            and not node.secondary_actions
            and (not node.ax_id or len(children_map.get(i, [])) == 1)
        ):
            skip_indices.add(i)
            continue
        if (
            node.ax_role in {"AXImage", "AXStaticText"}
            and not node.label
            and not node.description
            and not node.value
        ):
            skip_indices.add(i)

    _, parent_map = _build_tree_index_excluding(nodes, skip_indices)
    new_depths: dict[int, int] = {}
    kept_nodes: list[Node] = []
    for i, node in enumerate(nodes):
        if i in skip_indices:
            continue
        parent_idx = parent_map.get(i)
        if parent_idx is None:
            node.depth = 0
        else:
            node.depth = new_depths[parent_idx] + 1
        new_depths[i] = node.depth
        node.index = len(kept_nodes)
        kept_nodes.append(node)

    shorten_urls(kept_nodes)
    return kept_nodes
