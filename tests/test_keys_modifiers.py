from __future__ import annotations

import unittest

from app._lib.keys import decompose_modifier_sequence


class DecomposeModifierSequenceTests(unittest.TestCase):
    def test_empty_mask_returns_empty_list(self) -> None:
        result = decompose_modifier_sequence(0)
        self.assertEqual(result, [])

    def test_single_modifier_shift(self) -> None:
        MASK_SHIFT = 1 << 17
        result = decompose_modifier_sequence(MASK_SHIFT)
        self.assertEqual(len(result), 1)
        keycode, cumulative_flags = result[0]
        self.assertEqual(keycode, 56)  # shift keycode
        self.assertEqual(cumulative_flags, MASK_SHIFT)

    def test_single_modifier_command(self) -> None:
        MASK_COMMAND = 1 << 20
        result = decompose_modifier_sequence(MASK_COMMAND)
        self.assertEqual(len(result), 1)
        keycode, cumulative_flags = result[0]
        self.assertEqual(keycode, 55)  # cmd keycode
        self.assertEqual(cumulative_flags, MASK_COMMAND)

    def test_two_modifiers_shift_cmd_returns_ordered_with_cumulative_flags(self) -> None:
        MASK_SHIFT = 1 << 17
        MASK_COMMAND = 1 << 20
        mask = MASK_SHIFT | MASK_COMMAND
        result = decompose_modifier_sequence(mask)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0], (56, MASK_SHIFT))
        self.assertEqual(result[1], (55, MASK_SHIFT | MASK_COMMAND))

    def test_three_modifiers_ctrl_shift_cmd(self) -> None:
        MASK_SHIFT = 1 << 17
        MASK_CONTROL = 1 << 18
        MASK_COMMAND = 1 << 20
        mask = MASK_SHIFT | MASK_CONTROL | MASK_COMMAND
        result = decompose_modifier_sequence(mask)
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0], (56, MASK_SHIFT))
        self.assertEqual(result[1], (59, MASK_SHIFT | MASK_CONTROL))
        self.assertEqual(result[2], (55, MASK_SHIFT | MASK_CONTROL | MASK_COMMAND))

    def test_all_four_modifiers(self) -> None:
        MASK_SHIFT = 1 << 17
        MASK_CONTROL = 1 << 18
        MASK_ALTERNATE = 1 << 19
        MASK_COMMAND = 1 << 20
        mask = MASK_SHIFT | MASK_CONTROL | MASK_ALTERNATE | MASK_COMMAND
        result = decompose_modifier_sequence(mask)
        self.assertEqual(len(result), 4)
        self.assertEqual(result[0][0], 56)  # shift
        self.assertEqual(result[1][0], 59)  # control
        self.assertEqual(result[2][0], 58)  # alt
        self.assertEqual(result[3][0], 55)  # cmd
        self.assertEqual(result[3][1], mask)


if __name__ == "__main__":
    unittest.main()
