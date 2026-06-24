# mac-cua → Swift: Porting Design Document

**Status:** Design study (no implementation). Produced from a full read of the Python codebase (~14,400 LOC, ~30 modules, 8 MCP tools).
**Goal:** Re-implement mac-cua as a native Swift macOS app, preserving every hard-won background-CUA mechanism, and only then layering on native UX (animations, visible ghost cursor, overlays).
**Companion:** [`CODEX_PARITY_CHANGES.md`](./CODEX_PARITY_CHANGES.md) — research-derived backlog to match/beat OpenAI Codex "Computer Use" (the private *SkyComputerUse* helper): verified SPI catalog, the AX-tree-completeness fix for Electron/Chrome, new tools (`batch`/`select_text`/clipboard/`wait`), Vision-OCR fallback, and animation-aware settle. This doc is the contract; that doc is the delta we add to reach Codex-class. Findings from it are folded into §5.1, §5.8, §6, and §9 below.

---

## 0. Why Swift (the short version)

The entire core of mac-cua is already a macOS-native API wrapper routed awkwardly through PyObjC + ctypes. Every `CGEvent*`, `AXUIElement*`, `SCShareableContent`, and private `CGS*`/SkyLight call is a first-class native call in Swift — type-safe, faster, no bridge, no ctypes `__c_void_p__` hacks. We lose **zero** portability (the project is macOS-only already), and we *gain* the native UI layer needed for the visible ghost cursor and animations. The risk is not "can Swift do this" — it's "can we preserve the subtle behaviors without regressing the background invariant." This document is about de-risking exactly that.

---

## 1. Prime Invariant & Design Goals

These are the acceptance criteria. Every design decision below is justified against them.

### 1.1 The Prime Invariant — Background-First, No Fallbacks

> **The agent must NEVER steal the user's keyboard input, window focus, or mouse cursor. There is no fallback that foregrounds, activates, raises, or warps the cursor.**

This is not a feature; it is the product. The Python code enforces it at every seam, and a violation anywhere silently destroys the value proposition. Concretely it means:

- Input is delivered **per-process** (`CGEventPostToPid`, or the private `CGSPost*EventToProcess`), never via global `CGEventPost`/HID injection.
- The OS cursor is **never** moved — no `CGWarpMouseCursorPosition`, no `kCGEventMouseMoved` posted to a pid. Click targets ride *on* the down/up events plus window-under-pointer hints.
- Apps are **never** activated/raised — **no foregrounding of any kind, including the invisible ≤10 ms `SetFrontmost` micro-activation. The target is never made frontmost, period.** Launch uses `activates=false`; "focus enforcement" is observe-and-log only. There is no activation escape hatch: when no background delivery path works, the action fails honestly (surfaced to the model) rather than foregrounding.
- Capture reads a window's backing store by ID **without** foregrounding it, with the user's cursor excluded from the image.
- When the user touches the app the agent is driving, the agent **yields** (interruption monitor → tells the model to stop and re-read state).

### 1.2 Secondary Goals

| Goal | What it means | Where it lives |
|---|---|---|
| **Resilient** | Missing private SPI, lost AX ref, stale window-id, occluded window → degrade gracefully, never crash, never fall back to foregrounding. | per-symbol SPI resolution; retry policies; stale-node recovery |
| **Failproof** | Every tool call returns *something useful* to the model — on error, return a fresh snapshot with an explanatory hint, not a bare exception. | `execute()` error pipeline; `_try_snapshot_or_error` |
| **Accurate** | The element the model picked is the element acted on, even after the tree changed; verification distinguishes "delivered, no effect" from "not delivered". | `RefetchableTree` + `GraphLocator`; transport≠outcome verification |
| **Token-light** | Don't overload the agent: prune the AX tree aggressively, cap pathological sizes with *explicit* truncation notices, compress every string field, downscale screenshots. | `pruning.py`; transport image sizing; transient fast-path |
| **Out of the way** | Reactive-only focus handling; sub-second settles; yield on user interaction. | `focus.py` monitors; event-driven settle |

---

## 2. System Overview (what we are porting)

```
MCP client (Claude/agent)
        │  stdio (JSON-RPC)
        ▼
  server.py ── 8 tools, 150s timeout, ToolResponse → MCP text+image
        │
        ▼
  SessionManager.execute()  ◄── the integration spine (session.py, 3803 LOC)
        │
        ├─ resolve target  (app/window_id → pid → ax_app/ax_window → CG window_id)
        ├─ resolve element (element_index → Node via RefetchableTree)
        ├─ deliver input    (CGEventPostToPid / AX action / SkyLight SPI)
        ├─ settle           (event-driven wait-for-quiet, not sleep)
        ├─ snapshot         (walk AX → prune → screenshot → serialize, indices stable)
        └─ assemble + restore previous frontmost
```

