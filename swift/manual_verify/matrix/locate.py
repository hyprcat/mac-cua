"""locate.py — parse a get_app_state UI tree into Element records and query them.

Implements the `Element` / `parse_tree` / `find` / `find_all` contract from
docs/superpowers/specs/2026-06-25-swift-port-tool-matrix-design.md.

The serialized tree is tab-indented; each element line looks like:

    <index> <role words> <label>[, Placeholder: <p>][ (settable, <type>)]
            [, Value: <v>][, ID: <id>][, Secondary Actions: <a>, <b>]

State/settable markers in parentheses ("(selected)", "(settable, string)",
"(disabled, settable, float)") appear right after the role/label. They can sit
*before* the label too (e.g. "combo box (settable, string) Go to file" and
"scroll bar (settable, float) 0"). Labels themselves may contain commas, so
attributes are split only on known `, <Attr>:` boundaries — never on bare
commas. Long Help/Value text wraps across raw lines with no indent; those
continuation lines are folded back into the element that owns them.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field


# Known multi-word role phrases, longest-first so "pop-up button" wins over
# "button" and "search text field" over "text field". Roles are not a closed
# enum — anything not listed falls back to the first whitespace token.
KNOWN_ROLES = [
    "search text field",
    "secure text field",
    "static text",
    "text field",
    "text area",
    "combo box",
    "pop-up button",
    "menu button",
    "menu bar item",
    "menu bar",
    "menu item",
    "radio button",
    "radio group",
    "check box",
    "checkbox",
    "scroll area",
    "scroll bar",
    "value indicator",
    "HTML content",
    "web area",
    "split group",
    "tab group",
    "table row",
    "table column",
    "outline row",
    "disclosure triangle",
    "color well",
    "level indicator",
    "relevance indicator",
    "busy indicator",
    "progress indicator",
    "incrementor",
    "standard window",
    "dialog window",
    "system dialog",
    "list",
    "grid",
    "group",
    "container",
    "window",
    "button",
    "toolbar",
    "tabs",
    "tab",
    "image",
    "link",
    "heading",
    "text",
    "cell",
    "row",
    "column",
    "table",
    "outline",
    "menu",
    "slider",
    "splitter",
    "field",
    "popover",
    "sheet",
    "drawer",
    "ruler",
    "application",
]
KNOWN_ROLES.sort(key=len, reverse=True)

# Attribute keys that introduce a `, <Key>: <value>` clause. Splitting only on
# these boundaries keeps commas that live inside a label or value intact.
ATTR_KEYS = [
    "Placeholder",
    "Value",
    "ID",
    "Secondary Actions",
    "Help",
    "Description",
    "URL",
]
# `, Key:` boundary. Also matches a leading newline (folded continuation lines)
# or the very start of the text (e.g. a label-less "Description: ..." clause).
_ATTR_BOUNDARY = re.compile(
    r"(?:^|[,\n])\s*(" + "|".join(re.escape(k) for k in ATTR_KEYS) + r"):\s?"
)

# Leading state-marker parenthetical, e.g. "(settable, string)", "(disabled)",
# "(disabled, settable, float)", "(selected)", "(selectable)".
_STATE_PAREN = re.compile(r"^\((?P<body>[^()]*)\)")

# An element line: optional tabs, an integer index, a space, then content.
_ELEMENT_LINE = re.compile(r"^(?P<tabs>\t*)(?P<index>\d+) (?P<rest>.*)$", re.DOTALL)

_SETTABLE_TYPES = {"string", "float", "int", "integer", "bool", "boolean", "double", "number"}


@dataclass
class Element:
    index: int
    role: str
    label: str
    value: str | None
    placeholder: str | None
    settable: bool
    settable_type: str | None
    secondary_actions: list[str] = field(default_factory=list)
    depth: int = 0


def _split_role(rest: str) -> tuple[str, str]:
    """Split the post-index text into (role, remainder-after-role)."""
    for role in KNOWN_ROLES:
        if rest == role:
            return role, ""
        if rest.startswith(role + " "):
            return role, rest[len(role) + 1 :]
        # role immediately followed by a state paren, e.g. "combo box (settable..."
        if rest.startswith(role + " ("):
            return role, rest[len(role) + 1 :]
    # Fallback: first whitespace token is the role.
    first, _, tail = rest.partition(" ")
    return first, tail


def _consume_state_markers(text: str) -> tuple[str, bool, str | None]:
    """Pull any leading "(...)" state markers off `text`.

    Returns (remaining_text, settable, settable_type). Multiple consecutive
    parentheticals are consumed (some lines stack label + state).
    """
    settable = False
    settable_type: str | None = None
    text = text.lstrip()
    while True:
        m = _STATE_PAREN.match(text)
        if not m:
            break
        body = m.group("body")
        tokens = [t.strip() for t in body.split(",") if t.strip()]
        low = [t.lower() for t in tokens]
        if "settable" in low:
            settable = True
            for tok in low:
                if tok in _SETTABLE_TYPES:
                    settable_type = tok
            # A trailing bare type token after "settable" with no keyword match.
            if settable_type is None:
                idx = low.index("settable")
                if idx + 1 < len(low):
                    settable_type = low[idx + 1]
        text = text[m.end() :].lstrip()
    return text, settable, settable_type


def _parse_attributes(rest_after_role: str) -> dict:
    """Split label + trailing attributes from the post-role text.

    `rest_after_role` is everything after the role phrase. It may begin with a
    state paren, then a label, then `, <Attr>: value` clauses (themselves
    possibly containing a state paren before the label when label is empty).
    """
    # State markers may lead (before the label) or trail it; handle the leading
    # case first, then re-check after the label is isolated.
    text, settable, settable_type = _consume_state_markers(rest_after_role)

    # Find the first attribute boundary; everything before it is the label.
    m = _ATTR_BOUNDARY.search(text)
    if m:
        label_part = text[: m.start()]
        attr_blob = text[m.start() :]
    else:
        label_part = text
        attr_blob = ""

    # A state paren can sit between the label text and the first attribute
    # (e.g. "scroll bar (settable, float) 0" -> role consumed "scroll bar",
    # label "0" with a leading state paren). Re-run the consumer on label_part.
    label_part, s2, t2 = _consume_state_markers(label_part)
    settable = settable or s2
    settable_type = settable_type or t2
    label = label_part.strip().rstrip(",").strip()

    attrs = {
        "label": label,
        "value": None,
        "placeholder": None,
        "settable": settable,
        "settable_type": settable_type,
        "secondary_actions": [],
        "description": None,
    }

    # Walk the attribute clauses in order.
    pos = 0
    matches = list(_ATTR_BOUNDARY.finditer(attr_blob))
    for i, mm in enumerate(matches):
        key = mm.group(1)
        start = mm.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(attr_blob)
        raw = attr_blob[start:end].strip()
        if key == "Secondary Actions":
            attrs["secondary_actions"] = [a.strip() for a in raw.split(",") if a.strip()]
        elif key == "Value":
            attrs["value"] = raw
        elif key == "Placeholder":
            attrs["placeholder"] = raw
        elif key == "Description":
            attrs["description"] = raw
        # ID / Help / URL are not part of the Element contract; ignore.
        pos = end

    # If there was no plain label but a Description was present, promote it.
    if not attrs["label"] and attrs["description"]:
        attrs["label"] = attrs["description"]

    return attrs


def parse_tree(state_text: str) -> list[Element]:
    """Parse a get_app_state tree dump into a flat list of Element records."""
    raw_lines = state_text.split("\n")
    elements: list[Element] = []
    started = False  # have we seen the first real element line yet?
    pending: list[str] = []  # raw lines making up the current element

    def flush():
        if not pending:
            return
        joined = "\n".join(pending)
        m = _ELEMENT_LINE.match(joined)
        if not m:
            return
        depth = len(m.group("tabs"))
        index = int(m.group("index"))
        rest = m.group("rest")
        role, after_role = _split_role(rest)
        attrs = _parse_attributes(after_role)
        elements.append(
            Element(
                index=index,
                role=role,
                label=attrs["label"],
                value=attrs["value"],
                placeholder=attrs["placeholder"],
                settable=attrs["settable"],
                settable_type=attrs["settable_type"],
                secondary_actions=attrs["secondary_actions"],
                depth=depth,
            )
        )

    for line in raw_lines:
        if _ELEMENT_LINE.match(line):
            # New element line. Flush whatever we accumulated, then start fresh.
            flush()
            pending = [line]
            started = True
            continue
        # Non-element line.
        if not started:
            # Header / app_state / app_specific_instructions preamble — skip.
            continue
        stripped = line.strip()
        if not stripped:
            # Blank line inside wrapped value text — keep it folded in.
            if pending:
                pending.append(line)
            continue
        # Trailing "The focused UI element is ..." sentinel ends the tree.
        if stripped.startswith("The focused UI element is"):
            flush()
            pending = []
            started = False
            continue
        # Otherwise this is a wrapped continuation of the current element's
        # attribute text (e.g. a multi-line Help/Description/Value). Fold it in.
        if pending:
            pending.append(line)

    flush()
    return elements


def _matches(el: Element, role, label, label_contains, settable, has_action) -> bool:
    if role is not None and el.role != role:
        return False
    if label is not None and el.label != label:
        return False
    if label_contains is not None and label_contains.lower() not in el.label.lower():
        return False
    if settable is not None and el.settable != settable:
        return False
    if has_action is not None and has_action not in el.secondary_actions:
        return False
    return True


def find_all(
    elements,
    *,
    role=None,
    label=None,
    label_contains=None,
    settable=None,
    has_action=None,
) -> list[Element]:
    return [
        el
        for el in elements
        if _matches(el, role, label, label_contains, settable, has_action)
    ]


def find(
    elements,
    *,
    role=None,
    label=None,
    label_contains=None,
    settable=None,
    has_action=None,
) -> Element | None:
    for el in elements:
        if _matches(el, role, label, label_contains, settable, has_action):
            return el
    return None


if __name__ == "__main__":
    import os

    here = os.path.dirname(os.path.abspath(__file__))
    sample = os.path.join(here, "samples", "safari_tree.txt")
    with open(sample) as fh:
        text = fh.read()

    els = parse_tree(text)

    # 1. Bulk sanity.
    assert len(els) > 100, f"expected >100 elements, got {len(els)}"

    # 2. The "Go to file" combo box is settable/string.
    combo = find(els, role="combo box", label="Go to file")
    assert combo is not None, "combo box 'Go to file' not found"
    assert combo.settable is True, "combo box should be settable"
    assert combo.settable_type == "string", f"settable_type={combo.settable_type!r}"
    assert combo.placeholder == "Go to file", f"placeholder={combo.placeholder!r}"

    # 3. At least one element exposes a 'Scroll To Visible' secondary action.
    scrollers = find_all(els, has_action="Scroll To Visible")
    assert scrollers, "no element with 'Scroll To Visible' secondary action"

    # 4. Depths non-negative, root window at depth 0.
    assert all(e.depth >= 0 for e in els), "negative depth found"
    root = els[0]
    assert root.depth == 0, f"root depth {root.depth}"
    assert root.role == "standard window", f"root role {root.role!r}"
    assert root.index == 0, f"root index {root.index}"

    # --- Synthetic TextEdit-style edge cases (not present in the Safari tree) ---
    textedit = (
        "<app_state>\n"
        "App=com.apple.TextEdit (pid 1)\n"
        "0 standard window Untitled, ID: w1\n"
        "\t1 search text field (settable) Search, Placeholder: Search\n"
        "\t2 scroll bar (settable, float) 0\n"
        "\t3 splitter (disabled, settable, float) 200\n"
        "\t4 row (selected) Description: move, Value: TextEdit\n"
        "\t5 text area (settable, string) Body, Value: hello, world\n"
        "The focused UI element is 5 text area.\n"
    )
    te = parse_tree(textedit)
    by_index = {e.index: e for e in te}

    sf = by_index[1]
    assert sf.role == "search text field" and sf.settable and sf.settable_type is None, sf
    sb = by_index[2]
    assert sb.role == "scroll bar" and sb.settable and sb.settable_type == "float" and sb.label == "0", sb
    sp = by_index[3]
    assert sp.role == "splitter" and sp.settable and sp.settable_type == "float" and sp.label == "200", sp
    rw = by_index[4]
    # Empty label, Description promoted; Value preserved.
    assert rw.role == "row" and rw.label == "move" and rw.value == "TextEdit", rw
    ta = by_index[5]
    # Value containing a comma must survive intact.
    assert ta.role == "text area" and ta.value == "hello, world" and ta.settable_type == "string", ta

    print(
        f"PASS  safari_elements={len(els)}  scroll_to_visible={len(scrollers)}  "
        f"combo(settable={combo.settable},type={combo.settable_type})  "
        f"textedit_edge_cases={len(te)} ok"
    )
