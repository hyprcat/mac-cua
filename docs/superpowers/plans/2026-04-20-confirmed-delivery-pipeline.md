# Confirmed Delivery Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace unreliable CGEventPostToPid input delivery with a confirmed-delivery pipeline using SkyLight SPIs, discrete modifier sequences, event-driven confirmation, and per-session isolation.

**Architecture:** Incremental retrofit. Keep existing module boundaries. Add `skylight.py` (ctypes wrapper) and `verification.py` (unified verifier). Modify `input.py`, `keys.py`, `event_tap.py`, `virtual_cursor.py`, `screenshot.py`, and `session.py` internals. No changes to MCP tool schemas or ToolResponse format.

**Tech Stack:** Python 3.13, ctypes (SkyLight/CoreGraphics private SPIs), Quartz framework, AXObserver, CGEventTap, threading.Event

---

## Parallel Groups

```
Group A (no dependencies — run all 4 in parallel):
  Task 1: decompose_modifier_mask in keys.py
  Task 2: skylight.py ctypes wrapper
  Task 3: ActionVerifier in verification.py
  Task 4: Event source isolation in input.py

Group B (depends on Group A — run all 3 in parallel):
  Task 5: Delivery confirmation tap in event_tap.py (needs Task 4)
  Task 6: Discrete modifier sequences in input.py (needs Task 1, Task 4)
  Task 7: InputStrategy delivery/activation columns in virtual_cursor.py (needs Task 2)

Group C (depends on Group B — run all 3 in parallel):
  Task 8: Unified delivery pipeline in input.py (needs Tasks 2, 4, 5, 6)
  Task 9: Scroll overhaul in input.py (needs Tasks 4, 8)
  Task 10: Snapshot integrity in screenshot.py (needs Task 2)

Group D (depends on Group C):
  Task 11: Session integration in session.py (needs all above)
```

---

### Task 1: decompose_modifier_mask in keys.py

**Files:**
- Modify: `app/_lib/keys.py:218-219`
- Test: `tests/test_keys_modifiers.py`

This is a pure function with no macOS dependencies. The existing `modifier_keycodes(mask)` returns `list[tuple[keycode, flag]]` but doesn't guarantee ordering or provide cumulative masks. We need a function that returns the *sequence* of modifier events to emit, with cumulative flags at each step.

- [ ] **Step 1: Write the failing test**

Create `tests/test_keys_modifiers.py`:

```python
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
        # Order: shift first (bit 17), then cmd (bit 20)
        # — sorted by flag bit position ascending
        self.assertEqual(result[0], (56, MASK_SHIFT))  # shift down, cumulative = shift
        self.assertEqual(result[1], (55, MASK_SHIFT | MASK_COMMAND))  # cmd down, cumulative = shift|cmd

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
        # Last entry has all flags
        self.assertEqual(result[3][1], mask)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_keys_modifiers.py -v`
Expected: FAIL with `ImportError: cannot import name 'decompose_modifier_sequence'`

- [ ] **Step 3: Implement decompose_modifier_sequence**

Add to `app/_lib/keys.py` after line 219 (after `modifier_keycodes`):

```python
def decompose_modifier_sequence(mask: int) -> list[tuple[int, int]]:
    """Decompose a modifier mask into an ordered sequence for discrete key events.

    Returns a list of ``(keycode, cumulative_flags)`` tuples in the order
    modifiers should be pressed (sorted by flag bit position ascending).
    Each entry's ``cumulative_flags`` is the bitwise OR of all flags up to
    and including that modifier — matching what a real keyboard produces
    in its ``flagsChanged`` event stream.
    """
    present = [(flag, keycode) for flag, keycode in _MODIFIER_KEYCODES if mask & flag]
    present.sort(key=lambda pair: pair[0])  # ascending by flag bit value
    result: list[tuple[int, int]] = []
    cumulative = 0
    for flag, keycode in present:
        cumulative |= flag
        result.append((keycode, cumulative))
    return result
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_keys_modifiers.py -v`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/keys.py tests/test_keys_modifiers.py
git commit -m "feat: add decompose_modifier_sequence for discrete modifier events"
```

---

### Task 2: SkyLight ctypes wrapper

**Files:**
- Create: `app/_lib/skylight.py`
- Test: `tests/test_skylight.py`

Thin ctypes wrapper for CoreGraphics Server / SkyLight private SPIs. These are used for direct window-server event delivery and micro-activation.

- [ ] **Step 1: Write the failing test**

Create `tests/test_skylight.py`:

```python
from __future__ import annotations

import ctypes
import unittest
from unittest.mock import MagicMock, patch, PropertyMock