**The 8 tools:** `list_apps`, `get_app_state`, `click`, `drag`, `press_key`, `type_text`, `set_value`, `scroll`, `perform_secondary_action`. (`get_app_state` is pure capture; `set_value`/`perform_secondary_action` are pure-AX; `drag` is pure-CGEvent; the rest are hybrid with an AX-first or pointer-first order chosen by `InputStrategy`.)

---

## 3. The Non-Negotiable Invariants (port checklist)

Distilled from every subsystem. A Swift port that violates any of these has regressed the product. **This list is the single most important artifact in this document.**

### Input delivery
1. **Only `CGEvent.postToPid(_:)`** for synthetic events. Never `post(tap:)` / global posting.
2. **No cursor warp, ever.** No `CGWarpMouseCursorPosition`, no mouse-move event posted to a pid. Click target = the event's `mouseCursorPosition` + `.mouseEventWindowUnderMousePointer(ThatCanHandleThisEvent)` set to the target window id.
3. **Modifiers as flags on the key event** (`event.flags`), *not* discrete `flagsChanged` posted via `postToPid` — discrete modifier events leak into the user's global modifier state and corrupt their physical keyboard. (Discrete modifiers are only safe on the SkyLight path.)
4. **Per-session private `CGEventSource(stateID: .privateState)`**; confirm delivery by matching `.eventSourceStateID` (field 45) on the tap echo, so the agent never confuses user input with its own.
5. **Confirmation/monitoring taps are listen-only.** Never suppress or modify user events.
6. **Dual scroll deltas:** set both integer `pointDelta` (Chromium/Electron) and double `fixedPtDelta` (native Cocoa) axes.

### Accessibility / tree
7. **Reads never activate.** `AXUIElementCreateApplication(pid)` + copy/read APIs only; no setting `AXMain`/`AXFocused` window, no `AXRaise`, during reads.
8. **AX refs never reach the model.** `ax_ref`, `graph_id`, `graph_generation`, `graph_locator` stay internal; scrub any leaked `<AXUIElement 0x…>` strings.
9. **OOP detection by PID comparison** (`AXUIElementGetPid` vs target). Downstream behavior keys on `is_oop`.
10. **AX errors `-25205` / `-25212` = stale-reference signal** → trigger recovery, not hard failure.
11. **Write/action ops are PID-scoped, ref-counted assertions** wrapped in try/finally — the count must always balance.
12. **Preorder, reverse-push DFS** flat-list ordering with monotonic `depth`; pruning/indexing/recovery all depend on it.

### Capture / apps / focus
13. **Capture targets a window by id and reads its backing store** via SCK `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage` (captures *occluded/background* windows with no activation, hardware-scaled); private `CGSHWCaptureWindowList` is the fallback — `CGWindowListCreateImage` returns **NULL on macOS 26** (do not rely on it). No activation in the capture path; `showsCursor = false`.
14. **Launch with `activates = false`** (+ `open -g` fallback). Never `NSRunningApplication.activate` proactively.
15. **Focus "enforcement" is observe-and-log only.** The only re-activation allowed is restoring the *user's* previous frontmost app, never grabbing focus for the target.
16. **On user interaction with the driven app, yield** — surface a one-shot warning telling the model to stop and re-query.

### SkyLight private SPI
17. **Every private symbol is resolved individually and optional.** Missing symbol → `nil` → no-op / "assume correct", never crash, never a focus-stealing fallback.
18. **Micro-activation is FORBIDDEN.** No `SetFrontmost`, no `AXRaise`, no activation at any tier — not even invisible/time-boxed. Drop the `ActivationPolicy` concept, the `deliver_key_events` Attempt-2 retry (`input.py:537-545`), and `WindowUIElement.raise_window`. When background delivery fails, return `transport_confirmed=False` and tell the model to try AX or another element.
19. **`validate_window_owner` returns "assume valid" when it can't validate** — never block an action on a validation it couldn't perform.

### Verification
20. **Transport ≠ outcome.** Confirmed transport + no state change = `DELIVERED_NO_EFFECT`, not a delivery failure. Keep the verdict logic pure and stateless.
21. **Snapshot is ground truth.** The current build deliberately *disables* inline post-delivery event verification for the primary paths (AX lags transport by ~one call → false negatives) and trusts the fresh snapshot instead. **Carry this decision forward; do not "fix" it back.**

### Response
22. **Indices are assigned only at the end of pruning, in pre-order, dense 0..N-1.** The model references elements by this index across calls; `RefetchableTree` keeps it valid. Breaking pre-order or density breaks the model's references.
23. **Token-light by construction:** prune before serialize; cap geometry hints (160); transient fast-path skips screenshot/geometry; truncations are *announced*, never silent.

