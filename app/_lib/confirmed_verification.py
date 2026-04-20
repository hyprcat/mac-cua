"""Unified action verification: pre/post element snapshots + delivery confirmation.

Replaces the dual-monitor system (ActionOutcomeMonitor + CGEventOutcomeMonitor)
with a single source of truth.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


class DeliveryVerdict(str, Enum):
    CONFIRMED = "confirmed"
    CONFIRMED_VIA_FALLBACK = "confirmed_via_fallback"
    DELIVERED_NO_EFFECT = "delivered_no_effect"
    TRANSPORT_FAILED = "transport_failed"


class ExpectedDiff(str, Enum):
    """What kind of UI change a tool expects after a successful action."""
    FOCUS_OR_LAYOUT = "focus_or_layout"
    SELECTION_CHANGED = "selection_changed"
    VALUE_CHANGED = "value_changed"
    LAYOUT_OR_MENU = "layout_or_menu"
    MENU_TOGGLED = "menu_toggled"
    ACTION_DEPENDENT = "action_dependent"
    TRANSPORT_ONLY = "transport_only"


@dataclass(frozen=True)
class StateDiff:
    """Diff between two ElementSnapshots."""
    value_changed: bool
    selection_changed: bool
    focus_changed: bool
    menu_toggled: bool
    layout_changed: bool

    @property
    def any_changed(self) -> bool:
        return (
            self.value_changed
            or self.selection_changed
            or self.focus_changed
            or self.menu_toggled
            or self.layout_changed
        )


@dataclass(frozen=True)
class ElementSnapshot:
    """Lightweight capture of element state for pre/post comparison."""
    value: Any
    selected: bool
    focused_element_id: Any
    menu_open: bool
    child_count: int

    def diff(self, after: ElementSnapshot) -> StateDiff:
        return StateDiff(
            value_changed=self.value != after.value,
            selection_changed=self.selected != after.selected,
            focus_changed=self.focused_element_id != after.focused_element_id,
            menu_toggled=self.menu_open != after.menu_open,
            layout_changed=self.child_count != after.child_count,
        )


class ActionVerifier:
    """Stateless verdict computation. Session wires in the actual AX/transport signals."""

    @staticmethod
    def compute_verdict(
        *,
        transport_confirmed: bool,
        diff_any_changed: bool,
        expected: ExpectedDiff,
        fallback_used: bool,
    ) -> DeliveryVerdict:
        if not transport_confirmed:
            return DeliveryVerdict.TRANSPORT_FAILED

        if expected == ExpectedDiff.TRANSPORT_ONLY:
            return DeliveryVerdict.CONFIRMED

        if diff_any_changed:
            if fallback_used:
                return DeliveryVerdict.CONFIRMED_VIA_FALLBACK
            return DeliveryVerdict.CONFIRMED

        return DeliveryVerdict.DELIVERED_NO_EFFECT
