# PRD: Complete the mac-cua → Swift Port

> **Source of truth:** [`docs/SWIFT_PORT_DESIGN.md`](../docs/SWIFT_PORT_DESIGN.md) (the contract) and [`docs/CODEX_PARITY_CHANGES.md`](../docs/CODEX_PARITY_CHANGES.md) (the Codex/SkyComputerUse parity delta). This PRD turns those into Ralph-loop-sized user stories. When this PRD and the design docs disagree, **the design docs win** — fix this PRD.
>
> **Decisions baked in (from the user):**
> - **Scope:** full port through the visible ghost cursor — Phases 3–6.
> - **Parity target:** the **experimental confirmed-delivery pipeline** directly (transport-confirmation via delivery tap + snapshot-as-truth + `compute_verdict`), not release-parity-first.
> - **Codex parity:** **folded in by phase** — pure-logic "do-now" items land in Core now; Mac extras land in their natural phase.
> - **Mac definition-of-done:** code compiles under `#if os(macOS)` + pure bits are fake-tested; real AX/CGEvent/SkyLight behavior is **flagged `MANUAL-VERIFY`** for a human real-app pass (Ralph cannot drive real apps).

---

## 1. Introduction / Overview

mac-cua is a macOS background computer-use agent (8 MCP tools) whose entire value is the **Prime Invariant**: it drives apps *without ever* stealing the user's keyboard, focus, or cursor — no foregrounding, no fallbacks. It is ~14,400 LOC of Python routed awkwardly through PyObjC + ctypes.

This project re-implements it as a native Swift macOS app. The payoff: every `CGEvent`/`AXUIElement`/SkyLight call becomes a first-class type-safe native call, ~half the codebase (and the whole orchestration spine) becomes Linux-buildable behind protocol seams, and the native UI layer needed for the **visible per-window ghost cursor + animations** finally becomes possible — all without compromising background-first operation.

**Where we are now (Phases 0–2 complete, all Linux-pure, build green, 342 tests passing):**
- `MacCUACore` — Models, KeyParser, Pruning, TreeGraph, RefetchableTree, Serialize, Verdict, InputStrategy, Flags, Errors, Retry, Safety, SHA256Lite, URLParse, and the full `Providers.swift` protocol seam surface.
- `MacCUAServer` — `SessionManager` actor, the `execute()` spine, all current tool handlers, MCP layer, `FormatMCP`, `Permissions`, `ToolDefs` (9 tools) — exercised against **mock** providers.

**What this PRD covers (everything that remains to "complete the migration"):**
1. **Finish the Linux-verifiable layer** (Phase A) — Core/Server gaps + the pure-logic Codex "do-now" backlog. Ralph fully self-verifies these.
2. **Build the macOS adapter layer** (`MacCUAKit`, `CSkyLightShim`, the `mac-cua` executable) — Phases 3–5.
3. **Add the native ghost-cursor / animation UX** — Phase 6.
4. Fold in the Codex/SkyComputerUse parity items (A–M) by phase, and record what is deliberately **out of scope** (M1–M3, K1) so it is not re-litigated.

---

## 2. Goals

- **Preserve the Prime Invariant absolutely.** No `CGEventPost`/global posting, no `CGWarpMouseCursorPosition`, no cursor move, no `activate`/`AXRaise`/`SetFrontmost` micro-activation anywhere in the input or capture path — enforced by tests, not just convention.
- **Honor all 23 non-negotiable invariants** (design §3) — each becomes a functional requirement and/or invariant test below.
- **Reach behavioral parity with the experimental Python pipeline** (the `confirmed_verification` / `action_verification` / `delivery_tap` family), then **beat it** with the Codex-parity additions folded in by phase.
- **Keep the Linux build green throughout** — Core/Server must always `swift build && swift test` on Linux; macOS code lives behind `#if os(macOS)`.
- **Ship the native UX** — one translucent ghost cursor per driven window, clipped to that window, one per concurrent session, animated — additive only, never touching the invariant.
- **Every story is independently verifiable** by Ralph: pure-logic stories gate on green build+test; Mac stories gate on compiling under `#if os(macOS)` + fake-backed unit tests, with a written `MANUAL-VERIFY` note.

---

## 3. The Ralph Operating Model (read before executing)

Ralph executes one user story per focused session and must self-verify. Two story classes, two gates:

- **🟢 Pure-logic story (Core/Server, Linux-buildable).** Definition of done = **`swift build` succeeds AND `swift test` is green** (existing 342 tests stay green + new tests for this story pass). These are fully trustworthy.
- **🍎 Mac-integration story (`MacCUAKit`/`CSkyLightShim`/executable).** Ralph **cannot drive real apps**, so "done" =
  1. Code compiles on macOS (`swift build` with the macOS targets enabled), and Core/Server still `swift build && swift test` green on Linux (code is behind `#if os(macOS)`).
  2. All *pure* helper logic extracted from the story (sizing math, parsing, state machines, range resolution) has **fake-backed unit tests** that pass.
  3. The story carries an explicit **`MANUAL-VERIFY:`** acceptance line naming exactly what a human must confirm against real apps (e.g. "click on background Slack window delivers without foregrounding; user's cursor never moves").
  Ralph marks the story complete when 1–2 hold; the human clears the `MANUAL-VERIFY` line later. **Never** claim a Mac behavior "works" from compilation alone.

**Global gate on every story:** `swift build` green, Core/Server `swift test` green, no banned symbol newly reachable from the input/capture path (see US-012), no AX ref / graph id leaked to the model.

---

## 4. User Stories

Ordered by dependency. Phase A (🟢 pure logic) first — highest confidence, unblocks the spine. Then the Mac phases (🍎) in design-doc order.

### Phase A — Finish the Linux-verifiable layer (🟢 Ralph fully self-verifies)

#### US-001: Port `markdown_writer.py` → `Core/MarkdownWriter`
**Description:** As the serializer, I need rich-text AX content (AXTextArea / web selection) rendered to Markdown so `format_selection` and the rich-text snapshot path match Python.
**Acceptance Criteria:**
- [ ] New `MacCUACore/MarkdownWriter.swift` ports `AttributedStringMarkdownWriter` assembly logic as **pure** functions over an injected `AttributedRun` abstraction (font/trait/link/list runs → Markdown), per design §4.3.
- [ ] `format_selection(text:)` logic ported and wired where `Serialize` / selection formatting needs it.
- [ ] Golden tests: representative run-sequences → expected Markdown, captured from Python output.
- [ ] The NSAttributedString→`[AttributedRun]` adapter is declared as a Kit seam (impl deferred to Phase 4/5), not implemented here.
- [ ] `swift build && swift test` green.

