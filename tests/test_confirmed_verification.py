from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from app._lib.confirmed_verification import (
    ActionVerifier,
    DeliveryVerdict,
    ElementSnapshot,
    ExpectedDiff,
)


class ElementSnapshotTests(unittest.TestCase):
    def test_diff_detects_value_change(self) -> None:
        before = ElementSnapshot(value="old", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        after = ElementSnapshot(value="new", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        diff = before.diff(after)
        self.assertTrue(diff.value_changed)
        self.assertFalse(diff.selection_changed)
        self.assertFalse(diff.focus_changed)

    def test_diff_detects_selection_change(self) -> None:
        before = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        after = ElementSnapshot(value="x", selected=True, focused_element_id=1, menu_open=False, child_count=3)
        diff = before.diff(after)
        self.assertTrue(diff.selection_changed)
        self.assertFalse(diff.value_changed)

    def test_diff_detects_focus_change(self) -> None:
        before = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        after = ElementSnapshot(value="x", selected=False, focused_element_id=2, menu_open=False, child_count=3)
        diff = before.diff(after)
        self.assertTrue(diff.focus_changed)

    def test_diff_detects_menu_toggle(self) -> None:
        before = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        after = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=True, child_count=3)
        diff = before.diff(after)
        self.assertTrue(diff.menu_toggled)

    def test_diff_detects_layout_change(self) -> None:
        before = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        after = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=False, child_count=5)
        diff = before.diff(after)
        self.assertTrue(diff.layout_changed)

    def test_diff_no_changes(self) -> None:
        snap = ElementSnapshot(value="x", selected=False, focused_element_id=1, menu_open=False, child_count=3)
        diff = snap.diff(snap)
        self.assertFalse(diff.any_changed)


class VerdictTests(unittest.TestCase):
    def test_transport_confirmed_and_semantic_confirmed(self) -> None:
        verdict = ActionVerifier.compute_verdict(
            transport_confirmed=True,
            diff_any_changed=True,
            expected=ExpectedDiff.FOCUS_OR_LAYOUT,
            fallback_used=False,
        )
        self.assertEqual(verdict, DeliveryVerdict.CONFIRMED)

    def test_transport_confirmed_no_semantic_change(self) -> None:
        verdict = ActionVerifier.compute_verdict(
            transport_confirmed=True,
            diff_any_changed=False,
            expected=ExpectedDiff.FOCUS_OR_LAYOUT,
            fallback_used=False,
        )
        self.assertEqual(verdict, DeliveryVerdict.DELIVERED_NO_EFFECT)

    def test_transport_failed(self) -> None:
        verdict = ActionVerifier.compute_verdict(
            transport_confirmed=False,
            diff_any_changed=False,
            expected=ExpectedDiff.FOCUS_OR_LAYOUT,
            fallback_used=False,
        )
        self.assertEqual(verdict, DeliveryVerdict.TRANSPORT_FAILED)

    def test_fallback_confirmed(self) -> None:
        verdict = ActionVerifier.compute_verdict(
            transport_confirmed=True,
            diff_any_changed=True,
            expected=ExpectedDiff.FOCUS_OR_LAYOUT,
            fallback_used=True,
        )
        self.assertEqual(verdict, DeliveryVerdict.CONFIRMED_VIA_FALLBACK)

    def test_transport_only_for_scroll(self) -> None:
        verdict = ActionVerifier.compute_verdict(
            transport_confirmed=True,
            diff_any_changed=False,
            expected=ExpectedDiff.TRANSPORT_ONLY,
            fallback_used=False,
        )
        self.assertEqual(verdict, DeliveryVerdict.CONFIRMED)


if __name__ == "__main__":
    unittest.main()
