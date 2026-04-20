# Confirmed Delivery Pipeline

**Date:** 2026-04-20
**Status:** Approved
**Scope:** Incremental retrofit of input delivery, verification, snapshot integrity, and state isolation

## Problem Statement

The current input subsystem has four classes of failure:

1. **Input delivery unreliable.** `CGEventPostToPid` doesn't reach Electron, webview, Java, or Qt apps reliably. VS Code clicks/scrolls/key presses produce no effect. Multi-key shortcuts (`shift+cmd+s`) send a single compound event instead of discrete modifier sequences, which non-Cocoa apps reject.

2. **Snapshot desync.** `get_app_state` can return an AX tree from one app with a screenshot from another. Window ID caching goes stale when IDs are recycled or windows are recreated.

3. **Verification lies.** Two independent monitors (AX outcome, CGEvent transport) contradict each other. Actions report failure when state changed, and success when nothing happened.

4. **State leakage.** One shared `CGEventSource`, global mouse event numbering, and shared cursor position mean events from one app session can corrupt another.

## Constraints

- **Tool interface frozen.** MCP tool schemas, parameters, return types, tree serialization, screenshot format, ToolResponse structure, and guidance injection are unchanged. Only internals change.
- **Background-only.** All primary delivery is truly background. No window activation, no focus steal, no cursor movement. Micro-activation (Section 5) is a last-resort retry path with a hard 10ms budget, never the first attempt.
- **macOS 13+ (Ventura).** SkyLight SPIs are stable from Ventura onward.
- **Private SPI tolerance: pragmatic.** SkyLight/CGS private APIs are acceptable. IOKit/Mach port injection is not.
- **Incremental retrofit.** Existing module boundaries preserved. New modules added where needed. No architecture rewrite.
- **Event-driven, zero sleeps.** No hardcoded timing delays within event sequences. Every transition driven by an actual signal (event tap echo, AX observer notification).

## Design

### 1. Event Source Isolation

**Problem:** One shared `CGEventSource` across all sessions allows modifier state, mouse position, and event counters to leak between apps.

**Change:** Each `AppSession` creates its own `CGEventSource` with `kCGEventSourceStatePrivate`.

```
Session("Music")  -> CGEventSource(privateState) -> source_id=0xA1
Session("Finder") -> CGEventSource(privateState) -> source_id=0xA2
```

- **Private state** means modifiers pressed in one source don't affect another. Shift held in Music's session is invisible to Finder's session.
- **Source state ID** is a unique token per source. Posted events carry this ID. The delivery confirmation tap (Section 4) uses it to match echoes to the correct session.
- **Lifecycle:** Source created in `session._setup()`, destroyed in `session._teardown()`. No reuse across sessions.
- **Mouse event numbering** becomes per-source. The global `_MOUSE_EVENT_NUMBER` counter is eliminated.
- **InputStrategy** gains a `source: CGEventSource` field. All event creation uses the session's source instead of `None` (which defaults to the combined HID state).

**Files:** `app/session.py`, `app/_lib/input.py`, `app/_lib/virtual_cursor.py`

### 2. Discrete Modifier Sequences

**Problem:** `shift+cmd+s` is sent as a single `CGEvent(keyDown, keycode=s, flags=shift|cmd)`. Many apps (Electron/Chromium, Java AWT, Qt) expect the real keyboard sequence: separate `flagsChanged` events wrapping the key event.

**Change:** Replace `_post_keycode_with_modifiers(keycode, flags, pid)` with a sequenced emitter.

For `shift+cmd+s`, emit 6 discrete events:

```
1. CGEvent(flagsChanged, shift_keycode,  flags=shift)           -> wait for tap echo
2. CGEvent(flagsChanged, cmd_keycode,    flags=shift|cmd)        -> wait for tap echo
3. CGEvent(keyDown,      keycode=s,      flags=shift|cmd)        -> wait for tap echo
4. CGEvent(keyUp,        keycode=s,      flags=shift|cmd)        -> wait for tap echo
5. CGEvent(flagsChanged, cmd_keycode,    flags=shift)            -> wait for tap echo
6. CGEvent(flagsChanged, shift_keycode,  flags=0)                -> wait for tap echo
```

