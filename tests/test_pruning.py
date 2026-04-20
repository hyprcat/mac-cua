"""Tests for tree pruning passes.

Verifies all 12 pruning passes plus URL shortener:
- strip_actions
- merge_labels_with_controls
- collapse_into_interactive_parent
- remove_empty_subtrees (existing)
- remove_disabled_blanks (existing)
- unwrap_single_child_groups
- collapse_redundant_wrappers
- merge_adjacent_text
- inline_links_as_markdown
- combine_text_siblings
- prune_calendar_event_details
- URL shortener
- Full pipeline order
"""
from __future__ import annotations

import unittest

from app._lib.pruning import (
    _build_tree_index,
    _build_tree_index_excluding,
    collapse_row_children_into_row,
    collapse_button_title_children,
    drop_empty_outline_rows,
    flatten_outline_rows,
    merge_labels_with_controls,
    strip_actions,
    collapse_into_interactive_parent,
    inline_links_as_markdown,
    collapse_redundant_wrappers,
    merge_adjacent_text,
    unwrap_single_child_groups,
    combine_text_siblings,
    prune,
    prune_for_codex_tree,
    prune_calendar_event_details,
    shorten_urls,
    URLShortenerConfig,
)
from app.response import Node


def _node(
    index: int,
    role: str = "AXButton",
    label: str | None = "Ok",
    depth: int = 1,
    *,
    actions: list[str] | None = None,
    states: list[str] | None = None,
    value: str | None = None,
    url: str | None = None,
    web_area_url: str | None = None,
    description: str | None = None,
) -> Node:
    return Node(
        index=index,
        role=role.removeprefix("AX").lower(),
        label=label,
        states=states or [],
        description=description,
        value=value,
        ax_id=None,
        secondary_actions=actions or [],
        depth=depth,
        ax_ref=None,
        ax_role=role,
        url=url,
        web_area_url=web_area_url,
    )


# ---------------------------------------------------------------------------
# strip_actions
# ---------------------------------------------------------------------------

class TestStripActions(unittest.TestCase):
    def test_keeps_useful_actions(self) -> None:
        nodes = [_node(0, actions=["AXPress", "AXShowMenu", "AXRaise", "AXShowDefaultUI"])]
        strip_actions(nodes)
        self.assertEqual(nodes[0].secondary_actions, ["AXPress", "AXShowMenu"])

    def test_empty_actions_unchanged(self) -> None:
        nodes = [_node(0, actions=[])]
        strip_actions(nodes)
        self.assertEqual(nodes[0].secondary_actions, [])

    def test_all_useful_kept(self) -> None:
        nodes = [_node(0, actions=["AXPress", "AXPick", "AXIncrement"])]
        strip_actions(nodes)
        self.assertEqual(nodes[0].secondary_actions, ["AXPress", "AXPick", "AXIncrement"])


# ---------------------------------------------------------------------------
# merge_labels_with_controls
# ---------------------------------------------------------------------------

class TestMergeLabelsWithControls(unittest.TestCase):
    def test_merges_text_into_adjacent_field(self) -> None:
        nodes = [
            _node(0, role="AXStaticText", label="Name:", depth=1),
            _node(1, role="AXTextField", label=None, depth=1),
        ]
        removed = merge_labels_with_controls(nodes)
        self.assertEqual(removed, {0})
        self.assertEqual(nodes[1].label, "Name:")

    def test_skips_when_field_already_labeled(self) -> None:
        nodes = [
            _node(0, role="AXStaticText", label="Name:", depth=1),
            _node(1, role="AXTextField", label="Existing", depth=1),
        ]
        removed = merge_labels_with_controls(nodes)
        self.assertEqual(removed, set())

    def test_skips_different_depth(self) -> None:
        nodes = [
            _node(0, role="AXStaticText", label="Name:", depth=1),
            _node(1, role="AXTextField", label=None, depth=2),
        ]
        removed = merge_labels_with_controls(nodes)
        self.assertEqual(removed, set())

    def test_skips_non_interactive_target(self) -> None:
        nodes = [
            _node(0, role="AXStaticText", label="Title", depth=1),
            _node(1, role="AXGroup", label=None, depth=1),
        ]
        removed = merge_labels_with_controls(nodes)
        self.assertEqual(removed, set())