---

## 4. Target Swift Architecture

### 4.1 Package layout

```
swift/                                  (new branch, swift/ subdir alongside Python)
├── Package.swift
├── Sources/
│   ├── MacCUACore/        ── PURE LOGIC — builds + tests on Linux ✅
│   │   Models · KeyParser · Pruning · TreeGraph · MarkdownWriter · Selection(format)
│   │   Flags · Errors · Retry · Safety(logic) · Verdict(compute_verdict) · InputStrategy
│   │   + protocols: AccessibilityProvider, InputProvider, CaptureProvider,
│   │                AppResolver, SettleMonitor, OutcomeMonitor, FocusObserver
│   ├── MacCUAServer/      ── MCP tools + SessionManager (actor) + response assembly
│   │   depends only on Core protocols → Linux-buildable with mock providers ✅
│   ├── CSkyLightShim/     ── C target: header + module map for private CGS/SkyLight SPIs 🍎
│   ├── MacCUAKit/         ── REAL macOS implementations of the Core protocols 🍎
│   │   Accessibility · Input(CGEvent) · Capture(SCKit+CGWindowList) · Apps(NSWorkspace)
│   │   Focus · Observers(AXObserver+CFRunLoop) · SkyLight · Verification · Cursor · Overlay(NEW)
│   └── mac-cua/           ── executable: entrypoint, permissions, MCP stdio loop
└── Tests/
    ├── MacCUACoreTests/   ── XCTest, runs on Linux (port the 270 tests' intent) ✅
    └── MacCUAKitTests/    ── macOS-only integration tests 🍎
```

### 4.2 The central design move: protocol seams

The Python code already isolates framework calls behind modules and uses **dependency injection** (`RefetchableTree` takes `walk_fn`, `graph_state_getter`, `reopen_fn`; the verdict computer takes injected signals). We keep and formalize this: every macOS-touching capability is a Swift **protocol** defined in `MacCUACore`. `MacCUAServer` depends only on protocols. `MacCUAKit` provides the real implementations; tests provide fakes.

Result: **roughly half the codebase — and the entire orchestration spine — builds and unit-tests on Linux.** Only the thin adapter layer in `MacCUAKit` requires a Mac. This is the core de-risking strategy for a port we cannot fully run locally.

Key protocols:
- `AccessibilityProvider` — `walkTree`, `getKeyWindow`, `performAction`, `setAttribute`, `getElementFrame`, `elementAtPosition`, `nodeFromRef`, `getPid`, `refsEqual`.
- `InputProvider` — `clickAtScreenPoint`, `typeText`, `pressKey`, `scrollPid(_Pixel)`, `drag`, `createEventSource`. **`postToPid` semantics are a hard contract of this protocol.**
- `CaptureProvider` — `captureWindow`, `listWindows`, `getWindowBounds`, `getWindowPid`, `findWindowIdForAXWindow`.
- `AppResolver` — launch/resolve/frontmost (all non-activating).
- `SettleMonitor`, `OutcomeMonitor`, `FocusObserver`, `SkyLightProvider`.

### 4.3 Pure vs framework-bound split (verified per module)

| Module (Python) | Swift target | Purity |
|---|---|---|
| `response.py` (Node/Rect/Point/Size/AppState/ToolResponse) | Core/Models | **Pure** |
| `keys.py` | Core/KeyParser | **Pure** (keycode tables + bit math) |
| `pruning.py` (1377 L) | Core/Pruning | **Pure** (the prize — fully Linux-testable) |
| `graphs.py` | Core/TreeGraph | **Pure** except `_locator_from_ref`, `_refs_equal` (2 leaves → Kit) |
| `refetchable_tree.py` | Core/RefetchableTree | **Pure** (macOS deps injected) |
| `tree.py` (serialize) | Core/Serialize | **Pure** |
| `markdown_writer.py` | Core/MarkdownWriter | Pure logic; needs an `AttributedRun` abstraction (Kit adapter for NSAttributedString) |
| `confirmed_verification.py` | Core/Verdict | **Pure** (`compute_verdict` is stateless) |
| `virtual_cursor.py` (AppType/InputStrategy/policies) | Core/InputStrategy | **Pure** except click/drag delivery + `lsof` sniff |
| `flags.py`, `errors.py`, `retry.py` | Core | **Pure** |
| `safety.py` | Core/Safety | Pure except DNS (`getaddrinfo`) → inject a resolver |
| `observer.py` (DebounceStateMachine, AssertionTracker, settle logic) | Core (logic) + Kit (AXObserver/run loop) | Mixed |
| `accessibility.py` (1021 L) | Kit/Accessibility | **macOS** |
| `input.py`, `event_tap.py`, `delivery_tap.py` | Kit/Input | **macOS** |
| `screenshot.py`, `screen_capture.py` | Kit/Capture | macOS (sizing/classifier/scorer logic is pure) |
| `apps.py` | Kit/Apps | macOS (plist/lsappinfo parsing is pure) |
| `focus.py` | Kit/Focus | macOS (debounce/menu state machines are pure) |
| `skylight.py` | Kit/SkyLight + CSkyLightShim | **macOS, private SPI** |
| `selection.py` | Kit/Selection | macOS (`format_selection` is pure) |
| `session.py` (3803 L) | Server/SessionManager | Orchestration pure; all effects behind protocols |
| `server.py`, `main.py` | mac-cua executable | MCP (Swift MCP SDK) |

