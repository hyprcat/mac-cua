from __future__ import annotations

import unittest
from unittest.mock import call, patch, sentinel

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

    def test_post_keycode_with_modifiers_sends_chorded_key_events(self) -> None:
        key_down = object()
        key_up = object()

        with (
            patch(
                "app._lib.input.CGEventCreateKeyboardEvent",
                side_effect=[key_down, key_up],
            ) as create_mock,
            patch("app._lib.input.CGEventSetFlags") as flags_mock,
            patch("app._lib.input.CGEventPostToPid") as post_mock,
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_keycode_with_modifiers(456, 31, 16)

        create_mock.assert_has_calls([
            call(cg_input._source, 31, True),
            call(cg_input._source, 31, False),
        ])
        flags_mock.assert_has_calls([
            call(key_down, 16),
            call(key_up, 16),
        ])
        post_mock.assert_has_calls([
            call(456, key_down),
            call(456, key_up),
        ])

    def test_window_to_screen_coords_uses_delivered_screenshot_size(self) -> None:
        with patch("app._lib.input.screenshot.get_window_bounds", return_value=(10.0, 20.0, 200.0, 100.0)):
            coords = cg_input.window_to_screen_coords(99, 95.0, 50.0, screenshot_size=(100, 50))

        self.assertEqual(coords, (200.0, 118.0))

    def test_post_click_sets_pressure_and_window_hints(self) -> None:
        move = object()
        down = object()
        up = object()

        with (
            patch("app._lib.input._MOUSE_EVENT_NUMBER", 0),
            patch(
                "app._lib.input.CGEventCreateMouseEvent",
                side_effect=[move, down, up],
            ),
            patch("app._lib.input.CGEventSetIntegerValueField") as set_int_mock,
            patch("app._lib.input.CGEventSetDoubleValueField") as set_double_mock,
            patch("app._lib.input.CGEventPostToPid"),
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_click(456, sentinel.point, "left", 1, window_id=77)

        set_double_mock.assert_has_calls([
            call(move, cg_input.kCGMouseEventPressure, 0.0),
            call(down, cg_input.kCGMouseEventPressure, cg_input._MOUSE_PRESSURE),
            call(up, cg_input.kCGMouseEventPressure, 0.0),
        ])
        set_int_mock.assert_has_calls([
            call(move, cg_input.kCGMouseEventNumber, 1),
            call(move, cg_input.kCGMouseEventWindowUnderMousePointer, 77),
            call(move, cg_input.kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, 77),
            call(down, cg_input.kCGMouseEventClickState, 1),
            call(down, cg_input.kCGMouseEventNumber, 2),
            call(down, cg_input.kCGMouseEventWindowUnderMousePointer, 77),
            call(down, cg_input.kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, 77),
            call(up, cg_input.kCGMouseEventClickState, 1),
            call(up, cg_input.kCGMouseEventNumber, 3),
            call(up, cg_input.kCGMouseEventWindowUnderMousePointer, 77),
            call(up, cg_input.kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, 77),
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
