"""Parse xdotool-style key combo strings into (CGKeyCode, modifier_mask) tuples.

Pure module -- no macOS imports. Testable on any platform.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Modifier flags (CGEventFlags values)
# ---------------------------------------------------------------------------

_MASK_SHIFT = 1 << 17
_MASK_CONTROL = 1 << 18
_MASK_ALTERNATE = 1 << 19
_MASK_COMMAND = 1 << 20

_MODIFIERS: dict[str, int] = {
    "super": _MASK_COMMAND,
    "cmd": _MASK_COMMAND,
    "command": _MASK_COMMAND,
    "alt": _MASK_ALTERNATE,
    "opt": _MASK_ALTERNATE,
    "option": _MASK_ALTERNATE,
    "ctrl": _MASK_CONTROL,
    "control": _MASK_CONTROL,
    "shift": _MASK_SHIFT,
}

_MODIFIER_KEYCODES = [
    (_MASK_COMMAND, 55),
    (_MASK_SHIFT, 56),
    (_MASK_ALTERNATE, 58),
    (_MASK_CONTROL, 59),
]

# ---------------------------------------------------------------------------
# Key map: lowercase name -> (keycode, extra_modifier_flags)
# ---------------------------------------------------------------------------

_KEY_MAP: dict[str, tuple[int, int]] = {}


def _reg(names: str | list[str], keycode: int, flags: int = 0) -> None:
    """Register one or more names for a keycode."""
    if isinstance(names, str):
        names = [names]
    for n in names:
        _KEY_MAP[n.lower()] = (keycode, flags)


# Letters a-z (keycodes in alphabetical order)
_LETTER_CODES = [
    0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
    45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
]
for _i, _kc in enumerate(_LETTER_CODES):
    _reg(chr(ord("a") + _i), _kc)

# Digits 0-9
_DIGIT_CODES = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
for _i, _kc in enumerate(_DIGIT_CODES):
    _reg(str(_i), _kc)

_SHIFTED_DIGITS = {
    ")": _DIGIT_CODES[0],
    "!": _DIGIT_CODES[1],
    "@": _DIGIT_CODES[2],
    "#": _DIGIT_CODES[3],
    "$": _DIGIT_CODES[4],
    "%": _DIGIT_CODES[5],
    "^": _DIGIT_CODES[6],
    "&": _DIGIT_CODES[7],
    "*": _DIGIT_CODES[8],
    "(": _DIGIT_CODES[9],
}
for _char, _kc in _SHIFTED_DIGITS.items():
    _reg(_char, _kc, _MASK_SHIFT)

# F-keys
_F_CODES = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
for _i, _kc in enumerate(_F_CODES, start=1):
    _reg(f"f{_i}", _kc)

_F_CODES_EXT = [105, 107, 113, 106, 64, 79, 80, 90]
for _i, _kc in enumerate(_F_CODES_EXT, start=13):
    _reg(f"f{_i}", _kc)

# Navigation / editing
_reg(["return", "enter"], 36)
_reg("tab", 48)
_reg("space", 49)
_reg(["backspace", "delete", "back_space"], 51)
_reg(["escape", "esc"], 53)
_reg("left", 123)
_reg("right", 124)
_reg("down", 125)
_reg("up", 126)
_reg("home", 115)
_reg("end", 119)
_reg(["page_up", "pageup", "prior"], 116)
_reg(["page_down", "pagedown", "next"], 121)
_reg(["forwarddelete", "forward_delete"], 117)

# Punctuation / symbols
_reg("minus", 27)
_reg("-", 27)
_reg("_", 27, _MASK_SHIFT)
_reg("equal", 24)
_reg("=", 24)
_reg("+", 24, _MASK_SHIFT)
_reg(["bracketleft", "bracket_left"], 33)
_reg("[", 33)
_reg("{", 33, _MASK_SHIFT)
_reg(["bracketright", "bracket_right"], 30)
_reg("]", 30)
_reg("}", 30, _MASK_SHIFT)
_reg("semicolon", 41)
_reg(";", 41)
_reg(":", 41, _MASK_SHIFT)
_reg(["apostrophe", "quote"], 39)
_reg("'", 39)
_reg('"', 39, _MASK_SHIFT)
_reg("comma", 43)
_reg(",", 43)
_reg("<", 43, _MASK_SHIFT)
_reg("period", 47)
_reg(".", 47)
_reg(">", 47, _MASK_SHIFT)
_reg("slash", 44)
_reg("/", 44)
_reg("?", 44, _MASK_SHIFT)
_reg("backslash", 42)
_reg("\\", 42)
_reg("|", 42, _MASK_SHIFT)
_reg(["grave", "asciitilde"], 50)
_reg("`", 50)
_reg("~", 50, _MASK_SHIFT)

# Media
_reg(["volumeup", "volume_up"], 72)
_reg(["volumedown", "volume_down"], 73)
_reg("mute", 74)

# Keypad
_KP_DIGIT_CODES = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
for _i, _kc in enumerate(_KP_DIGIT_CODES):
    _reg(f"kp_{_i}", _kc)

_reg(["kp_decimal", "kp_period"], 65)
_reg("kp_multiply", 67)
_reg("kp_add", 69)
_reg("kp_subtract", 78)
_reg("kp_divide", 75)
_reg("kp_enter", 76)

# Clean up module namespace
del _char, _i, _kc, _LETTER_CODES, _DIGIT_CODES, _SHIFTED_DIGITS, _F_CODES, _F_CODES_EXT, _KP_DIGIT_CODES


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------


def parse_key_combo(combo: str) -> tuple[int, int]:
    """Parse an xdotool-style key combo into ``(keycode, modifier_mask)``.

    Examples::

        parse_key_combo("super+shift+c")  # -> (8, mask_command | mask_shift)
        parse_key_combo("Return")          # -> (36, 0)
        parse_key_combo("C")               # -> (8, mask_shift)  (uppercase)

    Raises ``ValueError`` for unknown key names.
    """
    parts = combo.split("+")
    mask = 0
    key_name: str | None = None

    for part in parts:
        part_stripped = part.strip()
        if not part_stripped:
            continue
        lower = part_stripped.lower()
        if lower in _MODIFIERS:
            mask |= _MODIFIERS[lower]
        else:
            if key_name is not None:
                raise ValueError(
                    f"multiple_non_modifier_keys: "
                    f"{key_name!r} and {part_stripped!r} in combo {combo!r}"
                )
            key_name = part_stripped

    if key_name is None:
        raise ValueError(
            f"no_non_modifier_keys: combo {combo!r} has only modifiers"
        )

    lower_key = key_name.lower()

    # Look up in the key map
    if lower_key in _KEY_MAP:
        keycode, extra_flags = _KEY_MAP[lower_key]
        mask |= extra_flags

        # Auto-shift for uppercase single letters: "C" -> shift+c
        if len(key_name) == 1 and key_name.isupper() and key_name.isalpha():
            mask |= _MASK_SHIFT

        return keycode, mask

    raise ValueError(
        f"unknown_key: {key_name!r} in combo {combo!r}"
    )


def modifier_keycodes(mask: int) -> list[tuple[int, int]]:
    return [(keycode, flag) for flag, keycode in _MODIFIER_KEYCODES if mask & flag]
