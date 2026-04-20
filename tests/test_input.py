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
        post_key_mock.assert_called_once_with(321, 31, 0, source=None)

    def test_press_key_routes_named_symbol_to_keycode_path(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", return_value=(44, 0)) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
        ):
            cg_input.press_key(321, "slash")

        parse_mock.assert_called_once_with("/")
        post_key_mock.assert_called_once_with(321, 44, 0, source=None)

    def test_press_key_uses_raw_keycodes_for_shortcuts(self) -> None:
        with (
            patch("app._lib.input.parse_key_combo", return_value=(31, 99)) as parse_mock,
            patch("app._lib.input._post_keycode_with_modifiers") as post_key_mock,
        ):
            cg_input.press_key(123, "cmd+o")

        parse_mock.assert_called_once_with("cmd+o")
        post_key_mock.assert_called_once_with(123, 31, 99, source=None)

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
        """Click emits down+up only (no mouse-move pre-positioning)."""
        down = object()
        up = object()

        with (
            patch.object(cg_input, "_mouse_counter", cg_input._MouseEventCounter()),
            patch(
                "app._lib.input.CGEventCreateMouseEvent",
                side_effect=[down, up],
            ),
            patch("app._lib.input.CGEventSetIntegerValueField") as set_int_mock,
            patch("app._lib.input.CGEventSetDoubleValueField") as set_double_mock,
            patch("app._lib.input.CGEventPostToPid"),
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_click(456, sentinel.point, "left", 1, window_id=77)

        set_double_mock.assert_has_calls([
            call(down, cg_input.kCGMouseEventPressure, cg_input._MOUSE_PRESSURE),
            call(up, cg_input.kCGMouseEventPressure, 0.0),
        ])
        set_int_mock.assert_has_calls([
            call(down, cg_input.kCGMouseEventClickState, 1),
            call(down, cg_input.kCGMouseEventNumber, 1),
            call(down, cg_input.kCGMouseEventWindowUnderMousePointer, 77),
            call(down, cg_input.kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, 77),
            call(up, cg_input.kCGMouseEventClickState, 1),
            call(up, cg_input.kCGMouseEventNumber, 2),
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
        post_key_mock.assert_called_once_with(456, 0, 0, source=None)
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
        post_unicode_mock.assert_called_once_with(456, "🙂", source=None)


class CompoundModifierTests(unittest.TestCase):
    """Verify _post_keycode_with_modifiers uses compound events (NOT discrete flagsChanged).

    Discrete flagsChanged via CGEventPostToPid leaks to global modifier state
    and corrupts the user's keyboard. Compound events embed modifiers as flags
    on keyDown/keyUp, which is safe.
    """

    def test_shift_cmd_s_produces_two_compound_events(self) -> None:
        """shift+cmd+s: keyDown(s, flags=shift|cmd), keyUp(s, flags=shift|cmd)."""
        events_posted = []

        def track_event(pid, event):
            events_posted.append(event)

        MASK_SHIFT = 1 << 17
        MASK_COMMAND = 1 << 20

        with (
            patch("app._lib.input.CGEventCreateKeyboardEvent", side_effect=lambda src, kc, down: (kc, down)),
            patch("app._lib.input.CGEventSetFlags"),
            patch("app._lib.input.CGEventPostToPid", side_effect=track_event),
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_keycode_with_modifiers(123, 1, MASK_SHIFT | MASK_COMMAND)

        # Only 2 events — modifiers embedded as flags, no separate flagsChanged
        self.assertEqual(len(events_posted), 2)
        self.assertEqual(events_posted[0], (1, True))   # keyDown
        self.assertEqual(events_posted[1], (1, False))   # keyUp

    def test_plain_key_no_modifiers_produces_two_events(self) -> None:
        events_posted = []

        def track_event(pid, event):
            events_posted.append(event)

        with (
            patch("app._lib.input.CGEventCreateKeyboardEvent", side_effect=lambda src, kc, down: (kc, down)),
            patch("app._lib.input.CGEventSetFlags"),
            patch("app._lib.input.CGEventPostToPid", side_effect=track_event),
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_keycode_with_modifiers(123, 36, 0)

        self.assertEqual(len(events_posted), 2)
        self.assertEqual(events_posted[0], (36, True))
        self.assertEqual(events_posted[1], (36, False))

    def test_cmd_c_produces_two_compound_events(self) -> None:
        events_posted = []

        def track_event(pid, event):
            events_posted.append(event)

        MASK_COMMAND = 1 << 20

        with (
            patch("app._lib.input.CGEventCreateKeyboardEvent", side_effect=lambda src, kc, down: (kc, down)),
            patch("app._lib.input.CGEventSetFlags"),
            patch("app._lib.input.CGEventPostToPid", side_effect=track_event),
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_keycode_with_modifiers(123, 8, MASK_COMMAND)

        # 2 compound events — NOT 4 discrete events
        self.assertEqual(len(events_posted), 2)
        self.assertEqual(events_posted[0], (8, True))    # keyDown
        self.assertEqual(events_posted[1], (8, False))   # keyUp


class EventSourceIsolationTests(unittest.TestCase):
    def test_post_key_event_uses_provided_source(self) -> None:
        custom_source = object()
        key_event = object()

        with (
            patch(
                "app._lib.input.CGEventCreateKeyboardEvent",
                return_value=key_event,
            ) as create_mock,
            patch("app._lib.input.CGEventSetFlags"),
            patch("app._lib.input.CGEventPostToPid"),
        ):
            cg_input._post_key_event(123, 31, True, 0, source=custom_source)

        create_mock.assert_called_once_with(custom_source, 31, True)

    def test_post_key_event_falls_back_to_default_source(self) -> None:
        key_event = object()

        with (
            patch(
                "app._lib.input.CGEventCreateKeyboardEvent",
                return_value=key_event,
            ) as create_mock,
            patch("app._lib.input.CGEventSetFlags"),
            patch("app._lib.input.CGEventPostToPid"),
        ):
            cg_input._post_key_event(123, 31, True, 0)

        create_mock.assert_called_once_with(cg_input._source, 31, True)

    def test_post_click_uses_provided_source(self) -> None:
        custom_source = object()
        down = object()
        up = object()

        with (
            patch(
                "app._lib.input.CGEventCreateMouseEvent",
                side_effect=[down, up],
            ) as create_mock,
            patch("app._lib.input.CGEventSetIntegerValueField"),
            patch("app._lib.input.CGEventSetDoubleValueField"),
            patch("app._lib.input.CGEventPostToPid"),
            patch("app._lib.input.time.sleep"),
        ):
            cg_input._post_click(456, sentinel.point, "left", 1, source=custom_source)

        # All three events should use custom_source
        for call_args in create_mock.call_args_list:
            self.assertIs(call_args[0][0], custom_source)

    def test_create_event_source_returns_private_source(self) -> None:
        fake_source = object()
        with patch("app._lib.input.CGEventSourceCreate", return_value=fake_source) as create_mock:
            result = cg_input.create_event_source()

        create_mock.assert_called_once_with(cg_input.kCGEventSourceStatePrivate)
        self.assertIs(result, fake_source)


class ScrollOverhaulTests(unittest.TestCase):
    def test_scroll_system_removed(self) -> None:
        self.assertFalse(hasattr(cg_input, "scroll_system"))

    def test_scroll_pid_pixel_sets_both_delta_fields(self) -> None:
        scroll = object()

        with (
            patch("app._lib.input.CGEventCreateScrollWheelEvent", return_value=scroll),
            patch("app._lib.input.CGEventSetIntegerValueField") as set_int,
            patch("app._lib.input.CGEventSetDoubleValueField") as set_double,
            patch("app._lib.input.CGEventPostToPid"),
        ):
            cg_input.scroll_pid_pixel(123, 100.0, 200.0, "down", 80, window_id=77)

        # Check integer deltas were set on the scroll event
        int_calls_on_scroll = [(c[0][1], c[0][2]) for c in set_int.call_args_list if c[0][0] is scroll]
        # Should have kCGScrollWheelEventPointDeltaAxis1 = -80 and Axis2 = 0
        self.assertTrue(any(v == -80 for _, v in int_calls_on_scroll))
        self.assertTrue(any(v == 0 for _, v in int_calls_on_scroll))

        # Check fixed-point deltas were set
        double_calls_on_scroll = [(c[0][1], c[0][2]) for c in set_double.call_args_list if c[0][0] is scroll]
        self.assertTrue(any(v == -80.0 for _, v in double_calls_on_scroll))

    def test_default_scroll_quantum_is_80_pixels(self) -> None:
        self.assertEqual(cg_input.SCROLL_PIXEL_QUANTUM, 80)


if __name__ == "__main__":
    unittest.main()