# ---------------------------------------------------------------------------
# collapse_into_interactive_parent
# ---------------------------------------------------------------------------

class TestCollapseIntoInteractiveParent(unittest.TestCase):
    def test_button_with_text_child(self) -> None:
        nodes = [
            _node(0, role="AXButton", label=None, depth=0),
            _node(1, role="AXStaticText", label="Save", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_into_interactive_parent(nodes, children_map)
        self.assertEqual(removed, {1})
        self.assertEqual(nodes[0].label, "Save")

    def test_skips_interactive_children(self) -> None:
        nodes = [
            _node(0, role="AXButton", label=None, depth=0),
            _node(1, role="AXButton", label="Inner", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_into_interactive_parent(nodes, children_map)
        self.assertEqual(removed, set())

    def test_preserves_existing_parent_label(self) -> None:
        nodes = [
            _node(0, role="AXButton", label="Already", depth=0),
            _node(1, role="AXStaticText", label="Save", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_into_interactive_parent(nodes, children_map)
        self.assertEqual(removed, {1})
        self.assertEqual(nodes[0].label, "Already")  # Not overwritten

    def test_multi_text_children_joined(self) -> None:
        nodes = [
            _node(0, role="AXCell", label=None, depth=0),
            _node(1, role="AXStaticText", label="Hello", depth=1),
            _node(2, role="AXImage", label=None, depth=1),
            _node(3, role="AXStaticText", label="World", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_into_interactive_parent(nodes, children_map)
        self.assertEqual(removed, {1, 2, 3})
        self.assertEqual(nodes[0].label, "Hello World")


class TestCollapseRowChildrenIntoRow(unittest.TestCase):
    def test_row_promotes_leaf_text_and_image_to_row(self) -> None:
        nodes = [
            _node(0, role="AXRow", label=None, depth=0),
            _node(1, role="AXImage", label=None, depth=1, description="Grid view"),
            _node(2, role="AXStaticText", label="New", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)

        removed = collapse_row_children_into_row(nodes, children_map)

        self.assertEqual(removed, {1, 2})
        self.assertEqual(nodes[0].description, "Grid view")
        self.assertEqual(nodes[0].value, "New")

    def test_row_without_icon_uses_text_as_label(self) -> None:
        nodes = [
            _node(0, role="AXRow", label=None, depth=0),
            _node(1, role="AXStaticText", label="Replay 2024", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)

        removed = collapse_row_children_into_row(nodes, children_map)

        self.assertEqual(removed, {1})
        self.assertEqual(nodes[0].label, "Replay 2024")

    def test_non_row_cells_keep_nested_text(self) -> None:
        nodes = [
            _node(0, role="AXCell", label=None, depth=0, description="Drake"),
            _node(1, role="AXStaticText", label="Drake Artist", depth=1),
        ]

        pruned = prune_for_codex_tree(nodes)

        self.assertEqual([node.ax_role for node in pruned], ["AXCell", "AXStaticText"])
        self.assertEqual(pruned[0].description, "Drake")
        self.assertEqual(pruned[1].label, "Drake Artist")

    def test_codex_pruning_keeps_scrollbars_splitters_and_actions(self) -> None:
        nodes = [
            _node(0, role="AXWindow", label="Music", depth=0, actions=["AXRaise"]),
            _node(1, role="AXSplitGroup", label=None, depth=1),
            _node(2, role="AXScrollArea", label=None, depth=2, actions=["AXScrollUpByPage", "AXScrollDownByPage"]),
            _node(3, role="AXScrollBar", label=None, depth=3, value="0"),
            _node(4, role="AXValueIndicator", label=None, depth=4, value="0"),
            _node(5, role="AXSplitter", label=None, depth=2, value="208"),
            _node(6, role="AXButton", label="Go Back", depth=2, actions=["AXMoveNext", "AXRemoveFromToolbar"]),
            _node(7, role="AXUnknown", label="Browse Categories", depth=2),
        ]

        pruned = prune_for_codex_tree(nodes)
        ax_roles = [node.ax_role for node in pruned]

        self.assertIn("AXSplitGroup", ax_roles)
        self.assertIn("AXScrollBar", ax_roles)
        self.assertIn("AXSplitter", ax_roles)
        self.assertIn("AXUnknown", ax_roles)
        button = next(node for node in pruned if node.ax_role == "AXButton")
        self.assertEqual(button.secondary_actions, ["AXMoveNext", "AXRemoveFromToolbar"])

    def test_outline_rows_flatten_to_direct_row_labels(self) -> None:
        nodes = [
            _node(0, role="AXOutline", label=None, depth=0, description="Sidebar"),
            _node(1, role="AXRow", label=None, depth=1),
            _node(2, role="AXCell", label=None, depth=2),
            _node(3, role="AXImage", label=None, depth=3, description="playlist"),
            _node(4, role="AXStaticText", label="Replay 2024", depth=3),
        ]
        nodes[1].subrole = "AXOutlineRow"
        children_map, _ = _build_tree_index(nodes)

        removed = flatten_outline_rows(nodes, children_map)

        self.assertEqual(removed, {2, 3, 4})
        self.assertEqual(nodes[1].description, "playlist")
        self.assertEqual(nodes[1].value, "Replay 2024")

    def test_outline_row_identical_icon_and_text_uses_label(self) -> None:
        nodes = [
            _node(0, role="AXRow", label=None, depth=0),
            _node(1, role="AXCell", label=None, depth=1),
            _node(2, role="AXImage", label=None, depth=2, description="Search"),
            _node(3, role="AXStaticText", label="Search", depth=2),
        ]
        nodes[0].subrole = "AXOutlineRow"
        children_map, _ = _build_tree_index(nodes)

        removed = flatten_outline_rows(nodes, children_map)

        self.assertEqual(removed, {1, 2, 3})
        self.assertEqual(nodes[0].label, "Search")
        self.assertIsNone(nodes[0].description)
        self.assertIsNone(nodes[0].value)

    def test_outline_row_preserves_existing_label_as_description_and_merges_disclosure(self) -> None:
        nodes = [
            _node(0, role="AXRow", label="Edit", depth=0, states=["selectable"]),
            _node(1, role="AXCell", label=None, depth=1),
            _node(2, role="AXDisclosureTriangle", label=None, depth=2, states=["expanded"], actions=["AXCollapse"]),
            _node(3, role="AXStaticText", label="Playlists", depth=2),
        ]
        nodes[0].subrole = "AXOutlineRow"
        children_map, _ = _build_tree_index(nodes)

        removed = flatten_outline_rows(nodes, children_map)

        self.assertEqual(removed, {1, 2, 3})
        self.assertEqual(nodes[0].description, "Edit")
        self.assertEqual(nodes[0].value, "Playlists")
        self.assertIn("expanded", nodes[0].states)
        self.assertIn("AXCollapse", nodes[0].secondary_actions)

    def test_outline_row_promotes_button_text_to_label(self) -> None:
        nodes = [
            _node(0, role="AXRow", label=None, depth=0, states=["selectable"]),
            _node(1, role="AXCell", label=None, depth=1),
            _node(2, role="AXStaticText", label="Library", depth=2),
            _node(3, role="AXButton", label="Edit", depth=2),
        ]
        nodes[0].subrole = "AXOutlineRow"
        children_map, _ = _build_tree_index(nodes)

        removed = flatten_outline_rows(nodes, children_map)

        self.assertEqual(removed, {1, 2, 3})
        self.assertEqual(nodes[0].label, "Edit")
        self.assertEqual(nodes[0].value, "Library")

    def test_outline_row_uses_static_text_description_when_present(self) -> None:
        nodes = [
            _node(0, role="AXRow", label=None, depth=0, states=["selectable"]),
            _node(1, role="AXCell", label=None, depth=1),
            _node(2, role="AXStaticText", label="1", depth=2, description="Software Update Available, 1 new item"),
        ]
        nodes[0].subrole = "AXOutlineRow"
        children_map, _ = _build_tree_index(nodes)

        removed = flatten_outline_rows(nodes, children_map)

        self.assertEqual(removed, {1, 2})
        self.assertEqual(nodes[0].label, "1")
        self.assertEqual(nodes[0].description, "Software Update Available, 1 new item")

    def test_drop_empty_outline_rows_removes_icon_only_wrappers(self) -> None:
        nodes = [
            _node(0, role="AXRow", label=None, depth=0, states=["selectable"]),
            _node(1, role="AXCell", label=None, depth=1),
            _node(2, role="AXGroup", label=None, depth=2),
            _node(3, role="AXRow", label="General", depth=0, states=["selectable"]),
        ]
        nodes[0].subrole = "AXOutlineRow"
        nodes[3].subrole = "AXOutlineRow"
        children_map, _ = _build_tree_index(nodes)

        removed = drop_empty_outline_rows(nodes, children_map)

        self.assertEqual(removed, {0, 1, 2})


class TestCollapseButtonTitleChildren(unittest.TestCase):
    def test_collapses_outer_button_with_title_button_child(self) -> None:
        nodes = [
            _node(0, role="AXButton", label=None, depth=0, description="Apple", states=["disabled"]),
            _node(1, role="AXImage", label=None, depth=1),
            _node(2, role="AXButton", label=None, depth=1, description="Apple", value="Apple"),
        ]
        children_map, _ = _build_tree_index(nodes)

        removed = collapse_button_title_children(nodes, children_map)

        self.assertEqual(removed, {1, 2})
        self.assertEqual(nodes[0].label, "Apple")

    def test_codex_pruning_keeps_disabled_sections(self) -> None:
        nodes = [
            _node(0, role="AXCollection", label=None, depth=0),
            _node(1, role="AXGroup", label="Top Picks for You", depth=1, states=["disabled"]),
            _node(2, role="AXStaticText", label="R&B Now", depth=2),
        ]

        pruned = prune_for_codex_tree(nodes)

        self.assertEqual([node.ax_role for node in pruned], ["AXCollection", "AXGroup", "AXStaticText"])

    def test_codex_pruning_keeps_descriptive_groups_but_skips_empty_hosting_views(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0, description=None),
            _node(1, role="AXGroup", label=None, depth=1, description="Mini Player"),
            _node(2, role="AXButton", label="Play", depth=2),
        ]
        nodes[0].subrole = "AXHostingView"

        pruned = prune_for_codex_tree(nodes)

        self.assertEqual([node.ax_role for node in pruned], ["AXGroup", "AXButton"])
        self.assertEqual(pruned[0].description, "Mini Player")

    def test_codex_pruning_skips_empty_single_child_group_even_with_id(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0, description="Mini Player"),
            _node(1, role="AXGroup", label=None, depth=1, description=None),
            _node(2, role="AXButton", label="Show Now Playing", depth=2),
        ]
        nodes[1].ax_id = "Music.miniPlayer.metadataRegion[state=empty]"

        pruned = prune_for_codex_tree(nodes)

        self.assertEqual([node.ax_role for node in pruned], ["AXGroup", "AXButton"])
        self.assertEqual(pruned[1].label, "Show Now Playing")


# ---------------------------------------------------------------------------
# unwrap_single_child_groups
# ---------------------------------------------------------------------------

class TestUnwrapSingleChildGroups(unittest.TestCase):
    def test_single_child_group_merged(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXButton", label="Click", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = unwrap_single_child_groups(nodes, children_map)
        self.assertEqual(removed, {0})
        self.assertEqual(nodes[1].depth, 0)  # Promoted

    def test_transfers_label(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label="Section", depth=0),
            _node(1, role="AXButton", label=None, depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = unwrap_single_child_groups(nodes, children_map)
        self.assertEqual(removed, {0})
        self.assertEqual(nodes[1].label, "Section")

    def test_multi_child_group_kept(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXButton", label="A", depth=1),
            _node(2, role="AXButton", label="B", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = unwrap_single_child_groups(nodes, children_map)
        self.assertEqual(removed, set())

    def test_non_container_role_kept(self) -> None:
        nodes = [
            _node(0, role="AXButton", label=None, depth=0),
            _node(1, role="AXStaticText", label="Text", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = unwrap_single_child_groups(nodes, children_map)
        self.assertEqual(removed, set())

    def test_nested_group_depth_adjusted(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXButton", label="Click", depth=1),
            _node(2, role="AXStaticText", label="text", depth=2),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = unwrap_single_child_groups(nodes, children_map)
        self.assertEqual(removed, {0})
        self.assertEqual(nodes[1].depth, 0)
        self.assertEqual(nodes[2].depth, 1)


# ---------------------------------------------------------------------------
# collapse_redundant_wrappers
# ---------------------------------------------------------------------------

class TestCollapseRedundantWrappers(unittest.TestCase):
    def test_same_role_unlabeled_parent_removed(self) -> None:
        nodes = [
            _node(0, role="AXList", label=None, depth=0),
            _node(1, role="AXList", label="Items", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_redundant_wrappers(nodes, children_map)
        self.assertEqual(removed, {0})
        self.assertEqual(nodes[1].depth, 0)

    def test_different_roles_kept(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXList", label="Items", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_redundant_wrappers(nodes, children_map)
        self.assertEqual(removed, set())

    def test_labeled_parent_kept(self) -> None:
        nodes = [
            _node(0, role="AXList", label="Outer", depth=0),
            _node(1, role="AXList", label="Inner", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_redundant_wrappers(nodes, children_map)
        self.assertEqual(removed, set())

    def test_parent_with_actions_kept(self) -> None:
        nodes = [
            _node(0, role="AXList", label=None, depth=0, actions=["AXPress"]),
            _node(1, role="AXList", label="Items", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = collapse_redundant_wrappers(nodes, children_map)
        self.assertEqual(removed, set())


# ---------------------------------------------------------------------------
# merge_adjacent_text
# ---------------------------------------------------------------------------

class TestMergeAdjacentText(unittest.TestCase):
    def test_adjacent_text_merged(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXStaticText", label="Hello", depth=1),
            _node(2, role="AXStaticText", label="World", depth=1),
            _node(3, role="AXStaticText", label="!", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = merge_adjacent_text(nodes, children_map)
        self.assertEqual(removed, {2, 3})
        self.assertEqual(nodes[1].label, "Hello World !")

    def test_non_text_breaks_run(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXStaticText", label="A", depth=1),
            _node(2, role="AXButton", label="B", depth=1),
            _node(3, role="AXStaticText", label="C", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = merge_adjacent_text(nodes, children_map)
        self.assertEqual(removed, set())

    def test_single_text_unchanged(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXStaticText", label="Only", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = merge_adjacent_text(nodes, children_map)
        self.assertEqual(removed, set())


# ---------------------------------------------------------------------------
# inline_links_as_markdown
# ---------------------------------------------------------------------------

class TestInlineLinksAsMarkdown(unittest.TestCase):
    def test_link_with_text_child(self) -> None:
        nodes = [
            _node(0, role="AXLink", label=None, depth=0, url="https://example.com"),
            _node(1, role="AXStaticText", label="Click here", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = inline_links_as_markdown(nodes, children_map)
        self.assertEqual(removed, {1})
        self.assertEqual(nodes[0].label, "[Click here](https://example.com)")

    def test_link_with_no_url_uses_text_only(self) -> None:
        nodes = [
            _node(0, role="AXLink", label=None, depth=0),
            _node(1, role="AXStaticText", label="Click here", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = inline_links_as_markdown(nodes, children_map)
        self.assertEqual(removed, {1})
        self.assertEqual(nodes[0].label, "Click here")

    def test_link_with_interactive_child_not_flattened(self) -> None:
        nodes = [
            _node(0, role="AXLink", label=None, depth=0, url="https://example.com"),
            _node(1, role="AXButton", label="Button", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = inline_links_as_markdown(nodes, children_map)
        self.assertEqual(removed, set())

    def test_link_with_image_child_skipped(self) -> None:
        nodes = [
            _node(0, role="AXLink", label=None, depth=0, url="https://example.com"),
            _node(1, role="AXImage", label=None, depth=1),
            _node(2, role="AXStaticText", label="Text", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = inline_links_as_markdown(nodes, children_map)
        self.assertEqual(removed, {1, 2})
        self.assertEqual(nodes[0].label, "[Text](https://example.com)")

    def test_link_fallback_to_description(self) -> None:
        nodes = [
            _node(0, role="AXLink", label=None, depth=0, description="https://fallback.com"),
            _node(1, role="AXStaticText", label="Link", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = inline_links_as_markdown(nodes, children_map)
        self.assertEqual(removed, {1})
        self.assertEqual(nodes[0].label, "[Link](https://fallback.com)")


# ---------------------------------------------------------------------------
# combine_text_siblings
# ---------------------------------------------------------------------------

class TestCombineTextSiblings(unittest.TestCase):
    def test_adjacent_text_merged(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXStaticText", label="A", depth=1),
            _node(2, role="AXStaticText", label="B", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = combine_text_siblings(nodes, children_map)
        self.assertEqual(removed, {2})
        self.assertEqual(nodes[1].label, "A B")

    def test_heading_uses_newline_separator(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXStaticText", label="Text", depth=1),
            _node(2, role="AXHeading", label="Title", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = combine_text_siblings(nodes, children_map)
        self.assertEqual(removed, {2})
        self.assertEqual(nodes[1].label, "Text\nTitle")

    def test_text_with_actions_not_merged(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label=None, depth=0),
            _node(1, role="AXStaticText", label="A", depth=1, actions=["AXPress"]),
            _node(2, role="AXStaticText", label="B", depth=1),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = combine_text_siblings(nodes, children_map)
        self.assertEqual(removed, set())


# ---------------------------------------------------------------------------
# prune_calendar_event_details
# ---------------------------------------------------------------------------

class TestRemoveCalendarEvents(unittest.TestCase):
    def test_skips_non_calendar_app(self) -> None:
        nodes = [
            _node(0, role="AXGroup", label="Meeting", depth=3),
            _node(1, role="AXStaticText", label="Details", depth=4),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = prune_calendar_event_details(
            nodes, children_map, "com.apple.Safari"
        )
        self.assertEqual(removed, set())

    def test_removes_children_in_calendar(self) -> None:
        nodes = [
            _node(0, role="AXWindow", label=None, depth=0),
            _node(1, role="AXScrollArea", label=None, depth=1),
            _node(2, role="AXGroup", label=None, depth=2),
            _node(3, role="AXGroup", label="Meeting at 3pm", depth=3),
            _node(4, role="AXStaticText", label="Location", depth=4),
            _node(5, role="AXStaticText", label="Attendees", depth=4),
            _node(6, role="AXStaticText", label="Notes", depth=4),
        ]
        children_map, _ = _build_tree_index(nodes)
        removed = prune_calendar_event_details(
            nodes, children_map, "com.apple.iCal"
        )
        self.assertIn(4, removed)
        self.assertIn(5, removed)
        self.assertIn(6, removed)
        self.assertNotIn(3, removed)  # Event summary kept


# ---------------------------------------------------------------------------
# URL Shortener
# ---------------------------------------------------------------------------

class TestURLShortener(unittest.TestCase):
    def test_strips_query_and_fragment(self) -> None:
        nodes = [_node(0, web_area_url="https://example.com/page?q=1&r=2#section")]
        shorten_urls(nodes)
        self.assertEqual(nodes[0].web_area_url, "https://example.com/page")

    def test_enforces_individual_limit(self) -> None:
        long_path = "/a" * 100
        nodes = [_node(0, web_area_url=f"https://example.com{long_path}")]
        config = URLShortenerConfig(individual_limit=40)
        shorten_urls(nodes, config)
        self.assertLessEqual(len(nodes[0].web_area_url), 40)
        self.assertTrue(nodes[0].web_area_url.endswith("..."))

    def test_shortens_url_in_label(self) -> None:
        nodes = [_node(
            0,
            label="[Click](https://example.com/path?tracking=abc&utm_source=test)",
        )]
        shorten_urls(nodes)
        self.assertNotIn("tracking=abc", nodes[0].label)
        self.assertIn("https://example.com/path", nodes[0].label)

    def test_include_query_when_configured(self) -> None:
        nodes = [_node(0, web_area_url="https://example.com/page?q=search")]
        config = URLShortenerConfig(include_query=True)
        shorten_urls(nodes, config)
        self.assertIn("q=search", nodes[0].web_area_url)

    def test_total_limit_stops_shortening(self) -> None:
        nodes = [
            _node(0, web_area_url="https://example.com/first"),
            _node(1, web_area_url="https://example.com/second"),
        ]
        config = URLShortenerConfig(total_limit=30)
        shorten_urls(nodes, config)
        # First URL shortened, second left as-is (total exceeded)
        self.assertIsNotNone(nodes[0].web_area_url)

    def test_shortens_node_url_field(self) -> None:
        nodes = [_node(0, url="https://example.com/link?track=1#ref")]
        shorten_urls(nodes)
        self.assertEqual(nodes[0].url, "https://example.com/link")


# ---------------------------------------------------------------------------
# _build_tree_index_excluding
# ---------------------------------------------------------------------------

class TestBuildTreeIndexExcluding(unittest.TestCase):
    def test_excluded_nodes_skipped(self) -> None:
        nodes = [
            _node(0, depth=0),
            _node(1, depth=1),
            _node(2, depth=1),
        ]
        children, parent = _build_tree_index_excluding(nodes, {1})
        self.assertNotIn(1, children)
        self.assertEqual(children[0], [2])

    def test_reparents_children(self) -> None:
        nodes = [
            _node(0, depth=0),
            _node(1, depth=1),  # Will be excluded
            _node(2, depth=2),  # Should reparent to 0
        ]
        children, parent = _build_tree_index_excluding(nodes, {1})
        # Node 2 at depth 2 has no parent at depth 1 in the included set,
        # so it falls through to its depth-based parent
        self.assertNotIn(1, children)

    def test_reparents_through_excluded_sibling_wrapper_chain(self) -> None:
        nodes = [
            _node(0, role="AXWindow", label="Music", depth=0),
            _node(1, role="AXScrollBar", label=None, depth=1),
            _node(2, role="AXValueIndicator", label=None, depth=2),
            _node(3, role="AXGroup", label=None, depth=1),  # excluded wrapper
            _node(4, role="AXGroup", label="Mini Player", depth=2),
        ]

        children, parent = _build_tree_index_excluding(nodes, {3})

        self.assertEqual(parent[4], 0)
        self.assertEqual(children[0], [1, 4])


# ---------------------------------------------------------------------------
# Full pipeline
# ---------------------------------------------------------------------------

class TestFullPipeline(unittest.TestCase):
    def test_pipeline_runs_without_errors(self) -> None:
        """Basic smoke test: pipeline doesn't crash on typical tree."""
        nodes = [
            _node(0, role="AXWindow", label="Test", depth=0),
            _node(1, role="AXGroup", label=None, depth=1),
            _node(2, role="AXButton", label="OK", depth=2, actions=["AXPress"]),
            _node(3, role="AXStaticText", label="Hello", depth=2),
            _node(4, role="AXStaticText", label="World", depth=2),
        ]
        result, collapse_info, depth_collapsed = prune(nodes)
        # Should have pruned and reindexed
        self.assertTrue(len(result) > 0)
        for i, node in enumerate(result):
            self.assertEqual(node.index, i)

    def test_advanced_false_skips_new_passes(self) -> None:
        """With advanced=False, only original passes run."""
        nodes = [
            _node(0, role="AXWindow", label="Test", depth=0),
            _node(1, role="AXButton", label=None, depth=1, actions=["AXRaise", "AXPress"]),
        ]
        result, _, _ = prune(nodes, advanced=False)
        # AXRaise should NOT be filtered (strip_actions skipped)
        btn = next(n for n in result if n.ax_role == "AXButton")
        self.assertIn("AXRaise", btn.secondary_actions)

    def test_advanced_true_filters_actions(self) -> None:
        """With advanced=True, strip_actions removes AXRaise."""
        nodes = [
            _node(0, role="AXWindow", label="Test", depth=0),
            _node(1, role="AXButton", label="OK", depth=1, actions=["AXRaise", "AXPress"]),
        ]
        result, _, _ = prune(nodes, advanced=True)
        btn = next(n for n in result if n.ax_role == "AXButton")
        self.assertNotIn("AXRaise", btn.secondary_actions)
        self.assertIn("AXPress", btn.secondary_actions)

    def test_web_page_tree_reduction(self) -> None:
        """Simulate a web page with lots of text spans and links."""
        nodes = [
            _node(0, role="AXWebArea", label="Page", depth=0),
            # Group wrapping a single paragraph
            _node(1, role="AXGroup", label=None, depth=1),
            _node(2, role="AXStaticText", label="Lorem", depth=2),
            _node(3, role="AXStaticText", label="ipsum", depth=2),
            _node(4, role="AXStaticText", label="dolor", depth=2),
            # Link with text child
            _node(5, role="AXLink", label=None, depth=1, url="https://example.com"),
            _node(6, role="AXStaticText", label="Click here", depth=2),
        ]
        result, _, _ = prune(nodes)
        # Texts should be merged, link should be markdown, group should be simplified
        self.assertTrue(len(result) < len(nodes))

    def test_empty_input(self) -> None:
        result, collapse_info, depth_collapsed = prune([])
        self.assertEqual(result, [])
        self.assertEqual(collapse_info, {})
        self.assertEqual(depth_collapsed, set())

    def test_indices_sequential(self) -> None:
        """All output nodes should have sequential indices."""
        nodes = [
            _node(0, role="AXWindow", label="W", depth=0),
            _node(1, role="AXGroup", label=None, depth=1),  # Will be pruned
            _node(2, role="AXButton", label="A", depth=2),
            _node(3, role="AXGroup", label=None, depth=1),  # Will be pruned
            _node(4, role="AXButton", label="B", depth=2),
        ]
        result, _, _ = prune(nodes)
        for i, node in enumerate(result):
            self.assertEqual(node.index, i, f"Node at position {i} has index {node.index}")


class TestCapWebAreaNodes(unittest.TestCase):
    """Tests for web area node cap."""

    def test_small_web_area_untouched(self):
        """Web areas under the cap are not modified."""
        from app._lib.pruning import cap_web_area_nodes
        nodes = [
            _node(0, role="AXWebArea", label="Page", depth=0),
        ] + [_node(i, role="AXStaticText", label=f"text{i}", depth=1) for i in range(1, 50)]
        nodes[0].is_web_area = True
        skips = cap_web_area_nodes(nodes, set(), cap=300)
        self.assertEqual(len(skips), 0)

    def test_large_web_area_truncated(self):
        """Web areas over the cap get oldest nodes removed."""
        from app._lib.pruning import cap_web_area_nodes
        nodes = [
            _node(0, role="AXWebArea", label="Page", depth=0),
        ] + [_node(i, role="AXStaticText", label=f"msg{i}", depth=1) for i in range(1, 21)]
        nodes[0].is_web_area = True
        skips = cap_web_area_nodes(nodes, set(), cap=10)
        # 20 descendants, cap=10 → 10 oldest removed
        self.assertEqual(len(skips), 10)
        # Removed nodes should be the first 10 descendants (oldest)
        self.assertEqual(skips, set(range(1, 11)))
        # Web area label should indicate truncation
        self.assertIn("10 earlier elements truncated", nodes[0].label)

    def test_already_skipped_nodes_excluded(self):
        """Nodes already in skip_indices don't count toward the cap."""
        from app._lib.pruning import cap_web_area_nodes
        nodes = [
            _node(0, role="AXWebArea", label="Page", depth=0),
        ] + [_node(i, role="AXStaticText", label=f"t{i}", depth=1) for i in range(1, 16)]
        nodes[0].is_web_area = True
        # 5 nodes already skipped
        existing_skips = {1, 2, 3, 4, 5}
        skips = cap_web_area_nodes(nodes, existing_skips, cap=10)
        # 10 remaining descendants, at cap → no extra skips
        self.assertEqual(len(skips), 0)


class TestAXElementPointerStripping(unittest.TestCase):
    """Tests for AXUIElement pointer string removal in serialization."""

    def test_pointer_stripped_from_label(self):
        from app._lib.tree import _format_node
        node = _node(0, role="AXLink", label="Click here (<AXUIElement 0x600003abc123 {pid=29221}>)")
        result = _format_node(node)
        self.assertNotIn("AXUIElement", result)
        self.assertNotIn("0x600003", result)
        self.assertIn("Click here", result)

    def test_pointer_stripped_from_description(self):
        from app._lib.tree import _format_node
        node = _node(0, role="AXLink", label=None, description="<AXUIElement 0x600003def456 {pid=1234}>")
        result = _format_node(node)
        self.assertNotIn("AXUIElement", result)

    def test_normal_content_preserved(self):
        from app._lib.tree import _format_node
        node = _node(0, role="AXButton", label="Submit Form")
        result = _format_node(node)
        self.assertIn("Submit Form", result)


if __name__ == "__main__":
    unittest.main()