---

## 5. The Hard Problems (and how we solve them)

These are the parts that will actually consume the engineering effort. Everything else is mechanical translation.

### 5.1 SkyLight / CGS private SPIs — the hardest part

The Python loaded CGS-prefixed symbols off the **CoreGraphics** dylib via ctypes. **Correction from later research:** the `CGSPost*EventToProcess` per-PID input symbols are *removed in macOS 26*, and the modern, confirmed-working background-delivery path is the SkyLight **`SLEvent`/`SLS` family** (loaded from `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`; verified against a second independent implementation on current macOS). The Swift port targets that family; CGS is kept only for stable connection/owner queries.

**Connection / owner queries (stable):**

| Symbol | Role |
|---|---|
| `CGSMainConnectionID()` | our window-server connection (mandatory) |
| `SLSGetWindowOwner(cid, wid, *out)` | window → owner connection |
| `SLSGetConnectionPSN(cid, *psn)` | owner connection → `ProcessSerialNumber` (8 bytes) |
| `CGSConnectionGetPID(cid, *pid)` | connection → PID (macOS-26 owner validation) |

**Per-PID delivery — modern SkyLight family (primary on current macOS):**

| Symbol | Role |
|---|---|
| `SLEventPostToPid(pid, event)` | post a `CGEventRef` to a pid (mouse / scroll) |
| `SLEventSetIntegerValueField(event, 40, pid)` | stamp **field 40 = target pid** |
| `CGEventSetWindowLocation(event, pt)` | window-local coords — **a SkyLight export, not CoreGraphics** |
| `SLSEventAuthenticationMessage +messageWithEventRecord:pid:version:` → `SLEventSetAuthenticationMessage(event,msg)` | authenticate keyboard events before delivery |
| `CGEventPostToPSN(psn, event)` (CoreGraphics) | secondary keyboard/scroll delivery to the owner PSN |

**Removed / forbidden:**

| Symbol | Status |
|---|---|
| `CGSGetConnectionIDForPID`, `CGSPostKeyboardEventToProcess`, `CGSPostMouseEventToProcess` | **removed in macOS 26** — never a hard dependency |
| `CGSSetConnectionProperty(... "SetFrontmost" ...)` | micro-activation — **DO NOT PORT (Invariant 18)** |

**Swift approach — `CSkyLightShim` C target:** a `module.modulemap` + header that `extern`-declares the stable symbols (`CGSMainConnectionID`, `SLSGetWindowOwner`, `SLSGetConnectionPSN`, `SLEventPostToPid`, `SLEventSetIntegerValueField`, `CGEventSetWindowLocation`, `CGEventPostToPSN`) with exact prototypes; resolve `SLSEventAuthenticationMessage` via the ObjC runtime. Swift calls them with native `CGPoint`/`CFString`/`kCFBooleanTrue` — the ctypes/PyObjC `__c_void_p__` bridge disappears.
- Resolve each symbol via `dlopen`+`dlsym` into `unsafeBitCast` C function pointers; a `nil` result = "symbol absent" ⇒ fall through to `CGEventPostToPid` (always-available primary for native apps), never crash, never foreground. Keep `isAvailable` **dynamic** (re-evaluated, test-patchable) behind the `SkyLightProvider` protocol.
- Build targeted mouse events **NSEvent-backed** (`+[NSEvent mouseEventWithType:…windowNumber:…].CGEvent`, with `NSApplication.activationPolicy = .accessory` to stay out of the Dock) for well-formed window association; stamp `kCGMouseEventSubtype(7)=3`, `WindowUnderMousePointer(91)`/`…ThatCanHandle(92) = windowId`.
- **Do NOT port `micro_activate` / `SetFrontmost`** (Invariant 18). SkyLight is used only for owner *validation* and per-PID *delivery*.

> Exact symbols, frameworks, signatures, and CGEvent field numbers (scroll axes line `11/12` · fixedPt `93/94` · pointDelta `96/97` · `isContinuous 88` · source-state-id `45`) are catalogued in [`CODEX_PARITY_CHANGES.md`](./CODEX_PARITY_CHANGES.md) Appendix.