#### US-002: Port `observer.py` pure logic → Core debounce / settle state machine (E1, §5.3)
**Description:** As the settle subsystem, I need an **animation-aware debounce state machine** as pure, Linux-testable logic so settle is by-observation (poll a tree fingerprint), never a fixed sleep.
**Acceptance Criteria:**
- [ ] New `MacCUACore` type `DebounceStateMachine` (pure): consumes (timestamp, tree-fingerprint, key-frame rects) ticks; requires *N* ms of quiet; treats changing frame rects as in-flight animation and keeps waiting; hard cap + early-exit. No sleeps, no clock calls inside (time injected).
- [ ] Port `AssertionTracker` ref-count balance logic (PID-scoped assertions, try/finally semantics) as pure state.
- [ ] The `SettleMonitor` seam is updated to be driven by this machine (the real frame/fingerprint feed is a Kit impl, Phase 3).
- [ ] Tests: quiet-converges, animation-keeps-waiting, hard-cap-fires, assertion-count-always-balances.
- [ ] `swift build && swift test` green.

#### US-003: Post-action AX change-summary verdict (E3) → Core
**Description:** As `compute_verdict`, I need a structured pre/post tree diff so "confirmed transport + zero change = `DELIVERED_NO_EFFECT`" is first-class.
**Acceptance Criteria:**
- [ ] Pure `changeSummary(pre:[Node], post:[Node]) -> {added, removed, changed}` keyed by stable element key.
- [ ] `compute_verdict` consumes it: transport-confirmed + 0/0/0 ⇒ `DELIVERED_NO_EFFECT`; >0 ⇒ confirmed effect.
- [ ] Verdict raw values still match Python (existing `VerdictTests` stay green).
- [ ] Tests cover added-only / removed-only / changed-only / none.
- [ ] `swift build && swift test` green.

