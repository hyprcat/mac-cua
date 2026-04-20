from unittest.mock import patch

from app._lib.accessibility import _get_actions, walk_tree
from app._lib.pruning import prune


def test_walk_tree_uses_depth_first_preorder() -> None:
    root = object()
    sidebar = object()
    row_one = object()
    row_one_text = object()
    row_two = object()
    row_two_text = object()

    attrs = {
        root: {
            "AXRole": "AXWindow",
            "AXChildren": [sidebar],
        },
        sidebar: {
            "AXRole": "AXOutline",
            "AXDescription": "Sidebar",
            "AXChildren": [row_one, row_two],
        },
        row_one: {
            "AXRole": "AXRow",
            "AXChildren": [row_one_text],
        },
        row_one_text: {
            "AXRole": "AXStaticText",
            "AXValue": "Replay 2023",
            "AXChildren": [],
        },
        row_two: {
            "AXRole": "AXRow",
            "AXChildren": [row_two_text],
        },
        row_two_text: {
            "AXRole": "AXStaticText",
            "AXValue": "Replay 2024",
            "AXChildren": [],
        },
    }

    with (
        patch("app._lib.accessibility._read_attrs", side_effect=lambda element: attrs[element]),
        patch("app._lib.accessibility._build_states", return_value=[]),
        patch("app._lib.accessibility._get_actions", return_value=[]),
        patch("app._lib.accessibility._get_element_pid", return_value=None),
    ):
        nodes = walk_tree(root)

    assert [node.ax_role for node in nodes] == [
        "AXWindow",
        "AXOutline",
        "AXRow",
        "AXStaticText",
        "AXRow",
        "AXStaticText",
    ]
    assert [node.depth for node in nodes] == [0, 1, 2, 3, 2, 3]


def test_walk_tree_order_allows_row_labels_to_merge_during_pruning() -> None:
    root = object()
    sidebar = object()
    row_one = object()
    row_one_text = object()
    row_two = object()
    row_two_text = object()

    attrs = {
        root: {
            "AXRole": "AXWindow",
            "AXChildren": [sidebar],
        },
        sidebar: {
            "AXRole": "AXOutline",
            "AXDescription": "Sidebar",
            "AXChildren": [row_one, row_two],
        },
        row_one: {
            "AXRole": "AXRow",
            "AXChildren": [row_one_text],
        },
        row_one_text: {
            "AXRole": "AXStaticText",
            "AXValue": "Replay 2023",
            "AXChildren": [],
        },
        row_two: {
            "AXRole": "AXRow",
            "AXChildren": [row_two_text],
        },
        row_two_text: {
            "AXRole": "AXStaticText",
            "AXValue": "Replay 2024",
            "AXChildren": [],
        },
    }

    with (
        patch("app._lib.accessibility._read_attrs", side_effect=lambda element: attrs[element]),
        patch("app._lib.accessibility._build_states", return_value=[]),
        patch("app._lib.accessibility._get_actions", return_value=[]),
        patch("app._lib.accessibility._get_element_pid", return_value=None),
    ):
        nodes = walk_tree(root)

    pruned, _, _ = prune(nodes)
    row_labels = [node.label for node in pruned if node.ax_role == "AXRow"]

    assert "Replay 2023" in row_labels
    assert "Replay 2024" in row_labels


def test_walk_tree_normalizes_outline_rows_and_windows() -> None:
    root = object()
    row = object()

    attrs = {
        root: {
            "AXRole": "AXWindow",
            "AXSubrole": "AXDialog",
            "AXTitle": "Music",
            "AXChildren": [row],
        },
        row: {
            "AXRole": "AXRow",
            "AXSubrole": "AXOutlineRow",
            "AXChildren": [],
        },
    }

    with (
        patch("app._lib.accessibility._read_attrs", side_effect=lambda element: attrs[element]),
        patch("app._lib.accessibility._build_states", return_value=[]),
        patch("app._lib.accessibility._get_actions", return_value=[]),
        patch("app._lib.accessibility._get_element_pid", return_value=None),
    ):
        nodes = walk_tree(root)

    assert nodes[0].role == "standard window"
    assert nodes[1].role == "row"


def test_get_actions_filters_noisy_row_actions() -> None:
    element = object()

    with patch(
        "app._lib.accessibility.AXUIElementCopyActionNames",
        return_value=(0, ["AXShowDefaultUI", "AXShowAlternateUI", "AXCollapse"]),
    ):
        actions = _get_actions(element, "AXRow")

    assert actions == ["AXCollapse"]


def test_get_actions_only_keeps_vertical_scroll_for_scroll_areas() -> None:
    element = object()

    with patch(
        "app._lib.accessibility.AXUIElementCopyActionNames",
        return_value=(
            0,
            [
                "AXScrollLeftByPage",
                "AXScrollRightByPage",
                "AXScrollUpByPage",
                "AXScrollDownByPage",
            ],
        ),
    ):
        actions = _get_actions(element, "AXScrollArea")

    assert actions == ["AXScrollUpByPage", "AXScrollDownByPage"]


def test_get_actions_normalizes_custom_toolbar_actions() -> None:
    element = object()

    with patch(
        "app._lib.accessibility.AXUIElementCopyActionNames",
        return_value=(
            0,
            [
                "Name:Move previous\nTarget:0x0\nSelector:(null)",
                "Name:Move next\nTarget:0x0\nSelector:(null)",
                "Name:Remove from toolbar\nTarget:0x0\nSelector:(null)",
                "Some Unknown Action",
            ],
        ),
    ):
        actions = _get_actions(element, "AXButton")

    assert actions == ["AXMovePrevious", "AXMoveNext", "AXRemoveFromToolbar"]


def test_walk_tree_uses_collection_and_section_subrole_names_and_state_order() -> None:
    root = object()
    collection = object()
    section = object()
    scrollbar = object()

    attrs = {
        root: {"AXRole": "AXWindow", "AXChildren": [collection, scrollbar]},
        collection: {
            "AXRole": "AXList",
            "AXSubrole": "AXCollectionList",
            "AXDescription": "Home",
            "AXChildren": [section],
            "AXFocused": True,
        },
        section: {
            "AXRole": "AXList",
            "AXSubrole": "AXSectionList",
            "AXDescription": "Top Picks for You",
            "AXChildren": [],
            "AXEnabled": False,
        },
        scrollbar: {
            "AXRole": "AXScrollBar",
            "AXValue": 0.0,
            "AXChildren": [],
        },
    }

    def fake_settable(element, attr, _unused):
        return (0, element is scrollbar)

    with (
        patch("app._lib.accessibility._read_attrs", side_effect=lambda element: attrs[element]),
        patch("app._lib.accessibility._get_actions", return_value=[]),
        patch("app._lib.accessibility._get_element_pid", return_value=None),
        patch("app._lib.accessibility.AXUIElementIsAttributeSettable", side_effect=fake_settable),
    ):
        nodes = walk_tree(root)

    assert nodes[1].role == "collection"
    assert nodes[1].label == "Home"
    assert nodes[2].role == "section"
    assert nodes[2].label == "Top Picks for You"
    assert nodes[3].states == ["settable", "float"]
    assert nodes[3].value == "0"
