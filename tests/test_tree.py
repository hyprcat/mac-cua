from app._lib.tree import serialize
from app.response import Node, Point, Size


def test_serialize_uses_bracketed_indices() -> None:
    node = Node(
        index=12,
        role="row",
        label="Replay 2024",
        states=[],
        description=None,
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=0,
    )

    text = serialize([node], enable_pruning=False)

    assert text.startswith("[12] row Replay 2024")


def test_serialize_codex_style_uses_plain_indices() -> None:
    node = Node(
        index=12,
        role="row",
        label="Replay 2024",
        states=["selectable"],
        description=None,
        value="Replay 2024",
        ax_id=None,
        secondary_actions=[],
        depth=0,
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text.startswith("12 row (selectable) Replay 2024")


def test_serialize_includes_frame_hints_for_grounding() -> None:
    node = Node(
        index=7,
        role="text",
        label="Replay 2023",
        states=[],
        description=None,
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=1,
        position=Point(x=120, y=340),
        size=Size(w=84, h=18),
    )

    text = serialize([node], enable_pruning=False)

    assert "Frame: (120,340 84x18)" in text


def test_serialize_codex_style_separates_description_and_value() -> None:
    node = Node(
        index=7,
        role="row",
        label=None,
        states=["selectable"],
        description="Grid view",
        value="New",
        ax_id=None,
        secondary_actions=[],
        depth=1,
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert "7 row (selectable) Description: Grid view, Value: New" in text


def test_serialize_codex_style_adds_comma_after_label_before_extras() -> None:
    node = Node(
        index=0,
        role="standard window",
        label="Music",
        states=[],
        description=None,
        value=None,
        ax_id=None,
        secondary_actions=["AXRaise"],
        depth=0,
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text.startswith("0 standard window Music, Secondary Actions: Raise")


def test_serialize_codex_style_menu_bar_item_uses_label_only() -> None:
    node = Node(
        index=121,
        role="menu bar item",
        label="Music",
        states=[],
        description=None,
        value=None,
        ax_id="_NS:2187",
        secondary_actions=["AXPick"],
        depth=1,
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text == "\t121 Music"


def test_serialize_codex_style_focused_summary_is_compact() -> None:
    node = Node(
        index=0,
        role="standard window",
        label="Music",
        states=[],
        description=None,
        value=None,
        ax_id=None,
        secondary_actions=["AXRaise"],
        depth=0,
    )

    text = serialize([node], focused_index=0, enable_pruning=False, codex_style=True)

    assert text.endswith("The focused UI element is 0 standard window.")


def test_serialize_codex_style_renames_web_area_to_html_content() -> None:
    node = Node(
        index=3,
        role="web area",
        label="workspace",
        states=[],
        description=None,
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=0,
        web_area_url="https://example.com",
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text.startswith("3 HTML content workspace, URL: https://example.com")


def test_serialize_codex_style_skips_inline_web_content_when_children_exist() -> None:
    nodes = [
        Node(
            index=0,
            role="web area",
            label="workspace",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=0,
            web_content="flattened content that should stay hidden",
        ),
        Node(
            index=1,
            role="button",
            label="Open",
            states=[],
            description=None,
            value=None,
            ax_id=None,
            secondary_actions=[],
            depth=1,
        ),
    ]

    text = serialize(nodes, enable_pruning=False, codex_style=True)

    assert "flattened content that should stay hidden" not in text
    assert "\t1 button Open" in text


def test_serialize_codex_style_uses_toggle_button_for_checkbox_subrole() -> None:
    node = Node(
        index=17,
        role="checkbox",
        label=None,
        states=[],
        description="Toggle Panel (⌘J)",
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=0,
        subrole="AXToggleButton",
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text.startswith("17 toggle button Description: Toggle Panel (⌘J)")


def test_serialize_codex_style_uses_tab_for_radio_button_tab_subrole() -> None:
    node = Node(
        index=24,
        role="radio button",
        label="Explorer (⇧⌘E)",
        states=["selected"],
        description=None,
        value="1",
        ax_id=None,
        secondary_actions=[],
        depth=0,
        subrole="AXTabButton",
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text.startswith("24 tab (selected) Explorer (⇧⌘E), Value: 1")


def test_serialize_codex_style_uses_pop_up_button_spelling() -> None:
    node = Node(
        index=13,
        role="popup button",
        label=None,
        states=[],
        description="More Actions",
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=0,
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text.startswith("13 pop-up button Description: More Actions")


def test_serialize_codex_style_promotes_row_description_to_label_when_value_missing() -> None:
    node = Node(
        index=63,
        role="row",
        label=None,
        states=[],
        description=".claude",
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=0,
    )

    text = serialize([node], enable_pruning=False, codex_style=True)

    assert text == "63 row .claude"