#### US-004: Request/turn-scoped cache (L1) → Core
**Description:** As the spine, I want a turn-scoped cache (PID→AppState, name→PID) so `batch` and repeated lookups don't re-walk, per docs §L1.
**Acceptance Criteria:**
- [ ] Pure cache type with request/turn lifetime; `PID→AppState` reused within a turn/batch, `name→PID` reused across calls; explicit invalidation hooks.
- [ ] Distinct from the SCContentFilter cache (§B2, that's Phase 3).
- [ ] Tests: hit/miss/invalidate; a `batch` reuses the pre-action tree instead of re-walking.
- [ ] `swift build && swift test` green.

#### US-005: `select_text` range-resolution (D1, pure tier) → Core
**Description:** As `select_text`, I need content→range resolution (find substring by exact text + prefix/suffix disambiguation → `{location,length}`) as pure logic, ahead of the Mac selection impl.
**Acceptance Criteria:**
- [ ] Pure resolver: given whole text + target substring (+ optional surrounding prefix/suffix), returns the unambiguous `(location,length)` or a typed ambiguity/not-found error.
- [ ] Caret-before / caret-after modeled as zero-length ranges.
- [ ] Tests: unique match, duplicate-needs-disambiguation, not-found, caret placement.
- [ ] `swift build && swift test` green. (Mac CFRange + AXTextMarker impl is US-040.)

#### US-006: CGEvent field-constant table (Appendix) → Core constants
**Description:** As the input layer, I need every CGEvent field number / flag mask / source-state id as named Core constants so the Mac impl can't transpose a magic number.
**Acceptance Criteria:**
- [ ] Core constants for: scroll axes line `11/12/13`, fixedPt `93/94/95`, pointDelta `96/97/98`, `isContinuous 88`, `scrollPhase 99`; mouse `subtype 7`, `windowUnderPointer 91`, `…ThatCanHandle 92`; `eventSourceStateID 45`; SkyLight `field 40 = pid`; source-state `Private=-1`; flag masks Shift/Control/Alt/Cmd; mouse buttons.
- [ ] Tests assert the numeric values match the Appendix exactly.
- [ ] `swift build && swift test` green.

#### US-007: Confirm `InputStrategy` pointer-first for Chromium/Electron (C1)
**Description:** As `InputStrategy`, web/Electron app types must choose **pointer-first** click delivery (AX-first only for native Cocoa controls + menu items), since `AXPress` under-triggers web/JS controls.
**Acceptance Criteria:**
- [ ] Verify/extend `InputStrategy.swift`: Chromium/Electron/web app types → pointer-first; native Cocoa controls + menu items → AX-first.
- [ ] Tests over the app-type × element-type matrix assert the chosen order.
- [ ] `swift build && swift test` green.

#### US-008: `batch` tool (D3) → ToolDefs + spine + handler
**Description:** As the model, I want to send N actions in one MCP call (linear, stop-on-first-failure, one final snapshot) so I save N−1 round-trips.
**Acceptance Criteria:**
- [ ] `batch` tool def added (JSON schema: ordered list of action items); spine executes sequentially, stops on first failure, returns one final snapshot + per-step outcomes.
- [ ] Reuses the turn cache (US-004) for the pre-action tree.
- [ ] Handler tested end-to-end against mock providers: success path, mid-batch failure halts remainder, final snapshot present.
- [ ] `swift build && swift test` green.

#### US-009: `wait` tool (D4) → ToolDefs + spine + handler
**Description:** As the model, I want an explicit settle/wait tool (Codex parity).
**Acceptance Criteria:**
- [ ] `wait` tool def + handler; drives the debounce state machine (US-002) via the `SettleMonitor` seam with the tool's timeout; returns a fresh snapshot.
- [ ] Tested against mock providers (settles, hits cap).
- [ ] `swift build && swift test` green.

#### US-010: Wire `select_text` + `clipboard` tool defs + spine routing
**Description:** As the spine, the two new tool surfaces must exist and route, even though their Mac providers arrive later.
**Acceptance Criteria:**
- [ ] `select_text` tool def (content/prefix/suffix/caret params) → spine calls US-005 resolver, then the `SelectionProvider` seam (mock for now).
- [ ] `clipboard` tool def (get/set/clear) → `ClipboardProvider` seam (mock for now).
- [ ] Handlers tested against fakes; real impls are US-040 / US-041.
- [ ] `swift build && swift test` green.

#### US-011: Action-feedback packet shape (F) → ToolResponse / OutcomeMonitor
**Description:** As the model, after every action I want delivery path used, target window id+title, logical cursor before/after, and the change-summary — so I self-correct instead of flying blind.
**Acceptance Criteria:**
- [ ] `ToolResponse` carries an action-feedback struct: `deliveryPath` (`AXPress|SkyLight|CGEvent|PSN|wheel`), `windowId`+title, `cursorBefore`/`cursorAfter` (logical), change-summary (US-003).
- [ ] `FormatMCP` renders it; assembly tested against fakes.
- [ ] `swift build && swift test` green. (Real population is Phase 4.)

#### US-012: Invariant & anti-regression test guard (§3, §J, M4)
**Description:** As the project, I need automated proof that banned behavior is unreachable and that we don't adopt macos-cua's weaker choices.
**Acceptance Criteria:**
- [ ] Test/lint guard asserting no `CGEventPost(` (global), `CGWarpMouseCursorPosition`, `NSRunningApplication.activate`, `AXRaise`, `SetFrontmost`, `SLPSSetFrontProcessWithOptions` string is reachable from input/capture sources.
- [ ] Guard against M4 regressions: scroll must set >1 delta axis (not integer-only); refetch must use GraphLocator (not "re-walk to same preorder index"); element key must be the graph locator (not `role|label|frame`).
- [ ] Guard: no `ax_ref`/`graph_id`/`graph_generation`/`graph_locator` field nor `<AXUIElement 0x…>` string is serializable into the model packet.
- [ ] `swift build && swift test` green.

#### US-013: Port residual support modules (`analytics`/`tracing`/`lifecycle`/`elicitation`)
**Description:** As the spine, any load-bearing logic in the Python support modules must be ported or **consciously dropped with a note**, so nothing silently goes missing.
**Acceptance Criteria:**
- [ ] Audit `app/_lib/{analytics,tracing,lifecycle}.py` + `app/_lib/elicitation.py`; for each, port the pure logic the spine depends on OR record in this PRD's §9 why it's out of scope (e.g. product telemetry).
- [ ] Elicitation (MCP elicitation prompts) decision recorded: ported to the Swift MCP layer or deferred.
- [ ] `swift build && swift test` green.

---

### Phase B — Scaffold the macOS adapter (🍎 compiles on macOS; Core/Server stay Linux-green)

#### US-014: Add `MacCUAKit` + `CSkyLightShim` targets to `Package.swift`
**Description:** As the build, I need the macOS adapter and C-shim targets to exist and compile, without breaking the Linux build of Core/Server.
**Acceptance Criteria:**
- [ ] `Package.swift`: new `CSkyLightShim` (C target: header + `module.modulemap`) and `MacCUAKit` (depends on Core + CSkyLightShim), both `#if os(macOS)`-guarded / conditionally included so Linux build of Core/Server is unaffected.
- [ ] Empty-but-compiling stubs that conform to the Core provider protocols (throwing/`fatalError("unimplemented")` bodies are fine at this step).
- [ ] **MANUAL-VERIFY:** `swift build` succeeds on macOS with Kit targets enabled.
- [ ] Linux gate: Core/Server `swift build && swift test` green (Kit excluded).

#### US-015: `mac-cua` executable target — MCP stdio entrypoint + permissions preflight
**Description:** As a user, I need a runnable binary that speaks MCP over stdio and wires real providers into `SessionManager`.
**Acceptance Criteria:**
- [ ] Executable target using the official `modelcontextprotocol/swift-sdk` stdio transport; serves the same tool defs.
- [ ] Permissions UX (design §6): first call prompts Accessibility (`AXIsProcessTrustedWithOptions[.prompt:true]`) + Screen Recording (`CGRequestScreenCaptureAccess()`); later calls just check; returns the "permissions pending, call again" retry message until granted; adds the explicit AX preflight Python lacks.
- [ ] `NSApplication` set to `.accessory` activation policy (stay out of the Dock); never activates.
- [ ] **MANUAL-VERIFY:** binary launches, registers with an MCP client, drives the permission prompts once.
- [ ] Linux gate stays green.

---

### Phase 3 — Kit read path (🍎 real `list_apps` + `get_app_state`)

#### US-016: `AppResolver` real impl (non-activating)
**Acceptance Criteria:**
- [ ] NSWorkspace-backed list/resolve/frontmost; launch with `activates=false` (+ `open -g` fallback); save/restore the **user's** previous frontmost only; never proactively `activate`.
- [ ] Pure plist/lsappinfo parsing extracted + fake-tested.
- [ ] **MANUAL-VERIFY:** launching a target app does not bring it to the foreground; user's frontmost app is restored.
- [ ] Linux gate green.

#### US-017: `AccessibilityProvider` walker — preorder reverse-push DFS + PID-scoped actions
**Acceptance Criteria:**
- [ ] `AXUIElementCreateApplication(pid)` + copy/read only; **no** `AXMain`/`AXFocused`/`AXRaise` during reads (Invariant 7).
- [ ] Preorder, reverse-push DFS with monotonic depth (Invariant 12); recursion cap 30.
- [ ] OOP detection by `AXUIElementGetPid` vs target (Invariant 9); write/action ops are PID-scoped ref-counted assertions, try/finally balanced (Invariant 11).
- [ ] AX errors `-25205`/`-25212` surfaced as stale signals (Invariant 10), not hard failures.
- [ ] AXValue unboxing via `AXValueGetValue` (no regex fallbacks); `CFEqual` for ref compare (§5.5).
- [ ] **MANUAL-VERIFY:** walking a real Cocoa app yields a tree whose pruned indices match the Python tool on the same screen.
- [ ] Linux gate green.

#### US-018: Rich AX attribute population (A3)
**Acceptance Criteria:**
- [ ] Walker fills `AXEnabled`, `AXFocused`, `AXSelected`, `AXValue` (+`AXMinValue`/`AXMaxValue`), `AXPlaceholderValue`, `AXRoleDescription`, `AXSelectedText`, position-in-set into `Node`.
- [ ] Batch AX-error entries detected via `AXValueGetType == .axError` (not string-sniffing).
- [ ] **MANUAL-VERIFY:** disabled/focused/selected states appear correctly for a real toolbar + form.
- [ ] Linux gate green.

#### US-019: Enable Chromium/Electron trees — `AXEnhancedUserInterface` + `AXManualAccessibility` + re-walk (A1)
**Acceptance Criteria:**
- [ ] On session attach, set BOTH `kAXEnhancedUserInterfaceAttribute` and `AXManualAccessibility` = `kCFBooleanTrue` on the AXApplication element, then **re-walk** (poll a few times / few hundred ms until non-empty or settle) — first walk after setting is expected empty (lazy build).
- [ ] Per-app, remembered, reversible, logged (caveat: enhanced-UI changes some apps' layout/perf).
- [ ] `AccessibilityProvider.enableEnhancedUI(appRef)` seam.
- [ ] **MANUAL-VERIFY:** Slack / VS Code / Discord / Obsidian expose a non-empty tree after attach.
- [ ] Linux gate green.

#### US-020: Bind AX element → CGWindowID via private `_AXUIElementGetWindow` (A4)
**Acceptance Criteria:**
- [ ] `_AXUIElementGetWindow(AXUIElementRef, CGWindowID*)` resolved per-symbol-optional; used for `findWindowIdForAXWindow` and capture/SkyLight target binding; bounds/title match only as fallback.
- [ ] **MANUAL-VERIFY:** the bound window id matches the actual on-screen window for multi-window apps.
- [ ] Linux gate green.

#### US-021: Text geometry parameterized attributes (A5)
**Acceptance Criteria:**
- [ ] `AXUIElementCopyParameterizedAttributeValue` for `kAXBoundsForRange`, `kAXRangeForPosition`, `kAXVisibleCharacterRange`.
- [ ] **MANUAL-VERIFY:** "where is this text" returns correct on-screen bounds in TextEdit + Safari.
- [ ] Linux gate green.

#### US-022: `CaptureProvider` — occluded single-window capture (B1, B5; Invariant 13)
**Acceptance Criteria:**
- [ ] `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage`; captures **occluded/background** windows with no activation; `showsCursor = false`.
- [ ] `CGWindowListCreateImage` is **not** used (NULL on macOS 26); private `CGSHWCaptureWindowList` only as fallback (US-024).
- [ ] **MANUAL-VERIFY:** a fully-occluded background window is captured correctly, no activation, user's cursor absent from the image.
- [ ] Linux gate green (pure sizing/crop math fake-tested).

#### US-023: Capture metadata + capture-time downscale + latency benchmark (B4, B6, L3)
**Acceptance Criteria:**
- [ ] Emit produced px dims, scale/backing factor, crop origin, window id+title, display id.
- [ ] GPU downscale via `SCStreamConfiguration.width/height` + `scalesToFit`; ImageIO `kCGImageDestinationImageMaxPixelSize` encode; **no** `screencapture`/`sips` shell-out.
- [ ] **MANUAL-VERIFY (L3 benchmark):** measure CGDisplay-window-scoped vs SCK one-shot latency on the target Mac; record numbers; pick the faster path (docs note SCK was ~15–25 ms slower for one-shot).
- [ ] Linux gate green (sizing/downscale math fake-tested).

#### US-024: Capture caching + private GPU fallback (B2, B3)
**Acceptance Criteria:**
- [ ] Cache `SCShareableContent`/`SCContentFilter` per window/display; invalidate on display-config / window-replace.
- [ ] Per-symbol-optional `CGSHWCaptureWindowList` / `SLSHWCaptureStreamCreateWithWindow` fallback behind `CaptureProvider`.
- [ ] **MANUAL-VERIFY:** cache hit path is faster; fallback engages when SCK unavailable.
- [ ] Linux gate green.

#### US-025: Observers / run-loop — CFRunLoop thread; AX notifications are optional-only (§5.3, §5.2)
**Acceptance Criteria:**
- [ ] Dedicated `Thread` running `CFRunLoopRun()` for the CGEventTaps we keep.
- [ ] C callbacks pass `self` via `Unmanaged.passUnretained(self).toOpaque()` refcon — **no** global registry/lock (§5.2).
- [ ] **AXObserver is NOT a correctness gate** — settle is the polling debounce machine (US-002); stale detection is liveness-check + GraphLocator re-walk (US-038), not the invalidation flag. AXObserver may exist only as an optional latency hint.
- [ ] **MANUAL-VERIFY:** settle returns only after real UI quiesces (no early `NO_CHANGE`) on an animated transition.
- [ ] Linux gate green (state machine already covered by US-002).

#### US-026: Permissions provider real impl
**Acceptance Criteria:**
- [ ] AX: `AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`; Screen Recording: `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`.
- [ ] **MANUAL-VERIFY:** cold-start prompts once each; warm-start silently checks; pending → retry message.
- [ ] Linux gate green.

#### US-027: Phase-3 acceptance — real `list_apps` + `get_app_state` end-to-end
**Acceptance Criteria:**
- [ ] Both tools run against real apps through the executable, producing the same pruned/serialized packet shape as Python (indices dense 0..N-1, announced truncations, image attached).
- [ ] **MANUAL-VERIFY:** run `get_app_state` on Safari, Slack, System Settings; tree + screenshot look correct; **no app is foregrounded** during either call.
- [ ] Linux gate green.

---

### Phase 4 — Kit write path (🍎 the 8 actions on real apps, experimental confirmed-delivery)

#### US-028: `InputProvider` CGEvent base — postToPid only (Invariants 1, 2, 4)
**Acceptance Criteria:**
- [ ] **Only** `CGEvent.postToPid(_:)`; never `post(tap:)`. No cursor warp, no mouse-move posted to a pid.
- [ ] Click target = event `mouseCursorPosition` + `mouseEventWindowUnderMousePointer(ThatCanHandle)` = target window id (no warp).
- [ ] Per-session **private** `CGEventSource(stateID:.privateState = -1)`.
- [ ] **MANUAL-VERIFY:** a click on a background window lands; the user's real cursor never moves; user keyboard unaffected.
- [ ] Linux gate green.

#### US-029: `CSkyLightShim` — symbol surface + optional resolution
**Acceptance Criteria:**
- [ ] Header/modulemap `extern`-declares the stable + delivery symbols with exact prototypes (design §5.1 / Appendix): `CGSMainConnectionID`, `SLSGetWindowOwner`, `SLSGetConnectionPSN`, `CGSConnectionGetPID`, `SLEventPostToPid`, `SLEventSetIntegerValueField`, `SLEventSetAuthenticationMessage`, `CGEventSetWindowLocation`, `CGEventPostToPSN`.
- [ ] Each symbol resolved via `dlopen`+`dlsym` → `unsafeBitCast` C fn ptr; `nil` = absent ⇒ fall through, never crash, never foreground. `SLSEventAuthenticationMessage` via ObjC runtime.
- [ ] `SkyLightProvider.isAvailable` is **dynamic** (re-evaluated, test-patchable).
- [ ] **MANUAL-VERIFY:** on the target macOS, log which symbols resolved.
- [ ] Linux gate green (resolution/branch logic fake-tested with a mocked loader).

#### US-029b: `validate_window_owner` — dual strategy, "assume valid" on failure (Invariant 19, §5.7)
**Acceptance Criteria:**
- [ ] Keep both strategies: PID→cid (pre-26) and cid→PID (26+, `CGSConnectionGetPID`); when it can't validate, return **assume-valid** — never block an action on an unperformable validation.
- [ ] **MANUAL-VERIFY:** owner validation succeeds on 26; absent-symbol path assumes valid.
- [ ] Linux gate green (branch logic fake-tested).

#### US-030: SkyLight targeted **mouse** delivery + window stamping (C2)
**Acceptance Criteria:**
- [ ] Mouse event built NSEvent-backed (`+[NSEvent mouseEventWithType:…windowNumber:…].CGEvent`) for proper window association; stamp `subtype(7)=3`, `windowUnderPointer(91)`/`…ThatCanHandle(92)=windowId`, window-local coords via `CGEventSetWindowLocation`, pid via `SLEventSetIntegerValueField(e,40,pid)`; post via `SLEventPostToPid`.
- [ ] **MANUAL-VERIFY:** background click on Chromium/Electron triggers the control (hover/mousedown path), no foregrounding.
- [ ] Linux gate green.

#### US-031: SkyLight targeted **keyboard** — authenticated + PSN (C3, Invariant 3)
**Acceptance Criteria:**
- [ ] `SLSEventAuthenticationMessage(+messageWithEventRecord:pid:version:)` → `SLEventSetAuthenticationMessage` → `SLEventPostToPid`; plus `CGEventPostToPSN` to the owner (`SLSGetWindowOwner`→`SLSGetConnectionPSN`).
- [ ] Modifiers are **flags on the key event** (`CGEventSetFlags`); discrete `flagsChanged` only ever on the SkyLight path, never via `postToPid` (Invariant 3).
- [ ] **MANUAL-VERIFY:** typing into a background window doesn't corrupt the user's live modifier state.
- [ ] Linux gate green.

#### US-032: `click` — pointer-first for Chromium, AX-first native; real CGEvent fidelity (C1)
**Acceptance Criteria:**
- [ ] Delivery order from `InputStrategy` (US-007): pointer-first web/Electron, AX-first native/menus; real CGEvent click (down/up) where fidelity matters.
- [ ] Confirm transport via the listen-only delivery tap echo (field 45 match); outcome trusted from snapshot (Invariant 21 — do **not** re-enable inline post-delivery AX verification on the primary path).
- [ ] **MANUAL-VERIFY:** click works on a web button, a native button, and a menu item — all in background.
- [ ] Linux gate green.

#### US-033: `type_text` — Unicode per-grapheme (C7)
**Acceptance Criteria:**
- [ ] `CGEventKeyboardSetUnicodeString` per grapheme (IME/emoji-safe), routed to target.
- [ ] **MANUAL-VERIFY:** typing emoji + accented text into a background field is correct.
- [ ] Linux gate green.

#### US-034: `press_key` — hold/interval timing preserved (D5)
**Acceptance Criteria:**
- [ ] Per-key down/up + inter-key interval timing preserved (matters for games/hold-shortcuts); modifiers as flags.
- [ ] **MANUAL-VERIFY:** a chord (e.g. Cmd-Shift-T) and a held key both register in background.
- [ ] Linux gate green.

#### US-035: `scroll` — all delta axes + AX page-scroll first (C4, Invariant 6)
**Acceptance Criteria:**
- [ ] Set line (`11/12`), **fixedPtDelta (`93/94`, double)**, **pointDelta (`96/97`, int)**, `isContinuous(88)`; semantic AX `AXScrollUpByPage`/`DownByPage` first, wheel as fallback.
- [ ] **MANUAL-VERIFY:** scroll works in both a Chromium webview (point delta) and a native Cocoa list (fixedPt).
- [ ] Linux gate green.

#### US-036: `drag` (pure CGEvent), `set_value` + `perform_secondary_action` (pure AX)
**Acceptance Criteria:**
- [ ] `drag` via `postToPid` down/move/up (no warp); `set_value`/`perform_secondary_action` via AX setters/actions (`AXValue`-typed ranges, §5.5).
- [ ] **MANUAL-VERIFY:** a slider drag and a right-click menu both work in background.
- [ ] Linux gate green.

#### US-037: Transport confirmation + OutcomeMonitor wiring (experimental pipeline; Invariants 20, 21)
**Acceptance Criteria:**
- [ ] Port `delivery_tap.py` (listen-only confirmation tap, never suppresses/modifies user events — Invariant 5) + `action_verification.py` transport check; feed `compute_verdict` (transport≠outcome; confirmed transport + no change ⇒ `DELIVERED_NO_EFFECT`).
- [ ] Snapshot remains ground truth; inline post-delivery AX verification stays **disabled** on primary paths.
- [ ] **MANUAL-VERIFY:** a delivered-but-no-effect action reports `DELIVERED_NO_EFFECT`, not a transport failure.
- [ ] Linux gate green (verdict logic already covered).

#### US-038: Stale recovery on real AX — RefetchableTree + GraphLocator (E2; Invariant 10)
**Acceptance Criteria:**
- [ ] On `-25202`/`-25204`/`-25205`/`-25212`, re-walk + rebind via GraphLocator (not "same preorder index"); liveness-check one attribute before acting on a cached ref.
- [ ] **MANUAL-VERIFY:** acting after the tree mutated rebinds to the correct element, never a dead/stale one.
- [ ] Linux gate green (locator scoring already covered).

#### US-039: Action-feedback packet population (F) + BackgroundCursor drive (§7.3 Phase-4 wiring)
**Acceptance Criteria:**
- [ ] Populate US-011's packet with real delivery path / window / logical cursor before·after / change-summary.
- [ ] One `BackgroundCursor` per `AppSession` (logical position only — OS cursor never moves); its `moveTo` is the single chokepoint that will later drive the ghost overlay (`GhostCursorController.move(windowId:)`), seam present, render deferred to Phase 6.
- [ ] **MANUAL-VERIFY:** feedback packet values are correct after a real click.
- [ ] Linux gate green.

#### US-040: `select_text` Mac impl — Tier1 CFRange + Tier2 AXTextMarker (D1)
**Acceptance Criteria:**
- [ ] Tier 1 simple fields: `AXSelectedTextRange` via `AXValueCreate(.cfRange,…)`. Tier 2 web/rich: AXTextMarker / AXTextMarkerRange (`AXStringForTextMarkerRange` → find substring via US-005 → set `AXSelectedTextMarkerRange`); caret = zero-length marker range.
- [ ] **MANUAL-VERIFY:** select a phrase in a `NSTextView` (Tier 1) and in Safari/Mail (Tier 2).
- [ ] Linux gate green (range resolution already covered).

#### US-041: `clipboard` Mac impl (D2)
**Acceptance Criteria:**
- [ ] `NSPasteboard` get/set/clear; background-safe, no focus.
- [ ] **MANUAL-VERIFY:** read + write clipboard while a user app is frontmost, without disturbing it.
- [ ] Linux gate green.

#### US-042: macOS-26 SPI-removal resilience pass (C8, §5.7)
**Acceptance Criteria:**
- [ ] `CGEventPostToPid` is the always-available primary for native apps; SkyLight family is an optimization for non-Cocoa; every removed symbol (`CGSPost*EventToProcess`, `CGSGetConnectionIDForPID`) is optional and never a hard dependency or foregrounding trigger.
- [ ] **MANUAL-VERIFY:** with SkyLight symbols forced absent, native-app input still works via `CGEventPostToPid`; nothing foregrounds.
- [ ] Linux gate green.

---

### Phase 5 — Hardening (🍎)

#### US-043: Retries, circuit breaker (SCK failure counter actor)
**Acceptance Criteria:**
- [ ] Per-failure counter `actor`s; SCK circuit breaker; retry policies per design.
- [ ] **MANUAL-VERIFY:** repeated capture failures trip the breaker and degrade gracefully (no crash, no foreground).
- [ ] Linux gate green.

#### US-044: User-interruption monitor — yield on user interaction (Invariant 16)
**Acceptance Criteria:**
- [ ] `UserInteractionMonitor` via listen-only CGEventTap; on user interaction with the driven app, surface a one-shot warning telling the model to stop and re-query.
- [ ] **MANUAL-VERIFY:** touching the driven app makes the next tool call return the yield warning.
- [ ] Linux gate green.

#### US-045: Window-ordering + frontmost observers
**Acceptance Criteria:**
- [ ] `WindowOrderingObserver` polls `CGWindowList`; NSWorkspace frontmost notifications kept.
- [ ] **MANUAL-VERIFY:** z-order changes are detected without AXObserver.
- [ ] Linux gate green.

#### US-046: Vision OCR fallback (A2)
**Acceptance Criteria:**
- [ ] `OCRProvider` via `VNRecognizeTextRequest(.accurate)` over the window image; emit synthetic `source: ocr` nodes (text + bounds, no AX ref) merged into the same packet; gated strictly on `ax_available == false` / near-empty tree (keep off the hot path).
- [ ] **MANUAL-VERIFY:** a canvas/PDF-image surface yields OCR nodes; a normal AX app does **not** trigger OCR.
- [ ] Linux gate green (merge logic fake-tested).

#### US-047: Safety blocklist + lock-screen guard (G)
**Acceptance Criteria:**
- [ ] Blocklist: Terminal apps, our own process, admin-auth dialogs, **SecurityAgent** / security-privacy prompts, Keychain prompts. Lock guard: `CGSessionCopyCurrentDictionary` → `CGSSessionScreenIsLocked == 1` ⇒ refuse input.
- [ ] **MANUAL-VERIFY:** input is refused against a Terminal window and at the lock screen.
- [ ] Linux gate green (blocklist logic fake-tested).

#### US-048: Redacted JSONL audit sink (G)
**Acceptance Criteria:**
- [ ] Redacted JSONL audit of actions (debug/trust); no secrets/tree refs leaked.
- [ ] Tested: sink writes expected redacted shape.
- [ ] Linux gate green.

#### US-049: Per-app instruction playbooks (I)
**Acceptance Criteria:**
- [ ] Author playbooks (curated markdown via existing `guidanceCache`) for Safari, Chrome, Slack, Mail, Xcode, VS Code, System Settings (Python ships only `com.apple.Music.md`).
- [ ] Guidance injection verified in `format_mcp` output.
- [ ] `swift build && swift test` green (content + injection are pure).

#### US-050: macOS-26 matrix validation + close gaps vs Python
**Acceptance Criteria:**
- [ ] Walk the design §3 invariant checklist and the Python feature set; file any residual gap as a follow-up story.
- [ ] **MANUAL-VERIFY:** full read+write smoke across Safari/Slack/native app on the target macOS, background-only.
- [ ] Linux gate green.

---

### Phase 6 — Native UX: the ghost cursor (🍎 additive only)

#### US-051: `GhostCursorOverlay` AppKit impl — non-activating panel per window (§7.2)
**Acceptance Criteria:**
- [ ] Borderless transparent **non-activating** `NSPanel` (`.nonactivatingPanel`, `ignoresMouseEvents=true`, `canBecomeKey/Main=false`, high level, `.canJoinAllSpaces`/`.stationary`); CALayer sprite; frame == target window screen rect (via `_AXUIElementGetWindow` + `getWindowBounds`); sprite clamped to that rect.
- [ ] **Decorative only** — never routes through the system cursor, never warps, never foregrounds.
- [ ] **MANUAL-VERIFY:** a ghost cursor appears on the driven window, never spills onto another app, and clicking through it hits the underlying app.
- [ ] Linux gate green (pure `GhostCursorController` palette + `clampPointToWindow` + per-window registry already testable).

#### US-052: Window tracking (§7.2)
**Acceptance Criteria:**
- [ ] Follow window frame on move/resize; hide on minimize/close/off-Space; reposition across displays.
- [ ] **MANUAL-VERIFY:** drag/resize the driven window — the ghost follows; minimize — it hides.
- [ ] Linux gate green.

#### US-053: Multi-cursor identity (§7.3, K2)
**Acceptance Criteria:**
- [ ] Keyed by `windowId`; N sessions ⇒ N cursors; each a distinct translucent tint from a rotating palette.
- [ ] **MANUAL-VERIFY:** two concurrent sessions show two visually-distinct cursors on two apps.
- [ ] Linux gate green (registry/palette logic fake-tested).

#### US-054: Animations (§7.3)
**Acceptance Criteria:**
- [ ] Core Animation: bezier "scoot" to target on `moveTo(animated:true)`, click pulse, optional wiggle-while-thinking, element-bounds highlight — driven off `BackgroundCursor` position changes (single chokepoint).
- [ ] **MANUAL-VERIFY:** moving/clicking shows the scoot + pulse on the driven window only.
- [ ] Linux gate green.

#### US-055: Occlusion clipping v2 (§7.2)
**Acceptance Criteria:**
- [ ] Clip to the window's **visible** region (subtract higher windows via CGS z-order); hide cursor when target fully occluded.
- [ ] **MANUAL-VERIFY:** covering the driven window with another app hides/clips the ghost correctly.
- [ ] Linux gate green.

#### US-056: Multi-session parallel-cursor acceptance test (K2)
**Acceptance Criteria:**
- [ ] A multi-session test drives 2+ apps concurrently (private per-session event source enables it); asserts no cross-talk, no foregrounding.
- [ ] **MANUAL-VERIFY:** Slack + Mail driven at once, two cursors, neither app foregrounded.
- [ ] Linux gate green.

---

## 5. Functional Requirements

**Invariant requirements (design §3 — each is also an invariant test in US-012 / per-phase):**
- FR-1: Synthetic events go **only** through `CGEvent.postToPid` (or SkyLight per-PID); never global `post(tap:)`.
- FR-2: No cursor warp ever; click target rides on the event + window-under-pointer hints.
- FR-3: Modifiers are flags on the key event; discrete modifiers only on the SkyLight path.
- FR-4: Per-session private event source (`stateID = -1`); confirm own delivery by echo-matching field 45.
- FR-5: Confirmation/monitoring taps are listen-only — never suppress or modify user events.
- FR-6: Scroll sets dual deltas (point + fixedPt), plus line + isContinuous as appropriate.
- FR-7: AX reads never activate (no `AXMain`/`AXFocused`/`AXRaise` during reads).
- FR-8: AX refs / graph ids / locators never reach the model; scrub leaked `<AXUIElement…>` strings.
- FR-9: OOP detection by PID comparison.
- FR-10: AX `-25205`/`-25212` ⇒ stale-reference recovery (re-walk + GraphLocator), not hard failure.
- FR-11: Write/action ops are PID-scoped ref-counted assertions, always balanced.
- FR-12: Preorder reverse-push DFS with monotonic depth throughout.
- FR-13: Capture reads a window's backing store by id (SCK desktop-independent), occluded-capable, no activation, `showsCursor=false`; no `CGWindowListCreateImage`.
- FR-14: Launch with `activates=false`; never proactively activate.
- FR-15: Focus "enforcement" is observe-and-log; the only re-activation allowed is restoring the user's previous frontmost.
- FR-16: On user interaction with the driven app, yield (one-shot warning to the model).
- FR-17: Every private symbol resolved individually + optional; missing ⇒ no-op/assume-correct, never crash, never foreground.
- FR-18: **No micro-activation anywhere** — no `SetFrontmost`/`AXRaise`/activation at any tier; failure returns `transport_confirmed=false` and tells the model to try another path.
- FR-19: `validate_window_owner` returns "assume valid" when it cannot validate.
- FR-20: Transport ≠ outcome; confirmed transport + no change ⇒ `DELIVERED_NO_EFFECT`.
- FR-21: Snapshot is ground truth; inline post-delivery AX verification stays disabled on primary paths.
- FR-22: Indices assigned only at end of pruning, pre-order, dense 0..N-1; stable across calls via RefetchableTree.
- FR-23: Token-light by construction: prune before serialize; cap geometry hints (160); transient fast-path; truncations announced, never silent.

**Capability requirements (Codex parity, folded by phase):**
- FR-24: New tools `batch`, `wait`, `select_text`, `clipboard` added; original 9 unchanged in name/schema/description.
- FR-25: Enhanced-UI + ManualAccessibility + re-walk enables Chromium/Electron trees (A1).
- FR-26: Vision OCR fallback for tree-less surfaces, gated on empty tree (A2).
- FR-27: Rich AX attributes populated (A3); window-id binding via `_AXUIElementGetWindow` (A4); text geometry via parameterized attrs (A5).
- FR-28: Action-feedback packet returned after every action (F).
- FR-29: Animation-aware debounce settle (E1); change-summary verdict (E3); request/turn cache (L1).
- FR-30: One ghost cursor per driven window, clipped to it, one per session with distinct tint, animated (H/§7) — additive, never touching FR-1…FR-23.

---

## 6. Non-Goals (explicitly out of scope — recorded so they are not re-litigated)

- **Code-mode / PTC sandbox (M1):** no embedded JS engine to run model-authored TS. `batch` (US-008) captures ~80% of the round-trip benefit at ~5% of the cost. **Skip** unless PTC is explicitly requested.
- **Zoom tool (M2):** our element-index design has no pixel-coordinate-guessing failure mode, so zoom's motivation is absent. **Skip.**
- **Passive memory / Codex `chronicle` (M3):** background screen-recording → OCR → work summaries is context/memory, orthogonal to live control. **Out of scope**; only ever a separate, privacy-gated feature.
- **Locked-Mac operation (K1):** the macOS Security authorization plug-in is a separate signed component (Intel signing is finicky). **Stretch / far-future**, not in this loop.
- **Release-parity-first intermediate:** per the user's choice we target the experimental confirmed-delivery pipeline directly; we do **not** first build a release-branch-faithful intermediate.
- **AXObserver as a correctness mechanism:** deliberately not ported as a gate (§5.3). Optional latency hint only.
- **Re-enabling inline post-delivery AX verification on primary paths** (FR-21): do not "fix" this back.
- **Porting product telemetry/analytics verbatim** unless the spine depends on it (US-013 records the decision). *US-013 outcome:* `analytics.py` call sites are kept as the `Analytics` protocol (+ a `BufferingAnalytics` mirroring the events/flush buffer); `tracing.py` (OSSignposter-equivalent timing spans) is **out of scope** — it is observability-only and the spine does not depend on it, so it is intentionally not ported.

**Anti-regression (do NOT copy macos-cua's weaker choices — M4 / §J):** `role|label|frame` element keys, "re-walk to same preorder index" refetch, integer-only scroll deltas, global `CGEventPost` default, "activate-without-raise", whole-display capture. US-012 guards these.

---

## 7. Technical Considerations

- **Toolchain:** Swift 6.2.4 present; target `arm64-apple-macosx`. Strict concurrency — `SessionManager` is an `actor`; live AX/CG handles are `final class` confined to it; `Node`/`ToolResponse`/geometry/verdicts are value `struct`s; per-failure counters are small `actor`s (§5.4).
- **C interop:** `@convention(c)` tap/observer callbacks pass `self` via `Unmanaged…toOpaque()` refcon — no global registry (§5.2). `CSkyLightShim` is a C target (header + modulemap); symbols `dlsym`-resolved and optional.
- **MCP:** official `modelcontextprotocol/swift-sdk`, stdio transport; confirm content-block shapes in Phase B (open risk, §10).
- **Linux CI discipline:** Core + Server must always build/test on Linux; all macOS code behind `#if os(macOS)`. This is the de-risking spine — protect it on every story.
- **Golden tests** for the fragile pruning passes (`flatten_outline_rows`, `cap_web_area_nodes`, `_build_tree_index_excluding`) — already partly covered; extend when touched.
- **Dual/triple PID handling** (`pid` vs `window_pid` vs element `element_pid`) must survive — it's how XPC-hosted/helper-rendered windows get input (`_background_pid_for_node`).

---

## 8. Success Metrics

- **Invariant integrity:** 100% of FR-1…FR-23 covered by an automated guard or test; zero banned symbols reachable from input/capture paths.
- **Linux gate:** `swift build && swift test` green on Linux at the end of **every** story (≥ 342 tests, growing).
- **Parity:** every Python `_lib` module is ported, intentionally dropped (with a recorded reason), or superseded — tracked in the Coverage Matrix (§10).
- **Capability:** all four new tools (`batch`/`wait`/`select_text`/`clipboard`) functional; Chromium/Electron trees non-empty after attach; occluded background capture works.
- **UX:** N concurrent sessions render N independent, window-clipped, animated ghost cursors with zero foregrounding.
- **Manual-verify burndown:** every `MANUAL-VERIFY` line is checked off by a human against real apps before the branch merges.

## 9. Open Questions

- **MCP Swift SDK maturity** — confirm stdio transport + the exact content-block shapes we need (resolve in Phase B / US-015).
- **Enhanced-UI side effects** — which apps shift layout/perf when `AXEnhancedUserInterface` is set? Per-app remembered policy (US-019) must enumerate exceptions during manual verify.
- **`elicitation.py`** — *Resolved (US-013):* the pure approval-store logic (session + persistent + denied + RISK_WARNING) is ported to `Server/Support.AppApprovalStore` with an injected `ApprovalStorage` seam (filesystem default, Linux-pure). The **interactive MCP elicitation prompt** itself is **deferred to the executable/MCP layer (US-015)** — until then the spine auto-approves on first use, exactly as before.
- **Capture path winner** — CGDisplay-window-scoped vs SCK one-shot on the target Mac (US-023 benchmark decides; affects US-022/024).
- **`AttributedRun` adapter** — exact NSAttributedString → run mapping for the markdown writer (US-001 defines the seam; Phase 4/5 implements).

---

## 10. Coverage Matrix — *"are we covering everything?"*

**Every Python module** (`app/` + `app/_lib/`, ~14.4k LOC) → Swift status → story.

| Python module | LOC | Swift target | Status | Story |
|---|---|---|---|---|
| `response.py` | — | Core/Models | ✅ done | — |
| `keys.py` | 238 | Core/KeyParser | ✅ done | — |
| `pruning.py` | 1377 | Core/Pruning | ✅ done | — |
| `graphs.py` | 439 | Core/TreeGraph | ✅ done (2 Kit leaves) | US-017/038 |
| `refetchable_tree.py` | 387 | Core/RefetchableTree | ✅ done | US-038 |
| `tree.py` | 357 | Core/Serialize | ✅ done | — |
| `confirmed_verification.py` | — | Core/Verdict | ✅ done | US-003 |
| `virtual_cursor.py` | 434 | Core/InputStrategy | ✅ done (delivery → Kit) | US-007/032 |
| `flags/errors/retry/safety.py` | 422 | Core | ✅ done (DNS inject → Kit) | US-047 |
| `markdown_writer.py` | 239 | Core/MarkdownWriter | ❌ **gap** | **US-001** |
| `observer.py` | 806 | Core SM + Kit | ⚠️ seam only; SM **gap** | **US-002**/025 |
| `action_verification.py` | 313 | Core verdict + Kit monitor | ⚠️ partial | US-003/037 |
| `accessibility.py` | 1021 | Kit/Accessibility | ❌ not started | US-017–021 |
| `input.py` | 706 | Kit/Input | ❌ not started | US-028,032–036 |
| `event_tap.py` | 209 | Kit/Input | ❌ not started | US-044 |
| `delivery_tap.py` | 137 | Kit/Input | ❌ not started | US-037 |
| `screenshot.py` | 519 | Kit/Capture | ❌ not started | US-022–024 |
| `screen_capture.py` | 419 | Kit/Capture | ❌ not started | US-022–024 |
| `apps.py` | 362 | Kit/Apps | ❌ not started | US-016 |
| `focus.py` | 671 | Kit/Focus | ❌ not started | US-044/045 |
| `skylight.py` | 383 | Kit/SkyLight + CSkyLightShim | ❌ not started | US-029–031 |
| `selection.py` | 376 | Kit/Selection | ❌ not started | US-040 |
| `session.py` | 3803 | Server/SessionManager | ✅ done | — |
| `server.py`/`main.py` | — | mac-cua exe | ❌ not started | US-015 |
| `analytics.py` | 68 | Server/Support | ✅ ported (`Analytics`/`BufferingAnalytics`) | US-013 |
| `lifecycle.py` | 59 | Server/Support | ✅ ported (`SessionLifecycle`/`TurnMetadata`) | US-013 |
| `elicitation.py` | 78 | Server/Support | ✅ ported (`AppApprovalStore` + persistence); interactive prompts → US-015 | US-013 |
| `tracing.py` | 105 | — | ⏭️ out of scope (observability-only timing spans; spine does not depend) — §6/§9 | US-013 |

**Every Codex-parity item** (A–M) → story: A1→US-019, A2→US-046, A3→US-018, A4→US-020, A5→US-021 · B1→US-022, B2→US-024, B3→US-024, B4→US-023, B5→US-022, B6→US-023 · C1→US-007/032, C2→US-030, C3→US-031, C4→US-035, C5→US-028, C6→US-031, C7→US-033, C8→US-042 · D1→US-005/040, D2→US-041, D3→US-008, D4→US-009, D5→US-034 · E1→US-002, E2→US-038, E3→US-003 · F→US-011/039 · G→US-047/048 · H→US-051–055 · I→US-049 · J/M4→US-012 · K1→**Non-Goal** · K2→US-053/056 · L1→US-004, L2→FR-21 (guard), L3→US-023 · M1/M2/M3→**Non-Goals**.

**Every one of the 23 invariants** → FR-1…FR-23 (§5) → enforced by US-012 + per-phase acceptance lines.

**Conclusion:** every Python module is ported / has a story / is consciously deferred; every Codex item A–M is scheduled or explicitly a Non-Goal; every invariant is a tracked requirement. Nothing in the two design docs is unaccounted for.

---

## Appendix — Phase summary & sequencing for Ralph

| Phase | Stories | Class | Gate |
|---|---|---|---|
| A — finish Linux layer | US-001…US-013 | 🟢 pure | build + test green |
| B — scaffold Mac | US-014…US-015 | 🍎 | compiles on macOS; Linux green |
| 3 — read path | US-016…US-027 | 🍎 | compile + fakes; MANUAL-VERIFY |
| 4 — write path | US-028…US-042 | 🍎 | compile + fakes; MANUAL-VERIFY |
| 5 — hardening | US-043…US-050 | 🍎 | compile + fakes; MANUAL-VERIFY |
| 6 — ghost cursor | US-051…US-056 | 🍎 | compile + fakes; MANUAL-VERIFY |

Ralph executes top-to-bottom. Phase A is the safest, highest-ROI work and should run first. Mac phases produce compiling, fake-tested code with explicit `MANUAL-VERIFY` lines a human clears against real apps before merge.
