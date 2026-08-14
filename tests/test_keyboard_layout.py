from __future__ import annotations

import sys
import unittest

from app._lib import keys
from app._lib.keys import install_layout_map, parse_key_combo

_MASK_SHIFT = 1 << 17
_MASK_ALTERNATE = 1 << 19
_MASK_COMMAND = 1 << 20


class LayoutOverrideTests(unittest.TestCase):
    """The parser must prefer the active layout over the static US table."""

    def tearDown(self) -> None:
        install_layout_map({})

    def test_without_layout_the_static_us_table_is_used(self) -> None:
        install_layout_map({})
        # US ANSI: "a" is keycode 0.
        self.assertEqual(parse_key_combo("a"), (0, 0))

    def test_layout_overrides_the_static_keycode(self) -> None:
        # French AZERTY: "a" sits where US has "q" (keycode 12).
        install_layout_map({"a": (12, 0), "q": (0, 0)})
        self.assertEqual(parse_key_combo("a"), (12, 0))
        self.assertEqual(parse_key_combo("q"), (0, 0))

    def test_modifiers_combine_with_layout_keycode(self) -> None:
        """super+a must be Cmd on the real "a" key, not Cmd+Q on AZERTY."""
        install_layout_map({"a": (12, 0)})
        self.assertEqual(parse_key_combo("super+a"), (12, _MASK_COMMAND))

    def test_layout_supplied_flags_are_merged(self) -> None:
        # A character only reachable with shift carries its own flag.
        install_layout_map({"9": (25, _MASK_SHIFT)})
        self.assertEqual(parse_key_combo("9"), (25, _MASK_SHIFT))
        self.assertEqual(parse_key_combo("ctrl+9"), (25, _MASK_SHIFT | (1 << 18)))

    def test_uppercase_is_not_double_shifted(self) -> None:
        """The layout entry for "C" already includes shift; don't add it twice."""
        install_layout_map({"C": (8, _MASK_SHIFT), "c": (8, 0)})
        self.assertEqual(parse_key_combo("C"), (8, _MASK_SHIFT))

    def test_named_keys_are_untouched_by_the_layout(self) -> None:
        install_layout_map({"a": (12, 0)})
        self.assertEqual(parse_key_combo("Return"), (36, 0))
        self.assertEqual(parse_key_combo("space"), (49, 0))

    def test_unknown_character_still_raises(self) -> None:
        install_layout_map({"a": (12, 0)})
        with self.assertRaises(ValueError):
            parse_key_combo("nosuchkey")

    def test_masks_stay_in_sync_with_keys_module(self) -> None:
        from app._lib import keyboard_layout

        self.assertEqual(keyboard_layout._MASK_SHIFT, keys._MASK_SHIFT)
        self.assertEqual(keyboard_layout._MASK_ALTERNATE, keys._MASK_ALTERNATE)


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Text Input Services")
class ActiveLayoutTests(unittest.TestCase):
    """Probe the real layout. Assertions hold for any layout, not just AZERTY."""

    def test_layout_map_covers_the_basic_alphabet(self) -> None:
        from app._lib.keyboard_layout import build_layout_map

        mapping = build_layout_map()
        if not mapping:
            self.skipTest("keyboard layout unavailable in this environment")
        for char in "abcdefghijklmnopqrstuvwxyz0123456789":
            self.assertIn(char, mapping, f"{char!r} missing from layout map")

    def test_keycodes_are_in_range_and_flags_are_valid(self) -> None:
        from app._lib.keyboard_layout import build_layout_map

        mapping = build_layout_map()
        if not mapping:
            self.skipTest("keyboard layout unavailable in this environment")
        allowed = {0, _MASK_SHIFT, _MASK_ALTERNATE, _MASK_SHIFT | _MASK_ALTERNATE}
        for char, (keycode, flags) in mapping.items():
            self.assertTrue(0 <= keycode < 128, f"{char!r}: keycode {keycode}")
            self.assertIn(flags, allowed, f"{char!r}: flags {flags}")

    def test_refresh_installs_the_map_into_the_parser(self) -> None:
        from app._lib import keyboard_layout

        keyboard_layout.refresh()
        try:
            if not keyboard_layout.active_layout_map():
                self.skipTest("keyboard layout unavailable in this environment")
            # Whatever the layout, "a" must resolve to the key that types "a".
            keycode, _ = parse_key_combo("a")
            self.assertEqual(keycode, keyboard_layout.active_layout_map()["a"][0])
        finally:
            install_layout_map({})


if __name__ == "__main__":
    unittest.main()