### 5.2 C callbacks for CGEventTap and AXObserver

Both `CGEvent.tapCreate` and `AXObserverCreate` take **`@convention(c)` callbacks that cannot capture Swift context.** Python sidesteps this with PyObjC bound methods (taps) and a global `id()`-keyed dict (observers).

In Swift, the *clean* solution is better than Python: pass the wrapper instance through the `userInfo`/`refcon` opaque pointer (`Unmanaged<T>.passUnretained(self).toOpaque()`), and in the top-level C callback do `Unmanaged<T>.fromOpaque(refcon).takeUnretainedValue()`. **No global registry, no lock.** This removes an entire class of Python indirection (`observer.py:146` global dict).

### 5.3 AX observers are NOT a correctness dependency (known-unreliable)

**Confirmed by the maintainer and visible in the code: `AXObserver`-based notifications are buggy and do not fire reliably** — especially for background windows, WebKit/Chromium web content, and Electron, which is exactly our operating envelope. `AXObserverCreate` can silently fail (`observer.py:187`); `AXCreated`/`AXUIElementDestroyed` rely on app-dependent bubbling; `wait_for_settle`'s notification swap is racy (`observer.py:762-806`).

The dangerous failure is the **false negative**: no notification fires → `TreeInvalidationMonitor.is_invalidated` stays `false` → `RefetchableTree` returns a **stale cached node** (acts on wrong/dead element) and `wait_for_settle` returns `NO_CHANGE` early (snapshot taken before the UI settled). Both silently corrupt accuracy.

**The tell in the existing codebase:** every tracker that actually works avoids `AXObserver` — `UserInteractionMonitor` uses a CGEventTap, `WindowOrderingObserver` polls `CGWindowList`, and `selection.py::FocusedElementObserver` **polls** `AXFocusedUIElement` every 100ms instead of subscribing. The team already routed around AX notifications with polling.