Details:
- **`flagsChanged` events** are what real keyboards emit for modifier transitions. The `flags` field is cumulative, reflecting the current modifier state after the transition.
- **Unwinding order** is reverse of winding. Last modifier pressed is first released.
- **Each step confirmed** by the delivery confirmation tap (Section 4) before proceeding. No fixed delays.
- **Single keys with no modifiers** (Return, Tab, etc.) skip the `flagsChanged` wrapper. Just keyDown -> confirm -> keyUp -> confirm.
- **The flags field on keyDown/keyUp** still carries the full modifier mask (apps use this for shortcut matching), but now it's preceded by the proper `flagsChanged` ramp-up so apps that inspect event sequences (Chromium) see the full picture.

New pure function in `keys.py`:
```
decompose_modifier_mask(mask) -> List[Tuple[keycode, flag]]
```
Splits a compound mask into ordered individual modifiers (shift=56, control=59, alt=58, cmd=55) with their corresponding flag bits.

**Files:** `app/_lib/input.py`, `app/_lib/keys.py`

### 3. SkyLight SPI Delivery Pipeline

**Problem:** `CGEventPostToPid` goes through the CGEvent tap chain. Electron/Chromium, Java AWT, and some Qt apps ignore PID-targeted events when not frontmost.

**Change:** Add a second delivery pipeline using CoreGraphics Server / SkyLight private SPIs that post events directly into the window server's per-process event queue.

**APIs (via ctypes):**

```python
CGSMainConnectionID() -> cid
    # Our process's window server connection.

CGSGetConnectionIDForPID(cid, target_pid) -> target_cid
    # Target app's window server connection ID.

CGSPostKeyboardEventToProcess(cid, target_pid, keychar, keydown)
    # Keyboard event directly to target's event queue.
    # Bypasses CGEvent tap chain entirely.

CGSPostMouseEventToProcess(cid, target_pid, event_type, point, ...)
    # Mouse event directly to target's event queue.
```

**Integration into InputStrategy:**

| App Type | Click | Keys | Scroll | Delivery |
|----------|-------|------|--------|----------|
| Native Cocoa | AX pref | AX pref | AX pref | CGEventPostToPid |
| Electron | CGEvent | CGEvent | CGEvent pixel | SkyLight SPI |
| Browser (web) | CGEvent | CGEvent | CGEvent pixel | SkyLight SPI |
| Browser (UI) | AX pref | AX pref | AX pref | CGEventPostToPid |
| Java/Qt | CGEvent | CGEvent | CGEvent pixel | SkyLight SPI |

