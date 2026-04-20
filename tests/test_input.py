from __future__ import annotations

import unittest
from unittest.mock import call, patch

from app._lib import input as cg_input


class InputTests(unittest.TestCase):
    def test_coerce_text_key_handles_plain_and_named_symbols(self) -> None:
        self.assertEqual(cg_input._coerce_text_key("o"), "o")
        self.assertEqual(cg_input._coerce_text_key("/"), "/")
        self.assertEqual(cg_input._coerce_text_key("slash"), "/")
        self.assertEqual(cg_input._coerce_text_key("minus"), "-")
        self.assertIsNone(cg_input._coerce_text_key("cmd+o"))
        self.assertIsNone(cg_input._coerce_text_key("Return"))

    def test_press_key_routes_plain_character_to_keycode_path(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", return_value=(31, 0)) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
        ):
            cg_input.press_key(321, "o")

        parse_mock.assert_called_once_with("o")
        post_key_mock.assert_called_once_with(321, 31, 0)

    def test_press_key_routes_named_symbol_to_keycode_path(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", return_value=(44, 0)) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
        ):
            cg_input.press_key(321, "slash")

        parse_mock.assert_called_once_with("/")
        post_key_mock.assert_called_once_with(321, 44, 0)

    def test_press_key_uses_raw_keycodes_for_shortcuts(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", return_value=(31, 99)) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
        ):
            cg_input.press_key(123, "cmd+o")

        parse_mock.assert_called_once_with("cmd+o")
        post_key_mock.assert_called_once_with(123, 31, 99)

    def test_post_keycode_with_modifiers_sends_modifier_transitions(self) -> None:
        modifier_down = object()
        key_down = object()
        key_up = object()
        modifier_up = object()

        with (
            patch("app._lib.input.modifier_keycodes", return_value=[(55, 16)]),
            patch(
                "app._lib.input.CGEventCreateKeyboardEvent",
                side_effect=[modifier_down, key_down, key_up, modifier_up],
            ) as create_mock,
            patch("app._lib.input.CGEventSetFlags") as flags_mock,
            patch("app._lib.input.CGEventPostToPid") as post_mock,
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_keycode_with_modifiers(456, 31, 16)

        create_mock.assert_has_calls([
            call(cg_input._source, 55, True),
            call(cg_input._source, 31, True),
            call(cg_input._source, 31, False),
            call(cg_input._source, 55, False),
        ])
        flags_mock.assert_has_calls([
            call(modifier_down, 16),
            call(key_down, 16),
            call(key_up, 16),
            call(modifier_up, 0),
        ])
        post_mock.assert_has_calls([
            call(456, modifier_down),
            call(456, key_down),
            call(456, key_up),
            call(456, modifier_up),
        ])

    def test_type_text_prefers_keycode_path_for_ascii(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", return_value=(0, 0)) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
            patch("app._lib.input._post_unicode_char") as post_unicode_mock,
            patch("app._lib.input.time.sleep"),
        ):
            cg_input.type_text(456, "A")

        parse_mock.assert_called_once_with("A")
        post_key_mock.assert_called_once_with(456, 0, 0)
        post_unicode_mock.assert_not_called()

    def test_type_text_falls_back_to_unicode_for_unmapped_characters(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", side_effect=ValueError("nope")) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
            patch("app._lib.input._post_unicode_char") as post_unicode_mock,
            patch("app._lib.input.time.sleep"),
        ):
            cg_input.type_text(456, "🙂")

        parse_mock.assert_called_once_with("🙂")
        post_key_mock.assert_not_called()
        post_unicode_mock.assert_called_once_with(456, "🙂")


if __name__ == "__main__":
    unittest.main()