**Port decision — do NOT port `AXObserver` as a correctness mechanism.** Build correctness on synchronous, reliable primitives; `AXObserver` may only ever be an optional latency optimization layered on top, never the gate.
1. **Settle by observation, not notification.** Poll a cheap tree fingerprint (window child-count + focused-element id + targeted element's value) every ~30–40 ms until two consecutive polls match, bounded by the existing per-tool `SETTLE_TIMEOUTS`. Formalize this as an **animation-aware debounce state machine** (Codex ships `DebounceStateMachine` + animation-aware capture): require *N* ms of quiet, treat changing frame rects as in-flight animation and keep waiting, with a hard cap + early-exit — **never a fixed sleep** (the 500 ms VM-CUA tax). The state machine is pure logic (Linux-testable).
2. **Liveness-checked, always-rematched resolution.** Before acting on a cached ref, read one attribute; AX `-25205`/`-25212` ⇒ stale ⇒ re-walk + rebind via `GraphLocator`. Drop the `is_invalidated` gate; re-walk + locator match is the source of truth.
3. **Transient/menu detection by snapshot tree-scan** (menu/sheet/popover roles), not `AXMenuOpened/Closed`.
4. **Keep what works:** CGEventTaps (user-interruption, delivery confirmation) and NSWorkspace frontmost notifications.

This makes the Swift port *more* reliable than the Python original. The `CFRunLoop` thread (a dedicated `Thread` running `CFRunLoopRun()`) is still needed for the CGEventTaps we keep, but not for tree correctness.

This supersedes Invariant 10's "notification-driven" implication: stale detection is **liveness-check + re-walk**, not the invalidation flag.

### 5.4 Concurrency model — actors

Python got serialization for free (sequential tool calls + GIL); there is no lock around `_sessions`. In Swift:
- `SessionManager` → **`actor`** (sole owner of `_sessions` / `_bundle_to_window`). The MCP handler `await`s its methods.
- `AppSession`, `AppTarget` → `final class` (hold live AX/CG handles, mutated in place), confined to the actor.
- `Node`, `ToolResponse`, `AppState`, geometry, verdicts → `struct` value types.
- The AX/CG/SCK calls are synchronous C APIs; run them inside the actor or hop to a dedicated capture queue. SCK's completion-handler APIs collapse to `async`/`await` (drop the Python `threading.Event` + timeout wrappers; use `Task` timeouts).
- Per-failure counters (SCK circuit breaker) → small `actor`s.

### 5.5 AXValue / CFType bridging

Swift makes this *easier* than Python, and we should delete Python's defensive cruft:
- Unbox point/size/range with `AXValueGetValue(v, .cgPoint/.cgSize/.cfRange, &out)`; **drop the regex string-parsing fallbacks** (they existed only because PyObjC sometimes failed to bridge `AXValue`).
- Detect AX-error entries in batch reads via `AXValueGetType(v) == .axError` (proper SPI) instead of Python's string-sniffing hack.
- Use `.takeRetainedValue()` for Copy-named calls (they return +1). Compare AX refs with `CFEqual`, never `===`.
- Box values to *set* with `AXValueCreate(.cgPoint/.cfRange, &v)`; prefer `AXValue`-typed ranges over `NSValue` for AX setters.

### 5.6 The pruning pipeline (token-light correctness)

`pruning.py` is pure but subtle. Port notes that matter:
- Keep the **flat pre-order array + depth** representation; reconstruct parent/child from depth on demand. This is load-bearing.
- Port `_build_tree_index_excluding`'s **upward-walk reparenting** exactly (full parent chain first, then climb to nearest *kept* ancestor). The naive depth-rebuild adopts a removed wrapper's children to the wrong sibling — documented bug.
- Assign `index` **only in the final reindex**, in array order, dense 0..N-1; keep the `old_to_new` remap for collapse metadata.
- `cap_web_area_nodes` keeps the **newest 300** descendants (tail-biased, e.g. latest chat messages) and appends "(N earlier elements truncated)" — relies on depth-contiguity of the pre-order list.
- `flatten_outline_rows` is the most fragile pass (dense, order-sensitive label/value/state merging) → port literally, cover with golden tests.
- Prefer the Codex pipeline's **parent-chain depth recomputation** over the main pipeline's delta-adjust when standardizing.
- Model `Node` as a `final class` (passes mutate in place) or `struct` in an `inout` array; recursion depth ≤ 30 (cap) so no stack risk.

### 5.7 macOS 26 SPI removals — resilience design

Several CGS input/connection SPIs are removed in macOS 26. The architecture already anticipates this (per-symbol optional + dual validation strategies + AX-first delivery for many ops). The port must:
- Treat SkyLight delivery as an *optimization for non-Cocoa apps*, with `CGEventPostToPid` as the always-available primary for native apps and a real path everywhere.
- Keep both `validate_window_owner` strategies (PID→cid pre-26, cid→PID 26+).
- Never let a removed symbol become a hard dependency or trigger a foregrounding fallback.

### 5.8 AX-tree completeness for Chromium / Electron (the real "AX-poor" fix)

Chrome, Electron (Slack, VS Code, Discord, Obsidian), and Chromium webviews **do not expose an AX tree until a client requests it.** They build it lazily only when `AXEnhancedUserInterface` (VoiceOver's flag) and/or `AXManualAccessibility` are set `true` on the **AXApplication** element — and **the first walk after setting returns empty** (lazy build). A naive "walk once → empty → give up / OCR" pipeline silently misses every modern app. This was absent from the original plan and is now a top correctness item.

- **On session attach:** set both `kAXEnhancedUserInterfaceAttribute` and `AXManualAccessibility` = `kCFBooleanTrue` on the app element, then **re-walk** (poll a few times / a few hundred ms until non-empty or settle).
- **Caveat:** the enhanced-UI flag makes some apps behave as if a screen reader is active (layout/perf shifts). Make it per-app, remembered, reversible, and logged.
- **Genuine OCR fallback** (Vision `VNRecognizeTextRequest`) is then needed only for truly tree-less surfaces (canvas/games/video/PDF-image) — emit recognized text+bounds as synthetic `source: ocr` nodes merged into the same packet. New `OCRProvider` seam (Phase 5).
- **Bind AX window → CGWindowID** directly with private `_AXUIElementGetWindow(AXUIElementRef, CGWindowID*)` instead of bounds/title matching.

---

## 6. MCP Server Layer

- Use the **official `modelcontextprotocol/swift-sdk`** with the stdio transport (matches today's `stdio_server`).
- Port `TOOL_DEFS` (8 tools) verbatim — same names, same JSON schemas, same descriptions (these are tuned and the model relies on them).
- **Parity additions to the tool surface** (see `CODEX_PARITY_CHANGES.md` §D): `batch` (N actions / one call, stop-on-first-failure, one final snapshot), `wait`, `select_text` (CFRange for simple fields + AXTextMarker for web/rich content), and clipboard read/write. `batch`/`wait` and the select-range resolution are pure spine logic, testable on Linux now; the original 8 stay unchanged.
- Port `format_mcp`: one `TextContent` (header + `<app_state>` wrapper + tree + selection, with `<app_specific_instructions>` guidance injection) + one optional `ImageContent` (PNG).
- Keep the 150 s per-tool timeout and the "always return text, even on error" behavior.
- **Permissions UX** (must replicate, non-blocking): on first tool call, prompt Accessibility (`AXIsProcessTrustedWithOptions([.prompt: true])`) and Screen Recording (`CGRequestScreenCaptureAccess()`); on later calls just check (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess()`). Return the "permissions pending, call again" retry message until granted. Add the explicit AX preflight the Python lacks.

---

## 7. The Ghost Cursor & Animations (the payoff)

**Product requirement:** every app mac-cua is driving gets its **own** translucent ghost cursor, rendered **on that app's window and clipped to it** — one cursor per driven window, never spilling onto another app. Each cursor moves only when *its* agent session moves the logical cursor. N concurrent sessions ⇒ N independent ghost cursors (this is the visible face of the parallel/multi-agent capability). Purely **additive**; it must never touch the Prime Invariant.

### 7.1 Three clean layers (source of truth → delivery → rendering)
- **Logical position (truth):** the per-session `BackgroundCursor` already models this — `moveTo` only updates an internal coordinate; the real OS cursor never moves. One `BackgroundCursor` per `AppSession` (holds `pid` + `windowId`).
- **Background delivery:** CGEvent/SkyLight to the target pid (unchanged).
- **Visible rendering (NEW, decorative):** a per-window overlay that draws the translucent sprite where the logical cursor already is. **Hard rule:** decorative only — never routes through the system cursor, never warps, never foregrounds; `ignoresMouseEvents = true`, non-activating.

### 7.2 One overlay per window, clipped to that window
- Each driven window gets a borderless, transparent, click-through, **non-activating** `NSPanel` (`.nonactivatingPanel`, `ignoresMouseEvents = true`, `canBecomeKey/Main = false`, `collectionBehavior` incl. `.canJoinAllSpaces`/`.stationary`, high `level` e.g. `.screenSaver`).
- The panel frame == the **target window's screen rect** (`CaptureProvider.getWindowBounds(windowId:)`, bound to the AX window via private `_AXUIElementGetWindow`). The sprite is **clamped to the window rect** so it can never render over another app — "specially on that window," per the requirement.
- **Track the window:** follow its frame on move/resize, hide on minimize/close/off-Space, reposition across displays.
- **Occlusion:** MVP clips to the window frame; v2 clips to the window's *visible* region (subtract higher windows via CGS z-order) so the cursor isn't painted over an app covering the target; when the target is fully occluded, hide the cursor.

### 7.3 Multi-cursor identity & animation
- Keyed by `windowId`. A pure `GhostCursorController` (style assignment + `clampPointToWindow` + per-window registry — **Linux-testable**) drives a `GhostCursorOverlay` seam (the AppKit impl). Each session gets a **distinct translucent tint** from a rotating palette so concurrent agents are visually separable.
- Animate via Core Animation: glide ("scoot") to the target on `moveTo(animated:true)`, a click pulse on click, optional "wiggle while thinking." Driven off `BackgroundCursor` position changes (a single chokepoint hook), so every logical move updates the ghost automatically.

### 7.4 Seam & phase split
- **New Core seam** `GhostCursorOverlay` (protocol) + pure `GhostCursorController` (palette + clamp + per-window registry) — Linux-buildable/testable now, exercised with a fake overlay.
- **Phase 4 (drive):** wire `BackgroundCursor` position changes → `GhostCursorController.move(windowId:)` when the Kit write path delivers via the cursor; `startTracking` on session create, `windowMoved` on snapshot, `stopTracking` on teardown.
- **Phase 6 (render):** the AppKit `GhostCursorOverlay` impl (NSPanel per window, CALayer sprite, window-follow, animations). Reference: macos-cua `native/cursor-overlay.m` (non-activating panel, stdin command protocol) — but we render in-process via the seam.
- This is exactly why Swift is worth it: the overlay/animation layer is native and trivial in AppKit/Core Animation, impossible to do well in Python.

---

## 8. Testing Strategy

The existing **270-test suite is the spec.** Port the *intent* first.

- **Linux (CI, fast):** Core modules with fakes — pruning (golden trees in/out), key parsing, graph-locator scoring & refetch (the recovery algorithm), serialization, verdict computation, input-strategy matrix, retry/flags/errors, coordinate math, image-sizing/classifier logic, debounce/menu state machines, SkyLight availability/branch logic (mocked loader).
- **Mac (integration):** AX walking/actions, CGEvent delivery, SCK capture, SkyLight SPI calls, observers/run-loop, the full `execute()` spine against real apps.
- **Golden-test the fragile passes:** `flatten_outline_rows`, `cap_web_area_nodes`, `_build_tree_index_excluding`.
- **Invariant tests:** assert no banned symbol is reachable from the input path (no `CGEventPost`, no `CGWarpMouseCursorPosition`, no `activate`), e.g. via a compile-time/lint guard plus runtime assertions in the providers.

---

## 9. Phased Roadmap

Sized so each phase is independently verifiable; phases 0–2 are fully verifiable on Linux.

| Phase | Scope | Verifiable where |
|---|---|---|
| **0. Scaffold** | `Package.swift`, target layout, MCP SDK dep, green `swift build` of Core on Linux. | Linux |
| **1. Core port** | Models → KeyParser → Pruning → TreeGraph → RefetchableTree → Serialize → Verdict → InputStrategy → Flags/Errors/Retry/Safety, with ported XCTests. | Linux ✅ (the big de-risk) |
| **2. Server skeleton** | 8 tool defs, MCP stdio loop, `SessionManager` actor + `execute()` spine against **mock** providers; full pipeline logic exercised with fakes. | Linux ✅ |
| **3. Kit — read path** | `AccessibilityProvider`, `CaptureProvider`, `AppResolver`, observers/run-loop, permissions → real `list_apps` + `get_app_state`. **+Parity:** AXEnhancedUserInterface/AXManualAccessibility + re-walk (§5.8); `SCContentFilter(desktopIndependentWindow:)` occluded capture; `_AXUIElementGetWindow` binding; rich AX attrs (enabled/focused/selected/min-max); capture metadata. | Mac 🍎 |
| **4. Kit — write path** | `InputProvider` (CGEvent) → SkyLight shim/provider; click/type/key/scroll/drag/set_value/secondary; verification wiring. **+Parity:** real-CGEvent-click fidelity (pointer-first for Chromium); all scroll axes (line+fixedPt+pointDelta); `select_text` (CFRange + AXTextMarker); clipboard; `batch`+`wait`; action-feedback packet (path used / window / cursor before·after). | Mac 🍎 |
| **5. Hardening** | Stale recovery, retries, circuit breaker, interruption, macOS-26 matrix; close gaps vs Python. **+Parity:** Vision-OCR fallback; animation-aware debounce settle; change-summary verdict; safety blocklist (Terminal/SecurityAgent/self) + lock-screen guard; redacted audit. | Mac 🍎 |
| **6. Native UX** | Visible ghost cursor overlay + animations (wiggle-when-thinking, bezier scoot, element highlight — matches Codex's animated virtual cursor); polish. Additive only. | Mac 🍎 |

> **Do-now (Linux, no Mac):** `batch` + `wait` tools, the AX change-summary verdict, the debounce state machine, `InputStrategy` pointer-first for Chromium, `select_text` range-resolution, and the CGEvent field-constant table — all pure logic. See `CODEX_PARITY_CHANGES.md` for the full per-area backlog and SPI appendix. **Stretch:** locked-Mac operation (a Security authorization plug-in — separate signed component).

---

## 10. Risks & Open Questions

- **Private SPI longevity.** The macOS-26 removals are real and confirmed (`CGSPost*EventToProcess`, `CGSGetConnectionIDForPID` gone). Mitigation: AX-first + `CGEventPostToPid` always-available primary; the modern `SLEvent`/`SLS` family is the confirmed background path (§5.1), every symbol optional behind `SkyLightProvider`. *Open:* validate on the target macOS version early (Phase 4); `CGWindowListCreateImage` is already known dead on 26 → SCK / `CGSHWCaptureWindowList` only.
- **Behavioral parity of pruning.** Subtle passes can drift. Mitigation: golden tests captured from the Python output before porting each pass.
- **The "trust transport, snapshot is truth" decision.** Counterintuitive; easy to "accidentally fix" back to inline verification and reintroduce false negatives. Documented here as intentional (Invariant 21).
- **Dual/triple PID handling** (`pid` vs `window_pid` vs element `element_pid`) must survive — it's how XPC-hosted/helper-rendered windows get input. (`_background_pid_for_node`.)
- **MCP Swift SDK maturity.** Confirm stdio transport + the content-block shapes we need in Phase 0.
- **Open question for the user:** do we aim for *behavioral parity first* (port `release` branch as-is) then merge the `confirmed-delivery-pipeline` improvements, or target the experimental pipeline directly? Recommendation: parity-first on `release`, since it has fewer moving parts and a cleaner invariant surface.

---

## 11. Bottom Line

The port is well-scoped because the codebase is already cleanly layered around dependency-injection seams. ~Half of it (and the entire orchestration spine) becomes Linux-testable Swift behind protocols; the macOS-only surface shrinks to a thin, well-understood adapter layer. The genuine engineering is concentrated in four spots — **SkyLight private SPIs, C callbacks for taps/observers, the run-loop/actor concurrency model, and faithful pruning** — all of which have concrete, documented solutions above. The Prime Invariant and the 23-point checklist in §3 are the contract: preserve them and the Swift version is strictly better than the Python one, because the native UI layer (ghost cursor, animations) finally becomes possible without ever compromising background-first operation.