class SkyLightLoadTests(unittest.TestCase):
    """Test that skylight.py loads and exposes its API correctly."""

    @patch("app._lib.skylight._load_framework")
    def test_get_main_connection_calls_cgs_function(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        mock_load.return_value = mock_framework

        # Re-import to pick up the mock
        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        cid = skylight.get_main_connection()
        self.assertEqual(cid, 42)
        mock_framework.CGSMainConnectionID.assert_called_once()

    @patch("app._lib.skylight._load_framework")
    def test_get_connection_for_pid_calls_cgs_function(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        # CGSGetConnectionIDForPID writes into a c_int pointer
        def fake_get_cid(cid, pid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetConnectionIDForPID.side_effect = fake_get_cid
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        result = skylight.get_connection_for_pid(42, 1234)
        mock_framework.CGSGetConnectionIDForPID.assert_called_once()

    @patch("app._lib.skylight._load_framework")
    def test_validate_window_owner_returns_true_for_matching_pid(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        # Both calls return same connection ID
        def fake_get_cid(cid, pid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetConnectionIDForPID.side_effect = fake_get_cid
        def fake_get_owner(cid, wid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetWindowOwner.side_effect = fake_get_owner
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        self.assertTrue(skylight.validate_window_owner(77, 1234))

    @patch("app._lib.skylight._load_framework")
    def test_validate_window_owner_returns_false_for_mismatched_pid(self, mock_load: MagicMock) -> None:
        mock_framework = MagicMock()
        mock_framework.CGSMainConnectionID.return_value = 42
        def fake_get_cid(cid, pid, out_ptr):
            out_ptr._obj.value = 99
            return 0
        mock_framework.CGSGetConnectionIDForPID.side_effect = fake_get_cid
        def fake_get_owner(cid, wid, out_ptr):
            out_ptr._obj.value = 50  # different from 99
            return 0
        mock_framework.CGSGetWindowOwner.side_effect = fake_get_owner
        mock_load.return_value = mock_framework

        import importlib
        from app._lib import skylight
        importlib.reload(skylight)

        self.assertFalse(skylight.validate_window_owner(77, 1234))


class MicroActivationTests(unittest.TestCase):

    @patch("app._lib.skylight._framework", new_callable=lambda: MagicMock)
    @patch("app._lib.skylight._main_cid", 42)
    @patch("app._lib.skylight.get_connection_for_pid", return_value=99)
    @patch("app._lib.skylight.time")
    def test_micro_activate_context_restores_on_exit(
        self, mock_time: MagicMock, mock_get_cid: MagicMock, mock_fw: MagicMock
    ) -> None:
        mock_time.monotonic.side_effect = [0.0, 0.001, 0.002]  # well under 10ms
        from app._lib.skylight import micro_activate

        with micro_activate(target_pid=1234):
            pass  # activation should be set and then restored

    @patch("app._lib.skylight._framework", new_callable=lambda: MagicMock)
    @patch("app._lib.skylight._main_cid", 42)
    @patch("app._lib.skylight.get_connection_for_pid", return_value=99)
    @patch("app._lib.skylight.time")
    def test_micro_activate_restores_even_on_exception(
        self, mock_time: MagicMock, mock_get_cid: MagicMock, mock_fw: MagicMock
    ) -> None:
        mock_time.monotonic.side_effect = [0.0, 0.001, 0.002]
        from app._lib.skylight import micro_activate

        with self.assertRaises(RuntimeError):
            with micro_activate(target_pid=1234):
                raise RuntimeError("boom")
        # Should not raise — restore happens in __exit__


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_skylight.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app._lib.skylight'`

- [ ] **Step 3: Implement skylight.py**

Create `app/_lib/skylight.py`:

```python
"""Thin ctypes wrapper for CoreGraphics Server / SkyLight private SPIs.

Provides:
- Window owner validation (snapshot integrity)
- Direct keyboard/mouse event delivery to process (bypass CGEvent tap chain)
- Invisible micro-activation (window-server-level frontmost flag flip)

macOS 13+ (Ventura). Falls back gracefully if symbols not found.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import logging
import platform
import time
from contextlib import contextmanager
from typing import Any, Generator

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Framework loading
# ---------------------------------------------------------------------------

_framework: Any = None
_main_cid: int = 0
_available: bool = False


def _load_framework() -> Any:
    """Load SkyLight / CoreGraphics framework and resolve symbols."""
    # SkyLight is the modern name; CGS functions live in CoreGraphics
    path = ctypes.util.find_library("CoreGraphics")
    if path is None:
        raise OSError("CoreGraphics framework not found")
    lib = ctypes.cdll.LoadLibrary(path)

    # Resolve function signatures
    lib.CGSMainConnectionID.restype = ctypes.c_int
    lib.CGSMainConnectionID.argtypes = []

    lib.CGSGetConnectionIDForPID.restype = ctypes.c_int  # CGError
    lib.CGSGetConnectionIDForPID.argtypes = [
        ctypes.c_int,  # cid (our connection)
        ctypes.c_int,  # pid
        ctypes.POINTER(ctypes.c_int),  # out_cid
    ]

    lib.CGSGetWindowOwner.restype = ctypes.c_int  # CGError
    lib.CGSGetWindowOwner.argtypes = [
        ctypes.c_int,  # cid
        ctypes.c_int,  # window_id
        ctypes.POINTER(ctypes.c_int),  # out_owner_cid
    ]

    lib.CGSPostKeyboardEventToProcess.restype = ctypes.c_int  # CGError
    lib.CGSPostKeyboardEventToProcess.argtypes = [
        ctypes.c_int,  # cid
        ctypes.c_int,  # target_pid
        ctypes.c_uint16,  # key_char
        ctypes.c_bool,  # key_down
    ]

    # Connection property manipulation (for micro-activation)
    try:
        lib.CGSSetConnectionProperty.restype = ctypes.c_int
        lib.CGSSetConnectionProperty.argtypes = [
            ctypes.c_int,  # owner_cid
            ctypes.c_int,  # target_cid
            ctypes.c_void_p,  # key (CFStringRef)
            ctypes.c_void_p,  # value (CFTypeRef)
        ]
    except AttributeError:
        pass  # Not available on this version

    return lib


def _init() -> None:
    """Initialize the module. Called once at import time."""
    global _framework, _main_cid, _available

    major, minor, _ = (int(x) for x in platform.mac_ver()[0].split("."))
    if major < 13:
        logger.info("[SkyLight] macOS %d.%d < 13, SkyLight SPIs unavailable", major, minor)
        return

    try:
        _framework = _load_framework()
        _main_cid = _framework.CGSMainConnectionID()
        _available = _main_cid != 0
        if _available:
            logger.debug("[SkyLight] Initialized, connection=%d", _main_cid)
        else:
            logger.warning("[SkyLight] CGSMainConnectionID returned 0")
    except (OSError, AttributeError) as e:
        logger.info("[SkyLight] Not available: %s", e)


_init()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def is_available() -> bool:
    """Return True if SkyLight SPIs are loaded and usable."""
    return _available


def get_main_connection() -> int:
    """Return our process's window server connection ID."""
    if not _available:
        raise RuntimeError("SkyLight not available")
    return _main_cid


def get_connection_for_pid(cid: int, pid: int) -> int | None:
    """Return the window server connection ID for a target PID, or None on failure."""
    if not _available:
        return None
    out = ctypes.c_int(0)
    err = _framework.CGSGetConnectionIDForPID(cid, pid, ctypes.byref(out))
    if err != 0:
        logger.debug("[SkyLight] CGSGetConnectionIDForPID(pid=%d) failed: error %d", pid, err)
        return None
    return out.value


def validate_window_owner(window_id: int, expected_pid: int) -> bool:
    """Check whether a window ID still belongs to the expected PID.

    Returns True if the window's owner connection matches the expected PID's
    connection. Returns False on mismatch or if either lookup fails.
    """
    if not _available:
        return True  # Can't validate — assume correct

    owner_cid_out = ctypes.c_int(0)
    err = _framework.CGSGetWindowOwner(_main_cid, window_id, ctypes.byref(owner_cid_out))
    if err != 0:
        return False

    expected_cid = get_connection_for_pid(_main_cid, expected_pid)
    if expected_cid is None:
        return False

    return owner_cid_out.value == expected_cid


def post_keyboard_event(pid: int, keycode: int, key_down: bool) -> bool:
    """Post a keyboard event directly to a process via the window server.

    Bypasses the CGEvent tap chain. Returns True on success.
    """
    if not _available:
        return False
    err = _framework.CGSPostKeyboardEventToProcess(_main_cid, pid, keycode, key_down)
    if err != 0:
        logger.debug("[SkyLight] CGSPostKeyboardEventToProcess(pid=%d, key=%d) failed: %d", pid, keycode, err)
        return False
    return True


# ---------------------------------------------------------------------------
# Micro-activation
# ---------------------------------------------------------------------------

_MICRO_ACTIVATION_BUDGET_S = 0.010  # 10ms hard limit


@contextmanager
def micro_activate(target_pid: int) -> Generator[None, None, None]:
    """Invisibly flip the window server's frontmost flag for a process.

    Context manager. Sets the target as frontmost, yields, then restores.
    Hard 10ms budget — if exceeded, restores immediately.

    No window ordering change, no visual change, no menu bar swap.
    """
    if not _available:
        yield
        return

    target_cid = get_connection_for_pid(_main_cid, target_pid)
    if target_cid is None:
        yield
        return

    start = time.monotonic()
    activated = False
    try:
        # Set target as frontmost in window server state
        _set_frontmost(target_cid, True)
        activated = True
        yield
    finally:
        if activated:
            elapsed = time.monotonic() - start
            if elapsed > _MICRO_ACTIVATION_BUDGET_S:
                logger.warning(
                    "[SkyLight] micro_activate exceeded budget: %.1fms",
                    elapsed * 1000,
                )
            _set_frontmost(target_cid, False)
            # Restore our own process as frontmost
            _set_frontmost(_main_cid, True)


def _set_frontmost(target_cid: int, frontmost: bool) -> None:
    """Set the frontmost flag on a window server connection."""
    if not _available or _framework is None:
        return
    try:
        from Foundation import NSString
        from CoreFoundation import kCFBooleanTrue, kCFBooleanFalse

        key = NSString.stringWithString_("SetFrontmost")
        value = kCFBooleanTrue if frontmost else kCFBooleanFalse
        _framework.CGSSetConnectionProperty(
            _main_cid,
            target_cid,
            ctypes.c_void_p(key.__c_void_p__()),
            ctypes.c_void_p(value.__c_void_p__()),
        )
    except Exception as e:
        logger.debug("[SkyLight] _set_frontmost failed: %s", e)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_skylight.py -v`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/skylight.py tests/test_skylight.py
git commit -m "feat: add SkyLight ctypes wrapper for window server SPIs"
```

---

### Task 3: Unified ActionVerifier

**Files:**
- Create: `app/_lib/confirmed_verification.py`
- Test: `tests/test_confirmed_verification.py`

The unified verifier replaces the dual-monitor system. It uses pre/post snapshots of AX element state to produce honest verdicts. This task builds the pure verdict logic; wiring to AX observers and delivery confirmation happens in Task 11.

- [ ] **Step 1: Write the failing test**

Create `tests/test_confirmed_verification.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_confirmed_verification.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement confirmed_verification.py**

Create `app/_lib/confirmed_verification.py`:

```python
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
    FOCUS_OR_LAYOUT = "focus_or_layout"          # click on button
    SELECTION_CHANGED = "selection_changed"        # click on row
    VALUE_CHANGED = "value_changed"                # set_value, type_text
    LAYOUT_OR_MENU = "layout_or_menu"              # press_key shortcut
    MENU_TOGGLED = "menu_toggled"                  # ShowMenu
    ACTION_DEPENDENT = "action_dependent"           # perform_secondary_action
    TRANSPORT_ONLY = "transport_only"              # scroll — no AX signal expected


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
    focused_element_id: Any  # id() of focused AXUIElement, or None
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

        # Scroll: transport confirmation is sufficient
        if expected == ExpectedDiff.TRANSPORT_ONLY:
            return DeliveryVerdict.CONFIRMED

        if diff_any_changed:
            if fallback_used:
                return DeliveryVerdict.CONFIRMED_VIA_FALLBACK
            return DeliveryVerdict.CONFIRMED

        return DeliveryVerdict.DELIVERED_NO_EFFECT
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_confirmed_verification.py -v`
Expected: All 11 tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/confirmed_verification.py tests/test_confirmed_verification.py
git commit -m "feat: add unified ActionVerifier with delivery verdict logic"
```

---

### Task 4: Event source isolation in input.py

**Files:**
- Modify: `app/_lib/input.py:39,52,79-84,87-91,94-109,160-214,244-293,327-402,445-461`
- Test: `tests/test_input.py` (update existing tests)

Change all event-creating functions to accept an optional `source` parameter instead of using the module-level `_source`. Remove the global `_MOUSE_EVENT_NUMBER`.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_input.py`:

```python
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
        move = object()
        down = object()
        up = object()

        with (
            patch(
                "app._lib.input.CGEventCreateMouseEvent",
                side_effect=[move, down, up],
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py::EventSourceIsolationTests -v`
Expected: FAIL — functions don't accept `source` parameter

- [ ] **Step 3: Implement event source isolation**

Modify `app/_lib/input.py`:

1. Add `create_event_source()` factory function after line 39:

```python
def create_event_source() -> Any:
    """Create a new private CGEventSource for session isolation."""
    return CGEventSourceCreate(kCGEventSourceStatePrivate)
```

2. Add `source` parameter to `_post_key_event` (line 79):

```python
def _post_key_event(pid: int, keycode: int, is_down: bool, flags: int, *, source: Any = None) -> None:
    src = source if source is not None else _source
    event = CGEventCreateKeyboardEvent(src, keycode, is_down)
    if event is None:
        raise CGEventError(f"cg_event_creation_failed: keycode={keycode}, down={is_down}")
    CGEventSetFlags(event, flags)
    CGEventPostToPid(pid, event)
```

3. Add `source` parameter to `_post_keycode_with_modifiers` (line 87):

```python
def _post_keycode_with_modifiers(pid: int, keycode: int, modifiers: int, *, source: Any = None) -> None:
    _post_key_event(pid, keycode, True, modifiers, source=source)
    time.sleep(_KEY_HOLD_DELAY)
    _post_key_event(pid, keycode, False, modifiers, source=source)
    time.sleep(_KEY_EVENT_DELAY)
```

4. Add `source` parameter to `_post_unicode_char` (line 94):

```python
def _post_unicode_char(pid: int, char: str, *, source: Any = None) -> None:
    from Quartz import CGEventKeyboardSetUnicodeString
    src = source if source is not None else _source

    down = CGEventCreateKeyboardEvent(src, 0, True)
    CGEventSetFlags(down, 0)
    CGEventKeyboardSetUnicodeString(down, len(char), char)
    CGEventPostToPid(pid, down)

    time.sleep(_KEY_HOLD_DELAY)

    up = CGEventCreateKeyboardEvent(src, 0, False)
    CGEventSetFlags(up, 0)
    CGEventKeyboardSetUnicodeString(up, len(char), char)
    CGEventPostToPid(pid, up)

    time.sleep(_KEY_EVENT_DELAY)
```

5. Add `source` parameter to `_post_click` (line 160) — replace `global _MOUSE_EVENT_NUMBER` with a per-call counter passed via a mutable list default, or simpler: add `source` and `event_number_start` params:

```python
def _post_click(
    pid: int,
    point: Any,
    button: str,
    count: int,
    *,
    window_id: int | None = None,
    source: Any = None,
) -> None:
    if button not in _BUTTON_MAP:
        raise InputError(f"Unknown mouse button: {button}")

    btn, down_type, up_type = _BUTTON_MAP[button]
    src = source if source is not None else _source
    global _MOUSE_EVENT_NUMBER

    move = CGEventCreateMouseEvent(src, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("cg_event_creation_failed: mouseMove")
    _MOUSE_EVENT_NUMBER += 1
    _decorate_mouse_event(move, window_id=window_id, pressure=0.0, event_number=_MOUSE_EVENT_NUMBER)
    CGEventPostToPid(pid, move)
    time.sleep(0.01)

    for click_num in range(1, count + 1):
        if click_num > 1:
            time.sleep(_DOUBLE_CLICK_INTERVAL)

        down = CGEventCreateMouseEvent(src, down_type, point, btn)
        if down is None:
            raise CGEventError("cg_event_creation_failed: mouseDown")
        _MOUSE_EVENT_NUMBER += 1
        _decorate_mouse_event(
            down,
            window_id=window_id,
            pressure=_MOUSE_PRESSURE,
            click_state=click_num,
            event_number=_MOUSE_EVENT_NUMBER,
        )
        CGEventPostToPid(pid, down)

        time.sleep(0.005)

        up = CGEventCreateMouseEvent(src, up_type, point, btn)
        if up is None:
            raise CGEventError("cg_event_creation_failed: mouseUp")
        _MOUSE_EVENT_NUMBER += 1
        _decorate_mouse_event(
            up,
            window_id=window_id,
            pressure=0.0,
            click_state=click_num,
            event_number=_MOUSE_EVENT_NUMBER,
        )
        CGEventPostToPid(pid, up)
```

6. Thread `source` through `click_at`, `click_at_screen_point`, `drag`, `press_key`, `type_text`, `scroll_pid`, `scroll_pid_pixel` — add `*, source: Any = None` parameter to each and pass it through to the underlying `_post_*` calls.

- [ ] **Step 4: Update existing tests and run all tests**

Update `tests/test_input.py` — the existing `test_post_keycode_with_modifiers_sends_chorded_key_events` references `cg_input._source` directly; this should still work since the default source fallback is preserved.

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py -v`
Expected: All tests PASS (old + new)

- [ ] **Step 5: Commit**

```bash
git add app/_lib/input.py tests/test_input.py
git commit -m "feat: add source parameter to all input functions for session isolation"
```

---

### Task 5: Delivery confirmation tap in event_tap.py

**Files:**
- Create: `app/_lib/delivery_tap.py`
- Test: `tests/test_delivery_tap.py`

A specialized listen-only event tap that watches for echoes of posted events, matched by source state ID. Built on top of the existing `EventTap` class.

- [ ] **Step 1: Write the failing test**

Create `tests/test_delivery_tap.py`:

```python
from __future__ import annotations

import threading
import unittest
from unittest.mock import MagicMock, patch

from app._lib.delivery_tap import DeliveryConfirmationTap


class DeliveryConfirmationTapTests(unittest.TestCase):
    def test_signal_fires_when_source_id_matches(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        event = MagicMock()

        with patch("app._lib.delivery_tap.CGEventGetIntegerValueField", return_value=42):
            tap._on_event(None, 10, event)  # KEY_DOWN = 10

        self.assertTrue(tap.transport_confirmed.is_set())

    def test_signal_does_not_fire_for_different_source_id(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        event = MagicMock()

        with patch("app._lib.delivery_tap.CGEventGetIntegerValueField", return_value=99):
            tap._on_event(None, 10, event)

        self.assertFalse(tap.transport_confirmed.is_set())

    def test_reset_clears_confirmed_flag(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        tap.transport_confirmed.set()
        tap.reset()
        self.assertFalse(tap.transport_confirmed.is_set())

    def test_wait_returns_false_on_timeout(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        result = tap.wait(timeout=0.001)
        self.assertFalse(result)

    def test_wait_returns_true_when_confirmed(self) -> None:
        tap = DeliveryConfirmationTap(expected_source_state_id=42)
        tap.transport_confirmed.set()
        result = tap.wait(timeout=0.01)
        self.assertTrue(result)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_delivery_tap.py -v`
Expected: FAIL with `ModuleNotFoundError`

- [ ] **Step 3: Implement DeliveryConfirmationTap**

Create `app/_lib/delivery_tap.py`:

```python
"""Per-session delivery confirmation via listen-only CGEventTap.

Watches for echoes of posted events matched by CGEventSource state ID.
Used by the delivery pipeline to confirm transport before proceeding.
"""

from __future__ import annotations

import logging
import threading
from typing import Any

from app._lib.event_tap import (
    EVENT_FLAGS_CHANGED,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_LEFT_MOUSE_DOWN,
    EVENT_LEFT_MOUSE_UP,
    EVENT_MOUSE_MOVED,
    EVENT_RIGHT_MOUSE_DOWN,
    EVENT_RIGHT_MOUSE_UP,
    EVENT_SCROLL_WHEEL,
    TAP_LOCATION_SESSION,
    TAP_OPTION_LISTEN_ONLY,
    EventTap,
    event_mask,
)

logger = logging.getLogger(__name__)

# CGEventField for source state ID
_kCGEventSourceStateID = 45

# Default transport confirmation timeout
TRANSPORT_TIMEOUT_S = 0.05

_ALL_INPUT_EVENTS = event_mask(
    EVENT_MOUSE_MOVED,
    EVENT_LEFT_MOUSE_DOWN,
    EVENT_LEFT_MOUSE_UP,
    EVENT_RIGHT_MOUSE_DOWN,
    EVENT_RIGHT_MOUSE_UP,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_FLAGS_CHANGED,
    EVENT_SCROLL_WHEEL,
)


def CGEventGetIntegerValueField(event: Any, field: int) -> int:
    """Wrapper — imported at call time to allow mocking in tests."""
    from Quartz import CGEventGetIntegerValueField as _get
    return _get(event, field)


class DeliveryConfirmationTap:
    """Listen-only event tap that confirms delivery of posted events.

    Each session creates one of these. It stays installed for the session
    lifetime. For each posted event, the caller resets the signal, posts
    the event, then waits on `transport_confirmed`.
    """

    def __init__(self, expected_source_state_id: int) -> None:
        self._expected_source_id = expected_source_state_id
        self.transport_confirmed = threading.Event()
        self._tap: EventTap | None = None

    def start(self) -> bool:
        """Install the listen-only tap on the session event stream."""
        self._tap = EventTap(
            event_types=_ALL_INPUT_EVENTS,
            location=TAP_LOCATION_SESSION,
            options=TAP_OPTION_LISTEN_ONLY,
        )
        self._tap.on_event_received = self._on_event
        return self._tap.start()

    def stop(self) -> None:
        """Remove the tap."""
        if self._tap is not None:
            self._tap.stop()
            self._tap = None

    def reset(self) -> None:
        """Clear the confirmed flag before posting the next event."""
        self.transport_confirmed.clear()

    def wait(self, timeout: float = TRANSPORT_TIMEOUT_S) -> bool:
        """Wait for transport confirmation. Returns True if confirmed."""
        return self.transport_confirmed.wait(timeout=timeout)

    def _on_event(self, proxy: Any, event_type: int, event: Any) -> Any:
        """Event tap callback — check if this is our event."""
        try:
            source_id = CGEventGetIntegerValueField(event, _kCGEventSourceStateID)
            if source_id == self._expected_source_id:
                self.transport_confirmed.set()
        except Exception:
            pass  # Don't crash the tap callback
        return event
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_delivery_tap.py -v`
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/delivery_tap.py tests/test_delivery_tap.py
git commit -m "feat: add DeliveryConfirmationTap for transport echo matching"
```

---

### Task 6: Discrete modifier sequences in input.py

**Files:**
- Modify: `app/_lib/input.py` (replace `_post_keycode_with_modifiers`)
- Test: `tests/test_input.py` (add new tests)

Replace the single compound event with a discrete flagsChanged sequence. Depends on Task 1 (`decompose_modifier_sequence`) and Task 4 (source parameter).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_input.py`:

```python
class DiscreteModifierTests(unittest.TestCase):
    def test_shift_cmd_s_produces_six_events(self) -> None:
        """shift+cmd+s should emit: shift_down, cmd_down, s_down, s_up, cmd_up, shift_up."""
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

        # 6 events: shift_down, cmd_down, s_down, s_up, cmd_up, shift_up
        self.assertEqual(len(events_posted), 6)
        # First event is shift down (keycode 56, True)
        self.assertEqual(events_posted[0], (56, True))
        # Second event is cmd down (keycode 55, True)
        self.assertEqual(events_posted[1], (55, True))
        # Third event is key down (keycode 1, True)
        self.assertEqual(events_posted[2], (1, True))
        # Fourth event is key up (keycode 1, False)
        self.assertEqual(events_posted[3], (1, False))
        # Fifth event is cmd up (keycode 55, False)
        self.assertEqual(events_posted[4], (55, False))
        # Sixth event is shift up (keycode 56, False)
        self.assertEqual(events_posted[5], (56, False))

    def test_plain_key_no_modifiers_produces_two_events(self) -> None:
        """Return key with no modifiers: just keyDown, keyUp."""
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

    def test_single_modifier_cmd_c_produces_four_events(self) -> None:
        """cmd+c: cmd_down, c_down, c_up, cmd_up."""
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

        self.assertEqual(len(events_posted), 4)
        self.assertEqual(events_posted[0], (55, True))   # cmd down
        self.assertEqual(events_posted[1], (8, True))     # c down
        self.assertEqual(events_posted[2], (8, False))    # c up
        self.assertEqual(events_posted[3], (55, False))   # cmd up
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py::DiscreteModifierTests -v`
Expected: FAIL — current implementation only posts 2 events

- [ ] **Step 3: Implement discrete modifier sequences**

Replace `_post_keycode_with_modifiers` in `app/_lib/input.py`:

```python
def _post_keycode_with_modifiers(pid: int, keycode: int, modifiers: int, *, source: Any = None) -> None:
    """Send a key press with discrete modifier events matching real keyboard behavior.

    For shift+cmd+s, emits:
      flagsChanged(shift_down, flags=shift)
      flagsChanged(cmd_down,   flags=shift|cmd)
      keyDown(s,               flags=shift|cmd)
      keyUp(s,                 flags=shift|cmd)
      flagsChanged(cmd_up,     flags=shift)
      flagsChanged(shift_up,   flags=0)
    """
    from app._lib.keys import decompose_modifier_sequence

    mod_sequence = decompose_modifier_sequence(modifiers)

    # Wind up: press each modifier in order
    for mod_keycode, cumulative_flags in mod_sequence:
        _post_key_event(pid, mod_keycode, True, cumulative_flags, source=source)
        time.sleep(_KEY_EVENT_DELAY)

    # Key down/up with full modifier mask
    _post_key_event(pid, keycode, True, modifiers, source=source)
    time.sleep(_KEY_HOLD_DELAY)
    _post_key_event(pid, keycode, False, modifiers, source=source)
    time.sleep(_KEY_EVENT_DELAY)

    # Unwind: release modifiers in reverse order
    for i, (mod_keycode, _) in enumerate(reversed(mod_sequence)):
        # Cumulative flags after releasing this modifier
        remaining_flags = 0
        for flag, kc in reversed(mod_sequence[:len(mod_sequence) - 1 - i]):
            remaining_flags = flag  # Use the cumulative_flags from the step before this one
            break
        # More precisely: remaining = cumulative of the one before in wind-up
        remaining_idx = len(mod_sequence) - 2 - i
        remaining_flags = mod_sequence[remaining_idx][1] if remaining_idx >= 0 else 0
        _post_key_event(pid, mod_keycode, False, remaining_flags, source=source)
        time.sleep(_KEY_EVENT_DELAY)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py -v`
Expected: All tests PASS

- [ ] **Step 5: Update existing test that expects 2 events**

The existing `test_post_keycode_with_modifiers_sends_chorded_key_events` sends keycode=31 with flags=16. flags=16 has no modifier bits set (modifiers start at bit 17), so `decompose_modifier_sequence(16)` returns `[]` and the function emits only 2 events (keyDown + keyUp) — the existing test should still pass. Verify this.

If the test fails, update it to match the new discrete behavior.

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py -v`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add app/_lib/input.py tests/test_input.py
git commit -m "feat: discrete modifier sequences for reliable cross-app key delivery"
```

---

### Task 7: InputStrategy delivery/activation columns

**Files:**
- Modify: `app/_lib/virtual_cursor.py:145-204`
- Test: `tests/test_virtual_cursor.py`

Add `delivery_method` and `activation_policy` properties to `InputStrategy`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_virtual_cursor.py`:

```python
from __future__ import annotations

import unittest

from app._lib.virtual_cursor import AppType, DeliveryMethod, ActivationPolicy, InputStrategy


class InputStrategyDeliveryTests(unittest.TestCase):
    def test_native_cocoa_uses_cgevent_delivery(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.CGEVENT_PID)

    def test_electron_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.ELECTRON)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_browser_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.BROWSER)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_java_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.JAVA)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_qt_uses_skylight_delivery(self) -> None:
        strategy = InputStrategy(AppType.QT)
        self.assertEqual(strategy.delivery_method, DeliveryMethod.SKYLIGHT_SPI)

    def test_native_cocoa_activation_is_never(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.activation_policy, ActivationPolicy.NEVER)

    def test_electron_activation_is_retry_only(self) -> None:
        strategy = InputStrategy(AppType.ELECTRON)
        self.assertEqual(strategy.activation_policy, ActivationPolicy.RETRY_ONLY)

    def test_native_cocoa_popup_activation_is_retry(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.activation_policy_for_popup, ActivationPolicy.RETRY_ONLY)

    def test_alternate_delivery_returns_other_method(self) -> None:
        strategy = InputStrategy(AppType.NATIVE_COCOA)
        self.assertEqual(strategy.alternate_delivery_method, DeliveryMethod.SKYLIGHT_SPI)

        strategy2 = InputStrategy(AppType.ELECTRON)
        self.assertEqual(strategy2.alternate_delivery_method, DeliveryMethod.CGEVENT_PID)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_virtual_cursor.py -v`
Expected: FAIL — `DeliveryMethod` and `ActivationPolicy` don't exist

- [ ] **Step 3: Implement delivery/activation enums and properties**

Add to `app/_lib/virtual_cursor.py` after `AppType` (after line 67):

```python
class DeliveryMethod(Enum):
    """Primary event delivery pipeline."""
    CGEVENT_PID = "cgevent_pid"      # CGEventPostToPid — works for native Cocoa
    SKYLIGHT_SPI = "skylight_spi"    # CGSPostKeyboardEventToProcess — works for Electron/browser/Java/Qt


class ActivationPolicy(Enum):
    """When to use invisible micro-activation."""
    NEVER = "never"            # Never micro-activate (AX actions, native Cocoa CGEvent)
    RETRY_ONLY = "retry_only"  # Only on retry after background delivery failed
```

Add properties to `InputStrategy` class:

```python
@property
def delivery_method(self) -> DeliveryMethod:
    """Primary delivery pipeline for this app type."""
    if self._app_type in (AppType.NATIVE_COCOA, AppType.UNKNOWN):
        return DeliveryMethod.CGEVENT_PID
    return DeliveryMethod.SKYLIGHT_SPI

@property
def alternate_delivery_method(self) -> DeliveryMethod:
    """Fallback delivery pipeline."""
    if self.delivery_method == DeliveryMethod.CGEVENT_PID:
        return DeliveryMethod.SKYLIGHT_SPI
    return DeliveryMethod.CGEVENT_PID

@property
def activation_policy(self) -> ActivationPolicy:
    """When to use micro-activation for regular actions."""
    if self._app_type in (AppType.NATIVE_COCOA, AppType.UNKNOWN):
        return ActivationPolicy.NEVER
    return ActivationPolicy.RETRY_ONLY

@property
def activation_policy_for_popup(self) -> ActivationPolicy:
    """Popups always qualify for micro-activation retry."""
    return ActivationPolicy.RETRY_ONLY
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_virtual_cursor.py -v`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/virtual_cursor.py tests/test_virtual_cursor.py
git commit -m "feat: add delivery method and activation policy to InputStrategy"
```

---

### Task 8: Unified delivery pipeline in input.py

**Files:**
- Modify: `app/_lib/input.py`
- Test: `tests/test_delivery_pipeline.py`

Add a `deliver_key_event` function that tries the primary pipeline, falls back to alternate, and optionally retries with micro-activation. This orchestrates Tasks 2 (SkyLight), 4 (source isolation), 5 (confirmation tap), and 6 (discrete modifiers).

- [ ] **Step 1: Write the failing test**

Create `tests/test_delivery_pipeline.py`:

```python
from __future__ import annotations

import unittest
from unittest.mock import MagicMock, patch, call

from app._lib.input import deliver_key_events
from app._lib.virtual_cursor import DeliveryMethod, ActivationPolicy


class DeliverKeyEventsTests(unittest.TestCase):
    @patch("app._lib.input._post_key_event")
    def test_cgevent_delivery_confirmed_on_first_try(self, mock_post: MagicMock) -> None:
        mock_tap = MagicMock()
        mock_tap.wait.return_value = True  # transport confirmed

        result = deliver_key_events(
            pid=123,
            keycode=8,
            modifiers=1 << 20,  # cmd
            source=MagicMock(),
            delivery_method=DeliveryMethod.CGEVENT_PID,
            confirmation_tap=mock_tap,
            activation_policy=ActivationPolicy.NEVER,
        )

        self.assertTrue(result.transport_confirmed)
        self.assertFalse(result.fallback_used)

    @patch("app._lib.input.skylight")
    @patch("app._lib.input._post_key_event")
    def test_falls_back_to_skylight_on_cgevent_timeout(
        self, mock_post: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_tap = MagicMock()
        # First attempt (CGEvent): timeout. Second attempt (SkyLight): confirmed.
        mock_tap.wait.side_effect = [False, False, False, False, True, True, True, True]
        mock_skylight.post_keyboard_event.return_value = True
        mock_skylight.is_available.return_value = True

        result = deliver_key_events(
            pid=123,
            keycode=8,
            modifiers=1 << 20,
            source=MagicMock(),
            delivery_method=DeliveryMethod.CGEVENT_PID,
            confirmation_tap=mock_tap,
            activation_policy=ActivationPolicy.RETRY_ONLY,
        )

        self.assertTrue(result.transport_confirmed)
        self.assertTrue(result.fallback_used)

    @patch("app._lib.input._post_key_event")
    def test_all_pipelines_fail_returns_not_confirmed(self, mock_post: MagicMock) -> None:
        mock_tap = MagicMock()
        mock_tap.wait.return_value = False  # always timeout

        result = deliver_key_events(
            pid=123,
            keycode=36,
            modifiers=0,
            source=MagicMock(),
            delivery_method=DeliveryMethod.CGEVENT_PID,
            confirmation_tap=mock_tap,
            activation_policy=ActivationPolicy.NEVER,
        )

        self.assertFalse(result.transport_confirmed)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_delivery_pipeline.py -v`
Expected: FAIL — `deliver_key_events` doesn't exist

- [ ] **Step 3: Implement deliver_key_events**

Add to `app/_lib/input.py`:

```python
from dataclasses import dataclass

@dataclass(frozen=True)
class DeliveryResult:
    transport_confirmed: bool
    fallback_used: bool
    micro_activated: bool


def deliver_key_events(
    *,
    pid: int,
    keycode: int,
    modifiers: int,
    source: Any,
    delivery_method: Any,  # DeliveryMethod
    confirmation_tap: Any,  # DeliveryConfirmationTap
    activation_policy: Any,  # ActivationPolicy
) -> DeliveryResult:
    """Deliver a key press through the confirmed delivery pipeline.

    Tries primary pipeline with discrete modifier sequences, confirms
    via tap echo, falls back to alternate pipeline on timeout, and
    optionally retries with micro-activation for qualified actions.
    """
    from app._lib import skylight
    from app._lib.keys import decompose_modifier_sequence
    from app._lib.virtual_cursor import DeliveryMethod, ActivationPolicy

    mod_sequence = decompose_modifier_sequence(modifiers)

    def _try_cgevent(src: Any) -> bool:
        """Attempt delivery via CGEventPostToPid with discrete modifiers."""
        for mod_keycode, cumulative_flags in mod_sequence:
            confirmation_tap.reset()
            _post_key_event(pid, mod_keycode, True, cumulative_flags, source=src)
            if not confirmation_tap.wait():
                return False

        confirmation_tap.reset()
        _post_key_event(pid, keycode, True, modifiers, source=src)
        if not confirmation_tap.wait():
            return False

        confirmation_tap.reset()
        _post_key_event(pid, keycode, False, modifiers, source=src)
        if not confirmation_tap.wait():
            return False

        for i, (mod_keycode, _) in enumerate(reversed(mod_sequence)):
            remaining_idx = len(mod_sequence) - 2 - i
            remaining_flags = mod_sequence[remaining_idx][1] if remaining_idx >= 0 else 0
            confirmation_tap.reset()
            _post_key_event(pid, mod_keycode, False, remaining_flags, source=src)
            if not confirmation_tap.wait():
                return False

        return True

    def _try_skylight() -> bool:
        """Attempt delivery via SkyLight SPI."""
        if not skylight.is_available():
            return False

        for mod_keycode, _ in mod_sequence:
            if not skylight.post_keyboard_event(pid, mod_keycode, True):
                return False

        if not skylight.post_keyboard_event(pid, keycode, True):
            return False
        if not skylight.post_keyboard_event(pid, keycode, False):
            return False

        for mod_keycode, _ in reversed(mod_sequence):
            if not skylight.post_keyboard_event(pid, mod_keycode, False):
                return False

        return True

    # Attempt 1: Primary pipeline
    if delivery_method == DeliveryMethod.CGEVENT_PID:
        if _try_cgevent(source):
            return DeliveryResult(transport_confirmed=True, fallback_used=False, micro_activated=False)
        # Fallback to SkyLight
        if _try_skylight():
            return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=False)
    else:  # SKYLIGHT_SPI primary
        if _try_skylight():
            return DeliveryResult(transport_confirmed=True, fallback_used=False, micro_activated=False)
        # Fallback to CGEvent
        if _try_cgevent(source):
            return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=False)

    # Attempt 2: Retry with micro-activation if policy allows
    if activation_policy == ActivationPolicy.RETRY_ONLY:
        with skylight.micro_activate(target_pid=pid):
            if delivery_method == DeliveryMethod.CGEVENT_PID:
                if _try_cgevent(source):
                    return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=True)
            else:
                if _try_skylight():
                    return DeliveryResult(transport_confirmed=True, fallback_used=True, micro_activated=True)

    return DeliveryResult(transport_confirmed=False, fallback_used=True, micro_activated=False)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_delivery_pipeline.py -v`
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/input.py tests/test_delivery_pipeline.py
git commit -m "feat: unified delivery pipeline with fallback and micro-activation"
```

---

### Task 9: Scroll overhaul

**Files:**
- Modify: `app/_lib/input.py` (scroll functions)
- Test: `tests/test_input.py` (add scroll tests)

Remove `scroll_system()`. Fix `scroll_pid_pixel()` to set both integer and fixed-point deltas plus event location. Update default scroll quantum.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_input.py`:

```python
class ScrollOverhaulTests(unittest.TestCase):
    def test_scroll_system_removed(self) -> None:
        self.assertFalse(hasattr(cg_input, "scroll_system"))

    def test_scroll_pid_pixel_sets_both_delta_fields_and_location(self) -> None:
        move = object()
        scroll = object()

        with (
            patch("app._lib.input.CGEventCreateMouseEvent", return_value=move),
            patch("app._lib.input.CGEventCreateScrollWheelEvent", return_value=scroll),
            patch("app._lib.input.CGEventSetIntegerValueField") as set_int,
            patch("app._lib.input.CGEventSetDoubleValueField") as set_double,
            patch("app._lib.input.CGEventPostToPid"),
            patch("app._lib.input._decorate_mouse_event"),
            patch("app._lib.input.time.sleep"),
        ):
            from Quartz import kCGScrollWheelEventPointDeltaAxis1, kCGScrollWheelEventPointDeltaAxis2
            cg_input.scroll_pid_pixel(123, 100.0, 200.0, "down", 80, window_id=77)

        # Should set integer delta fields
        int_calls = {(c[0][1], c[0][2]) for c in set_int.call_args_list if c[0][0] is scroll}
        self.assertIn((kCGScrollWheelEventPointDeltaAxis1, -80), int_calls)
        self.assertIn((kCGScrollWheelEventPointDeltaAxis2, 0), int_calls)

        # Should set fixed-point delta field
        double_calls = [(c[0][1], c[0][2]) for c in set_double.call_args_list if c[0][0] is scroll]
        self.assertTrue(any(v == -80.0 for _, v in double_calls))

    def test_default_scroll_quantum_is_80_pixels(self) -> None:
        self.assertEqual(cg_input.SCROLL_PIXEL_QUANTUM, 80)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py::ScrollOverhaulTests -v`
Expected: FAIL

- [ ] **Step 3: Implement scroll changes**

In `app/_lib/input.py`:

1. Remove the entire `scroll_system` function (lines 405-442).
2. Replace `_SCROLL_LINE_DELTA = 5` with `SCROLL_PIXEL_QUANTUM = 80`.
3. Update `scroll_pid_pixel` to set the fixed-point delta field and event location:

```python
def scroll_pid_pixel(
    pid: int,
    x: float,
    y: float,
    direction: str,
    pixels: int,
    *,
    window_id: int | None = None,
    source: Any = None,
) -> None:
    """Scroll via pixel deltas with both integer and fixed-point fields set."""
    from Quartz import (
        CGEventCreateScrollWheelEvent,
        kCGScrollEventUnitPixel,
        kCGScrollWheelEventPointDeltaAxis1,
        kCGScrollWheelEventPointDeltaAxis2,
        kCGScrollWheelEventFixedPtDeltaAxis1,
        kCGScrollWheelEventFixedPtDeltaAxis2,
    )

    src = source if source is not None else _source
    point = CGPointMake(x, y)
    move = CGEventCreateMouseEvent(src, kCGEventMouseMoved, point, kCGMouseButtonLeft)
    if move is None:
        raise CGEventError("cg_event_creation_failed: scroll mouseMove")
    _decorate_mouse_event(move, window_id=window_id, pressure=0.0)
    CGEventPostToPid(pid, move)

    dy = dx = 0
    if direction == "up":
        dy = pixels
    elif direction == "down":
        dy = -pixels
    elif direction == "left":
        dx = pixels
    elif direction == "right":
        dx = -pixels

    scroll = CGEventCreateScrollWheelEvent(src, kCGScrollEventUnitPixel, 2, dy, dx)
    if scroll is None:
        raise CGEventError("cg_event_creation_failed: scrollWheel")
    # Set integer deltas (Chromium reads these)
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventPointDeltaAxis1, dy)
    CGEventSetIntegerValueField(scroll, kCGScrollWheelEventPointDeltaAxis2, dx)
    # Set fixed-point deltas (Cocoa reads these)
    CGEventSetDoubleValueField(scroll, kCGScrollWheelEventFixedPtDeltaAxis1, float(dy))
    CGEventSetDoubleValueField(scroll, kCGScrollWheelEventFixedPtDeltaAxis2, float(dx))
    CGEventPostToPid(pid, scroll)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_input.py -v`
Expected: All tests PASS

- [ ] **Step 5: Update session.py references to scroll_system**

Search for `scroll_system` in `app/session.py` and replace with `scroll_pid_pixel` using `SCROLL_PIXEL_QUANTUM` as the default pixel amount. Update the `_scroll_method_order` and `_try_scroll_method` functions to remove the "system" method.

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/ -v`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add app/_lib/input.py app/session.py tests/test_input.py
git commit -m "feat: scroll overhaul — remove cursor warp, fix pixel deltas, add quantum"
```

---

### Task 10: Snapshot integrity via window ID validation

**Files:**
- Modify: `app/_lib/screenshot.py`
- Test: `tests/test_screenshot.py`

Add `validate_and_capture` that checks window ownership before capture.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_screenshot.py`:

```python
class SnapshotIntegrityTests(unittest.TestCase):
    @patch("app._lib.screenshot.skylight")
    @patch("app._lib.screenshot.capture_window")
    def test_validate_and_capture_succeeds_for_valid_window(
        self, mock_capture: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_skylight.validate_window_owner.return_value = True
        mock_capture.return_value = MagicMock()  # fake image

        result = screenshot.validate_and_capture(window_id=77, expected_pid=123)

        mock_skylight.validate_window_owner.assert_called_once_with(77, 123)
        mock_capture.assert_called_once_with(77)
        self.assertIsNotNone(result)

    @patch("app._lib.screenshot.skylight")
    @patch("app._lib.screenshot.list_windows")
    @patch("app._lib.screenshot.capture_window")
    def test_validate_and_capture_re_resolves_stale_window_id(
        self, mock_capture: MagicMock, mock_list: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_skylight.validate_window_owner.return_value = False
        mock_list.return_value = [
            MagicMock(window_id=88, owner_pid=123, onscreen=True, width=800, height=600),
        ]
        mock_capture.return_value = MagicMock()

        result, new_window_id = screenshot.validate_and_capture(window_id=77, expected_pid=123)

        self.assertEqual(new_window_id, 88)
        mock_capture.assert_called_once_with(88)

    @patch("app._lib.screenshot.skylight")
    @patch("app._lib.screenshot.list_windows")
    def test_validate_and_capture_returns_none_when_no_window_found(
        self, mock_list: MagicMock, mock_skylight: MagicMock
    ) -> None:
        mock_skylight.validate_window_owner.return_value = False
        mock_list.return_value = []  # no windows for this PID

        result = screenshot.validate_and_capture(window_id=77, expected_pid=123)

        self.assertIsNone(result)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_screenshot.py::SnapshotIntegrityTests -v`
Expected: FAIL — `validate_and_capture` doesn't exist

- [ ] **Step 3: Implement validate_and_capture**

Add to `app/_lib/screenshot.py`:

```python
from app._lib import skylight


def validate_and_capture(
    window_id: int,
    expected_pid: int,
) -> tuple[Image.Image, int] | None:
    """Validate window ownership, re-resolve if stale, then capture.

    Returns (image, validated_window_id) or None if no valid window found.
    """
    valid_wid = window_id

    if not skylight.validate_window_owner(window_id, expected_pid):
        logger.info(
            "[screenshot] Window %d no longer belongs to pid %d, re-resolving",
            window_id, expected_pid,
        )
        # Re-resolve from window list
        candidates = [
            w for w in list_windows(owner_pid=expected_pid)
            if w.onscreen and w.width > 0 and w.height > 0
        ]
        if not candidates:
            return None
        # Pick the largest window (most likely the main one)
        candidates.sort(key=lambda w: w.width * w.height, reverse=True)
        valid_wid = candidates[0].window_id

    image = capture_window(valid_wid)
    if image is None:
        return None

    return (image, valid_wid)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/test_screenshot.py -v`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add app/_lib/screenshot.py tests/test_screenshot.py
git commit -m "feat: validate window ownership before screenshot capture"
```

---

### Task 11: Session integration

**Files:**
- Modify: `app/session.py`
- Test: `tests/test_session.py` (update existing tests)

Wire everything together: per-session event source, delivery confirmation tap, unified verifier, snapshot validation. This is the largest task but all the building blocks are in place.

- [ ] **Step 1: Add event source and delivery tap to AppSession**

In `app/session.py`, modify the `AppSession` dataclass (line 219) to add:

```python
    event_source: Any = field(default=None, repr=False)
    delivery_tap: Any = field(default=None, repr=False)  # DeliveryConfirmationTap
```

- [ ] **Step 2: Create/destroy event source in session lifecycle**

In `SessionManager._setup_observer` (line 316), after creating the `InputStrategy`, add:

```python
from app._lib.input import create_event_source
from app._lib.delivery_tap import DeliveryConfirmationTap
from Quartz import CGEventSourceGetSourceStateID

session.event_source = create_event_source()
source_state_id = CGEventSourceGetSourceStateID(session.event_source)
session.delivery_tap = DeliveryConfirmationTap(expected_source_state_id=source_state_id)
session.delivery_tap.start()
```

In `SessionManager._teardown_observer` (line 438), add:

```python
if session.delivery_tap is not None:
    session.delivery_tap.stop()
    session.delivery_tap = None
session.event_source = None
```

- [ ] **Step 3: Thread event source through action handlers**

In `_handle_press_key` (line 2945), replace the direct `cg_input.press_key(pid, key)` call with delivery pipeline usage:

```python
from app._lib.input import deliver_key_events
from app._lib.keys import parse_key_combo

keycode, modifiers = parse_key_combo(resolved_key)
result = deliver_key_events(
    pid=input_pid,
    keycode=keycode,
    modifiers=modifiers,
    source=session.event_source,
    delivery_method=session.input_strategy.delivery_method,
    confirmation_tap=session.delivery_tap,
    activation_policy=session.input_strategy.activation_policy,
)
```

Pass `source=session.event_source` to all `cg_input.click_at`, `cg_input.drag`, `cg_input.type_text`, `cg_input.scroll_pid_pixel` calls throughout the action handlers.

- [ ] **Step 4: Wire snapshot validation into _capture_screenshot**

In `SessionManager._capture_screenshot` (line 2495), before calling `screenshot.capture_window`, add window validation:

```python
from app._lib.screenshot import validate_and_capture

result = validate_and_capture(target.window_id, target.pid)
if result is not None:
    image, validated_wid = result
    if validated_wid != target.window_id:
        logger.info("Window ID re-resolved: %d -> %d", target.window_id, validated_wid)
        target.window_id = validated_wid
        session.target = target
```

- [ ] **Step 5: Wire ActionVerifier into action handlers**

In each action handler (`_handle_click`, `_handle_press_key`, `_handle_set_value`, etc.), add pre/post snapshot capture using the `ElementSnapshot` and `ActionVerifier` from `confirmed_verification.py`:

```python
from app._lib.confirmed_verification import ActionVerifier, ElementSnapshot, ExpectedDiff

# Before action:
before = ElementSnapshot(
    value=getattr(node, 'value', None),
    selected=getattr(node, 'selected', False),
    focused_element_id=id(accessibility.get_focused_element(session.target.ax_app, session.tree_nodes)),
    menu_open=session.menu_tracker.menus_open if session.menu_tracker else False,
    child_count=len(node.children) if hasattr(node, 'children') else 0,
)

# After action + settle:
after = ElementSnapshot(...)  # same fields, re-read

diff = before.diff(after)
verdict = ActionVerifier.compute_verdict(
    transport_confirmed=delivery_result.transport_confirmed,
    diff_any_changed=diff.any_changed,
    expected=ExpectedDiff.FOCUS_OR_LAYOUT,  # varies per tool
    fallback_used=delivery_result.fallback_used,
)
```

- [ ] **Step 6: Run full test suite**

Run: `cd /Users/affan/Documents/GitHub/mac-cua && uv run python -m pytest tests/ -v`
Expected: All tests PASS. Fix any failures from the session.py wiring.

- [ ] **Step 7: Commit**

```bash
git add app/session.py app/_lib/input.py
git commit -m "feat: wire confirmed delivery pipeline into session lifecycle"
```

---

## Post-Implementation Checklist

After all tasks complete:

- [ ] Run full test suite: `uv run python -m pytest tests/ -v`
- [ ] Verify no `scroll_system` references remain: `grep -r "scroll_system" app/`
- [ ] Verify no `time.sleep` in event sequences (only in legacy paths pending removal): `grep -n "time.sleep" app/_lib/input.py`
- [ ] Verify MCP tool schemas unchanged: `grep -A5 "def execute" app/server.py`
- [ ] Manual smoke test against Finder, VS Code, Safari, Music, Notes