**Fallback chain per delivery attempt (CGEvent/SkyLight-primary actions only — AX-primary actions use AX directly and don't enter this chain):**

```
1. Primary pipeline (from strategy matrix)
   -> delivery confirmed? Done.
2. Alternate pipeline (the other one)
   -> delivery confirmed? Done.
3. If element supports AX equivalent (AXPress, AXSetValue, etc.)
   -> AX observer confirms? Done.
4. Fail with honest error.
```

SkyLight SPIs use the same event model (CGEvent types, keycodes, flags). The discrete modifier sequences from Section 2 work identically over either pipeline. Only the final `post()` call changes.

**New file: `app/_lib/skylight.py`**

Thin ctypes wrapper (~150 lines):
- Loads SkyLight framework at import time
- Resolves function symbols with `ctypes.CDLL`
- Exposes `post_keyboard_event(pid, keycode, keydown)` and `post_mouse_event(pid, event_type, point)`
- Version-gates: checks macOS version at init, raises `UnsupportedPlatformError` if <13
- Falls back gracefully if symbols not found (future macOS renames)

**Files:** `app/_lib/skylight.py` (new), `app/_lib/input.py`, `app/_lib/virtual_cursor.py`

### 4. Delivery Confirmation Loop

**Problem:** Current code sleeps for fixed durations and hopes events landed. No actual confirmation. Actions "succeed" with no effect and "fail" when they worked.

**Change:** Every posted event gets a delivery receipt before the next event is posted. Two confirmation layers:

#### Layer A: Transport Confirmation (event tap echo)

Each session installs a listen-only `CGEventTap` at `kCGSessionEventTap`. Posted events are tagged with the session's source state ID. The tap watches for matching events:

```
post(event, source=session.source)
  -> event enters system with source_state_id=0xA1
  -> tap callback sees event with source_state_id=0xA1
  -> signal: threading.Event.set()

caller:
  session.transport_confirmed.wait(timeout=0.05)
  if confirmed -> proceed to next event
  if timeout -> retry via alternate pipeline (Section 3)
```

- **Matching:** `CGEventGetIntegerValueField(event, kCGEventSourceStateID)` on the tap side matches against the session's known source ID. No false positives from other sessions or user input.
- **One event tap per session**, not per event. The tap stays installed for the session lifetime. The `threading.Event` is reset/set per posted event.
- **50ms timeout is a failure signal**, not a delay. Real delivery takes <1ms. Timeout means the event genuinely didn't make it.

#### Layer B: Semantic Confirmation (AX observer)

Transport confirmation proves the event reached the app's event queue. The AX observer proves the UI reacted:

```
Before action:
  Register AXObserver for target element:
    - AXValueChanged
    - AXFocusedUIElementChanged
    - AXSelectedRowsChanged
    - AXLayoutChanged
    - AXMenuOpened / AXMenuClosed

After transport confirmed:
  semantic_confirmed.wait(timeout=0.5)
  if confirmed -> report success + which notification fired
  if timeout -> report "delivered but no observable effect"
```

- **Notification-specific contracts.** Each tool declares expected notifications:
  - `click` on button -> `AXLayoutChanged` or `AXFocusedUIElementChanged`
  - `set_value` on text field -> `AXValueChanged`
  - `press_key("cmd+w")` -> `AXUIElementDestroyed` or `AXLayoutChanged`
  - `scroll` -> transport confirmation only (scroll often doesn't fire AX notifications)
- **Element-scoped.** Observer registered on the specific element or window, not globally. Unrelated changes don't trigger false confirmations.

#### Combined Verdict

| Transport | Semantic | Verdict |
|-----------|----------|---------|
| Confirmed | Confirmed | `CONFIRMED` |
| Confirmed | Timeout | `DELIVERED_NO_EFFECT` |
| Timeout | N/A | `TRANSPORT_FAILED` |
| Timeout (pipeline A), Confirmed (pipeline B retry) | Confirmed | `CONFIRMED_VIA_FALLBACK` |

**Files:** `app/_lib/event_tap.py`, `app/_lib/verification.py` (new), `app/session.py`

### 5. Background Delivery with Invisible Micro-Activation

**Default:** All events delivered in background. No activation, no focus steal, no visible change. This is the common path.

**Micro-activation:** For interactions that provably require the target app to consider itself "active" — but only as a retry after background delivery fails.

**Mechanism:**

```python
SLSGetConnectionIDForPID(cid, target_pid) -> target_cid
SLSConnectionSetProperty(cid, target_cid, "SetFrontmost", kCFBooleanTrue)
  ... post event ... wait for delivery confirmation ...
SLSConnectionSetProperty(cid, target_cid, "SetFrontmost", kCFBooleanFalse)
SLSConnectionSetProperty(cid, original_cid, "SetFrontmost", kCFBooleanTrue)
```

This flips the window server's internal "frontmost" flag for the connection:
- **No window ordering change.** `SLSOrderWindow` is never called.
- **No visual change.** No title bar highlight, no dock bounce, no menu bar swap.
- **Sub-millisecond.** Completes before the next display refresh.

**Rules:**

1. **<10ms hard budget.** Flag set -> event post -> flag restore must complete within 10ms. Monotonic clock check enforces this. If exceeded, restore immediately and abandon.

2. **Retry path only, never first attempt.** Delivery flow:
   ```
   Background delivery (primary pipeline)
     -> confirmed? Done. Never micro-activate.
     -> transport failed?
       -> Qualified action type? (see below)
         -> Yes: retry WITH micro-activation
         -> No: report TRANSPORT_FAILED
   ```

3. **Qualified actions only:**
   - Popup/menu interactions (AXShowMenu, context menus)
   - Keyboard shortcuts on Electron/Java/Qt
   - Secondary actions that failed background delivery
   
   Regular clicks, typing, set_value never get micro-activation. If they fail background, they fail honestly.

4. **Safety:** `try/finally` guarantees restore. Watchdog at 10ms force-restores if confirmation loop hangs. If `SLSConnectionSetProperty` fails (sandboxed app, SIP), fall back to pure background and report `DELIVERED_NO_EFFECT`.

**Strategy matrix — activation column:**

| Action | Native Cocoa | Electron | Browser (web) | Java/Qt |
|--------|-------------|----------|---------------|---------|
| AX click (AXPress) | none | none | none | none |
| CGEvent click | none | retry | retry | retry |
| Key shortcut | none | retry | retry | retry |
| Single key press | none | retry | none | retry |
| Scroll | none | retry | retry | retry |
| AXShowMenu | none | retry | none | none |
| Popup interaction | retry | retry | retry | retry |
| AXSetValue | none | none | none | none |

"retry" = micro-activation only on retry after background delivery failed. "none" = never.

**Files:** `app/_lib/skylight.py`, `app/_lib/input.py`

### 6. Snapshot Integrity

**Problem:** Cached window ID goes stale. Screenshot captures the wrong window. AX tree and screenshot can be out of sync if the app changes between the two fetches.

#### Window ID Validation

Before every screenshot capture, validate ownership:

```python
SLSGetWindowOwner(cid, cached_window_id) -> owner_cid
SLSGetConnectionIDForPID(cid, target_pid) -> expected_cid
if owner_cid != expected_cid:
    discard cached_window_id
    re-resolve from CGWindowListCopyWindowInfo(filter by target_pid)
    update session.target.window_id
```

**Why IDs go stale:** App closed and another reused the ID. Window destroyed and recreated (tab tear-off, document close/reopen). Multiple windows and wrong one cached.

#### Atomic Snapshot Capture

Current pipeline: fetch AX tree -> capture screenshot. If the app changes between steps, they're out of sync.

New pipeline:

```
1. Validate window ID
2. Register AXObserver for AXLayoutChanged on target window
3. Capture screenshot
4. Fetch AX tree
5. If AXLayoutChanged fired between steps 3 and 4:
     -> retry from step 3 (max 2 retries)
6. Package tree + screenshot as atomic snapshot
```

The AXLayoutChanged observer acts as a dirty flag. If the UI changed during capture, we know and retry.

**Files:** `app/_lib/screenshot.py`, `app/_lib/skylight.py`, `app/session.py`

### 7. Unified Verification System

**Problem:** Two independent monitors contradict each other.

**Change:** Replace both with a single `ActionVerifier`. Three phases:

#### Phase 1: Pre-action snapshot

```python
before = {
    element_value: AXValue of target element,
    element_selected: AXSelected state,
    focused_element: AXFocusedUIElement of window,
    menu_open: MenuTracker.is_open,
    child_count: len(target.children)
}
```

Captured synchronously before the action fires.

#### Phase 2: Delivery confirmation

From Section 4. Transport confirmed -> proceed. Transport failed -> report `TRANSPORT_FAILED`.

#### Phase 3: Post-action diff

After AX observer signal (or timeout):

```python
after = { same fields }
diff = {
    value_changed: before.element_value != after.element_value,
    selection_changed: before.element_selected != after.element_selected,
    focus_changed: before.focused_element != after.focused_element,
    menu_toggled: before.menu_open != after.menu_open,
    layout_changed: before.child_count != after.child_count
}
```

#### Per-tool expected diffs

| Tool | Expected diff |
|------|--------------|
| `click` on button | focus_changed OR layout_changed |
| `click` on row | selection_changed |
| `set_value` | value_changed |
| `press_key` shortcut | layout_changed OR menu_toggled |
| `type_text` | value_changed |
| `scroll` | transport confirmation only |
| `perform_secondary_action` | action-dependent (menu_toggled for ShowMenu, value_changed for Increment) |

#### Verdict mapping to tool response

- `CONFIRMED` / `CONFIRMED_VIA_FALLBACK` -> success
- `DELIVERED_NO_EFFECT` -> success with note (event reached app, app chose not to react)
- `TRANSPORT_FAILED` -> error

No tool interface change.

**Files:** `app/_lib/verification.py` (new), `app/session.py`

### 8. Scroll Overhaul

**Problem:** Three scroll methods, none universal. `scroll_system()` warps the cursor (violates background-only).

**Change:** Kill `scroll_system()` entirely. Two remaining methods:

#### Method 1: CGEvent pixel scroll (via CGEventPostToPid or SkyLight SPI)

```python
event = CGEventCreateScrollWheelEvent(source, kCGScrollEventUnitPixel, 1, 0)
CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, delta_y)
CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, delta_x)
CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, float_delta_y)
CGEventSetLocation(event, target_point_in_screen_coords)
```

Fixes over current:
- **Both integer and fixed-point delta fields set.** Cocoa reads `FixedPtDelta`, Chromium reads integer deltas. Set both always.
- **Event location set to scroll target point.** Apps use this for hit-testing which scrollable view receives the event.
- **Session's isolated event source.** No leakage.
- **Micro-activation for Electron/browser/Java** on retry path.

#### Method 2: AX scroll action (native Cocoa only)

```python
AXUIElementPerformAction(element, kAXScrollAction)
# or for scrollable areas:
AXUIElementSetAttributeValue(element, kAXScrollPositionAttribute, new_position)
```

Only works on native Cocoa scroll views that implement AX scroll protocol.

#### Strategy

| App Type | Primary | Fallback |
|----------|---------|----------|
| Native Cocoa | AX scroll | CGEvent pixel |
| Electron | CGEvent pixel + micro-activation (retry) | SkyLight SPI + micro-activation (retry) |
| Browser (web) | CGEvent pixel + micro-activation (retry) | SkyLight SPI + micro-activation (retry) |
| Java/Qt | CGEvent pixel + micro-activation (retry) | SkyLight SPI + micro-activation (retry) |

**Scroll amounts:** `amount=1` (default) maps to 80 pixels (~3 lines of text), the standard trackpad scroll quantum. No more arbitrary `_SCROLL_LINE_DELTA = 5`.

**Files:** `app/_lib/input.py`, `app/_lib/virtual_cursor.py`

## Module Map

| File | Change Type | Summary |
|------|------------|---------|
| `app/_lib/skylight.py` | New | ctypes wrapper for SkyLight/CGS SPIs (~150 lines) |
| `app/_lib/verification.py` | New | `ActionVerifier` — pre-snapshot, delivery confirmation, post-diff, verdict (~200 lines) |
| `app/_lib/input.py` | Modify | Discrete modifier sequences, per-source events, remove `scroll_system()`, remove hardcoded sleeps, `deliver()` function with pipeline selection |
| `app/_lib/keys.py` | Modify | Add `decompose_modifier_mask()` pure function |
| `app/_lib/virtual_cursor.py` | Modify | `InputStrategy` gains `delivery_method` and `activation` columns, `BackgroundCursor` uses session source |
| `app/_lib/event_tap.py` | Modify | Per-session delivery confirmation tap (listen-only, source ID matching) |
| `app/_lib/focus.py` | Modify | Remove activation/restore logic |
| `app/_lib/screenshot.py` | Modify | Window ID validation before capture |
| `app/session.py` | Modify | Session creates/destroys isolated event source, atomic snapshot, `ActionVerifier` replaces dual monitors |
| `app/server.py` | No change | |
| `app/response.py` | No change | |
| `main.py` | No change | |

## End-to-End Flow

Example: `click(app="VS Code", element=14)`

```
 1. SessionManager.execute("click", ...)

 2. session.resolve_index(14) -> AXUIElement + metadata

 3. InputStrategy lookup:
    Electron + CGEvent click -> delivery=SkyLight, activation=retry-only

 4. ActionVerifier.pre_snapshot()
    captures: element value, selection, focused element, menu state

 5. deliver(click_events, pipeline=SkyLight, session.source)
    |-- post mouseMoved (with window ID + target coords)
    |-- transport_confirmed.wait(0.05s) <- tap echo
    |-- post mouseDown
    |-- transport_confirmed.wait(0.05s) <- tap echo
    |-- post mouseUp
    |-- transport_confirmed.wait(0.05s) <- tap echo
    |
    |  if any transport timeout:
    |  |-- retry via CGEventPostToPid (alternate pipeline)
    |  |-- still failing + qualified action?
    |  |   |-- micro_activate (< 10ms)
    |  |   |-- retry primary pipeline
    |  |   |-- restore activation (try/finally)

 6. ActionVerifier.await_semantic(timeout=0.5s)
    <- AXObserver fires AXFocusedUIElementChanged
    -> verdict: CONFIRMED

 7. Atomic snapshot:
    |-- validate_window_id(session.target.window_id, target_pid)
    |-- capture screenshot
    |-- fetch AX tree
    |-- if layout changed between capture and fetch -> retry (max 2)

 8. Format ToolResponse (unchanged interface)
    -> tree text + screenshot + metadata
```

## Failure Scenarios & Honest Reporting

| Scenario | What Happens | Tool Response |
|----------|-------------|---------------|
| VS Code button click, SkyLight delivers | Transport confirmed, focus changed | Success |
| VS Code button click, SkyLight timeout, CGEvent timeout, micro-activate retry succeeds | Transport confirmed via fallback | Success |
| Music slider AXIncrement, app silently rejects | Transport confirmed (AX action returned), value unchanged | Success + "delivered but no observable effect" |
| Finder screenshot, window ID stale | Validation catches mismatch, re-resolves, captures correct window | Success (transparent retry) |
| AX tree fetched, app changes, screenshot captured | AXLayoutChanged fires between steps, retry captures consistent pair | Success (transparent retry) |
| All pipelines fail for unknown app | Transport failed on all paths | Error: "could not deliver event to process" |
