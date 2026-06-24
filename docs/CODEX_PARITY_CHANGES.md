# Codex / SkyComputerUse Parity — Change Spec for the Swift Port

**Status:** Research-derived backlog. Target = match/beat OpenAI Codex "Computer Use" (the private **SkyComputerUse** helper, the ex-"Sky" app OpenAI acquired). Companion to `SWIFT_PORT_DESIGN.md` — that doc is the contract; this doc is the delta we add to reach Codex-class.

**How this was produced:** deep read of (a) the `code-yeongyu/macos-cua` TS repo's *working* private-SPI bindings, (b) OpenAI's official Codex Computer Use docs + reverse-engineering writeups, (c) the underlying private SPIs (SkyLight/CGS, Accessibility, ScreenCaptureKit, Vision). Exact symbols/field numbers are in the Appendix.

Legend per item: **[NEW]** not in our current design · **[CONFIRM]** in design, ensure the macOS impl does it · **[AHEAD]** we already beat them, do not regress.

---

## What Codex/SkyComputerUse actually is (so we aim at the right target)

- **AX-tree-first + screenshot as context/fallback.** Codex parses the accessibility hierarchy (can be "20 levels deep"), reasons about elements, and uses screenshots as backup — *not* coordinate-guessing. This is our architecture. We are at design parity; the gaps below are execution + a few capabilities.
- **Background virtual cursor.** No foregrounding; the user keeps working. The cursor "wiggles when thinking, takes playful paths." → our Prime Invariant + Phase-6 ghost cursor. **[AHEAD/CONFIRM]**
- **Parallel cursors across apps** (Slack+Ivory+Unread concurrently). Warns against *same-app* parallel.
- **Locked-Mac operation** via a Security authorization plug-in (stretch, §K).
- Reads **windows, menus, keyboard, and clipboard**; per-app approvals; blocks Terminal/itself/admin-auth/security prompts.

---

## A. Perception — AX tree completeness (biggest correctness wins)

### A1. Enable Chromium/Electron trees — `AXEnhancedUserInterface` + `AXManualAccessibility` **[NEW, high impact]**
Chrome, Electron (Slack, VS Code, Obsidian, Discord), and Chromium webviews **do not expose an AX tree by default**. They build it lazily only when a client sets `AXEnhancedUserInterface = true` (the attribute VoiceOver sets) and/or `AXManualAccessibility = true` (Electron-specific, newer) on the **AXApplication** element. **The first walk after setting returns empty** (lazy build) — so "walk once, empty → OCR" silently misses every Electron app. This is *the* reason pure-AX tools look blind on modern apps; it is a flag, not an OCR problem.
- **Do:** on session attach, set BOTH `kAXEnhancedUserInterfaceAttribute` and `AXManualAccessibility` = `kCFBooleanTrue` on the app element; then **re-walk** (poll until non-empty or settle, ~2–5 walks / a few hundred ms).
- **Caveat:** `AXEnhancedUserInterface` makes some apps believe a screen reader is active and can change layout/perf. Make it per-app, remembered, and reversible; log when set. Provider: `AccessibilityProvider.enableEnhancedUI(appRef)`.

### A2. Vision OCR fallback for genuinely tree-less surfaces **[NEW]**
After A1, the only blank surfaces are canvas/games/video/PDF-image/custom-drawn. Add a **`VNRecognizeTextRequest`** (Vision, `.accurate`) pass over the captured window image; emit recognized strings as **synthetic elements** (text + bounds, no AX ref, flagged `source: ocr`) merged into the same model packet so the tool surface is identical. Gate strictly on `ax_available == false` (or a near-empty tree) to keep it off the hot path. New seam: `OCRProvider`. Phase 5.

### A3. Populate the rich AX attribute set in the walker **[CONFIRM]**
Our `Node` already carries `states`, `value`, `placeholder`, `helpText`, `valueDescription`, `description`, `subrole`, `secondaryActions`, `focusedElement`. The macOS walker (Phase 3) must actually fill them: read `AXEnabled`, `AXFocused`, `AXSelected`, `AXValue` (+ `AXMinValue`/`AXMaxValue` for sliders/steppers), `AXPlaceholderValue`, `AXRoleDescription`, `AXSelectedText`, position-in-set. Disabled/focused/selected state stops the model from clicking dead controls.

### A4. Bind AX element → CGWindowID via private `_AXUIElementGetWindow` **[NEW]**
`AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out)` (ApplicationServices, private) returns the window id for an AX window/element directly. Use it for `CaptureProvider.findWindowIdForAXWindow` and to bind the capture/SkyLight target — replaces macos-cua's fragile get-windows + bounds/title matching. Per-symbol-optional; fall back to bounds match if absent.

### A5. Text geometry via parameterized attributes **[NEW]**
For precise text targeting/selection bounds: `AXUIElementCopyParameterizedAttributeValue` with `kAXBoundsForRangeParameterizedAttribute`, `kAXRangeForPositionParameterizedAttribute`, and `kAXVisibleCharacterRangeAttribute`. Enables "where is this text on screen" and visible-range-aware reads.

---

## B. Capture — true background single-window capture

### B1. `SCContentFilter(desktopIndependentWindow:)` + `SCScreenshotManager.captureImage` **[CONFIRM, Invariant 13]**
This captures **one window's content even when occluded/partially hidden or off the active display, with no activation** (confirmed: SCK includes occluded window content for desktop-independent filters). macos-cua **cannot do this** — its SCK shim captures the *whole main display + crops* (`initWithDisplay:excludingWindows:@[]`, `showsCursor=YES`), so a background/occluded window is invisible to it. This is a place we beat them by construction. Set `showsCursor = NO`.

### B2. Cache `SCShareableContent` / `SCContentFilter` **[NEW]**
Filter resolution is ~80–200 ms cold (SCShareableContent discovery). Cache per (window/display) and invalidate on display-config / window-replace. (macos-cua caches the display filter; we cache per-window.)

### B3. Private GPU capture fallback — `CGSHWCaptureWindowList` / `SLSHWCaptureStreamCreateWithWindow` **[NEW, optional]**
For speed or when SCK is unavailable: `CGSHWCaptureWindowList` (one-shot) or `SLSHWCaptureStreamCreateWithWindow` (10.15+, GPU pre-composite stream). Per-symbol-optional; SkyLight needs no entitlement. Keep behind `CaptureProvider` so we pick per-OS.

### B4. Window-scoped capture + capture-time downscale **[CONFIRM]**
Capturing one window (fewer pixels) is faster than Codex's display capture. Downscale on the GPU via `SCStreamConfiguration.width/height` + `scalesToFit`, encode via ImageIO `kCGImageDestinationImageMaxPixelSize`. Avoid any `screencapture`/`sips` shell-out (macos-cua's slow path: 608 ms p50 vs 61 ms FFI).

### B5. Exclude the user's cursor; render our own **[CONFIRM, Invariant 13]**
`showsCursor = NO`. The visible pointer is our decorative ghost-cursor overlay only (§I).

### B6. Emit capture metadata **[NEW]**
Return exact produced image px dims, scale/backing factor, crop origin, target window id+title, display id. The model needs to know the frame it's reasoning over (Codex ships `codexDisplay`-style display context).

---

## C. Input — fidelity + completeness (exact SPIs in Appendix)

### C1. Prefer **real CGEvent clicks** over `AXPress` where fidelity matters **[NEW]**
Codex prefers physical CGEvent clicks. `AXPress` skips hover/`mousedown`/JS listeners/drag-arming that many web/Electron controls require — silent under-triggering. Make `InputStrategy` choose **pointer-first** for Chromium/web/Electron app types (keep AX-first for native Cocoa controls and menu items). Pure logic → Linux-testable now.

### C2. Targeted mouse via SkyLight + window stamping **[CONFIRM]**
`SLEventPostToPid(pid, event)` with: field **40 = pid** (`SLEventSetIntegerValueField`), `kCGMouseEventSubtype(7) = 3`, `kCGMouseEventWindowUnderMousePointer(91)` and `…ThatCanHandleThisEvent(92)` = windowId, window-local coords via `CGEventSetWindowLocation` (**a SkyLight export, not CoreGraphics**). Build the mouse event NSEvent-backed (`+[NSEvent mouseEventWithType:…windowNumber:…] → CGEvent`) for proper window association; `setActivationPolicy(.accessory)` to stay out of the Dock.

### C3. Targeted keyboard — authenticated SkyLight + PSN **[CONFIRM]**
`SLSEventAuthenticationMessage` (`+messageWithEventRecord:pid:version:`) → `SLEventSetAuthenticationMessage` → `SLEventPostToPid`; then also `CGEventPostToPSN` to the window owner (`SLSGetWindowOwner` → `SLSGetConnectionPSN`). In Swift we can pull the event record cleanly rather than the TS pointer-offset hack (decode at CGEventRef byte offset 24/32/16).

### C4. Scroll — set ALL delta axes + AX page scroll **[CONFIRM, Invariant 6]**
macos-cua sets only line deltas (axes 11/12). We must set line (`11/12`), **fixedPtDelta (`93/94`, double)**, **pointDelta (`96/97`, int)**, and `isContinuous(88)` as appropriate — covers Chromium/Electron (point) and native Cocoa (fixedPt). Add a **semantic AX page-scroll first** path (`AXScrollUpByPage`/`AXScrollDownByPage` actions) with the wheel event as fallback (Codex uses page scrolling).

### C5. Per-session **private** `CGEventSource(stateID: .privateState = -1)` + echo-match field 45 **[AHEAD]**
Confirm our own delivery via `kCGEventSourceStateID(45)` on the listen-only tap so we never confuse agent input with the user's. macos-cua uses HID state (1) with no echo check — keep our stricter design.

### C6. Modifiers as flags, never discrete `flagsChanged` to a pid **[AHEAD/CONFIRM, Invariant 3]**
`CGEventSetFlags` on the key event. Discrete modifiers only ever on the SkyLight path.

### C7. Unicode text via `CGEventKeyboardSetUnicodeString` per grapheme **[CONFIRM]**
IME/emoji-safe; route to target. (macos-cua does this per-char.)

### C8. macOS-26 SPI-removal resilience **[CONFIRM]**
`CGSPostKeyboardEventToProcess` / `CGSPostMouseEventToProcess` / `CGSGetConnectionIDForPID` are **removed in macOS 26**. Primary delivery = `CGEventPostToPid` (native) + `SLEventPostToPid` family (SkyLight); per-symbol optional resolution; never fall back to global posting or foreground.

---

## D. New model-facing tools / capabilities

### D1. `select_text` tool (two-tier) **[NEW]**
Codex exposes text selection + caret placement by content ("provide text exactly as in the AX tree incl. Markdown; disambiguate by surrounding prefix/suffix").
- **Tier 1 (simple fields):** `AXSelectedTextRange` via `AXValueCreate(kAXValueCFRangeType = 4, {location,length})` — works for `NSTextField`/`NSTextView` (macos-cua's approach).
- **Tier 2 (web/rich content — Safari/Chrome/Mail/Pages):** **AXTextMarker / AXTextMarkerRange**. Read whole text via `AXStringForTextMarkerRange`, find the substring, build a range from markers, set `AXSelectedTextMarkerRange`. CFRange does NOT work on web content; markers do. Caret-before/after = zero-length marker range. Range-resolution (prefix/suffix → offset) is pure logic, Linux-testable. New seam: `SelectionProvider.selectByContent`.

### D2. Clipboard tool(s) **[NEW]**
Codex interacts with clipboard state. Add `NSPasteboard` read/write (get/set/clear) — background-safe, no focus. New seam: `ClipboardProvider`.

### D3. `batch` tool — N actions / one MCP call **[NEW]**
Linear, stop-on-first-failure, one final snapshot. Removes N−1 round-trips. Pure spine logic → **buildable/testable on Linux now.**

### D4. `wait` tool **[NEW]**
Explicit model-requested settle (Codex has `wait`). Trivial.

### D5. Preserve key hold/interval timing in `press_keys` **[CONFIRM]**
Per-key down/up timing + inter-key interval (Codex preserves this; matters for games/hold-shortcuts).

---

## E. Settle & tree machinery (reliability)

### E1. Animation-aware debounced settle (formalize) **[NEW vs §5.3]**
Codex ships `DebounceStateMachine` + `ComputerUseIPCAppStartCaptureAnimationDisplay` (animation-aware capture). Replace ad-hoc polling with an explicit debounce state machine: poll tree-hash / key-frame rects, require N ms of quiet, detect in-flight animation (frame deltas) and keep waiting, **hard cap + early-exit, never a fixed sleep** (the 500 ms cua tax). The state machine itself is pure → Linux-testable. Provider feeds frames.

### E2. RefetchableTree + GraphLocator on stale AX **[AHEAD/CONFIRM]**
On `kAXErrorInvalidUIElement (-25202)` / `-25204` / `-25212` / `-25205`, refetch via `GraphLocator` re-walk+rematch. This is **stronger** than SkyComputerUse's index-style refetch and macos-cua's "re-walk to same preorder index" (which breaks when the tree changed). Keep it.

### E3. Post-action AX change-summary as a first-class verdict **[NEW]**
Diff post-action tree vs pre-action by element key → `{added, removed, changed}`. Feed `compute_verdict`: confirmed transport + 0/0/0 = `DELIVERED_NO_EFFECT` → tell the model to retry/alt-path. Pure → Linux-testable now.

---

## F. Action-feedback packet **[NEW]**
Return after every action: delivery path used (`AXPress` | `SkyLight` | `CGEvent` | `PSN` | `wheel`), target window id+title, logical (virtual) cursor before/after, and the E3 change-summary. (Codex returns `cursor_before`/`cursor_after`, frontmost window.) Makes the model self-correct instead of flying blind on a bare `{ok:true}`.

---

## G. Safety **[CONFIRM + extend]**
- Blocklist: Terminal apps, our own process, admin-auth dialogs, **SecurityAgent** / security-privacy permission prompts, Keychain prompts. (Extend `SafetyBlocklist`.)
- Lock-screen guard: `CGSessionCopyCurrentDictionary` → `CGSSessionScreenIsLocked == 1` → refuse input (unless locked-mode §K).
- Yield on user interaction (listen-only `CGEventTap`) — have.
- Per-app approval store — have (`AppApprovalStore`).
- Redacted JSONL audit sink — borrow (debug/trust).

---

## H. Ghost cursor / UX (Phase 6) **[NEW]**
**One translucent ghost cursor per driven window, clipped to that window so it never overlaps another app; one per concurrent session (distinct tint).** Each: a non-activating `NSPanel` (`canBecomeKey/Main = NO`, `ignoresMouseEvents = YES`), frame == the target window's screen rect, sprite clamped to that rect; follows the window on move/resize, hides on minimize/occlusion. Decorative only (never routes through the system cursor, never foregrounds). Animate: "wiggle when thinking," bezier "scoot" to target, click pulse, highlight target element bounds — matches Codex's animated virtual cursor. New Core seam `GhostCursorOverlay` + pure `GhostCursorController` (palette + `clampPointToWindow` + per-window registry, Linux-testable); drive off `BackgroundCursor` position changes (Phase 4), render in AppKit (Phase 6). See `SWIFT_PORT_DESIGN.md` §7. Reference: macos-cua `native/cursor-overlay.m` (non-activating panel + stdin command protocol).

---

## I. Per-app instruction playbooks **[NEW content]**
We already have the mechanism (`guidance` / `app_specific_instructions` / `guidanceCache`); Codex ships curated per-app markdown. Author playbooks for top apps (Safari, Chrome, Slack, Mail, Xcode, VS Code, System Settings): quirks, best AX paths, known traps.

---

## J. Where we are already ahead (do NOT regress to macos-cua)
- **Background occluded-window capture** (B1) — they capture the whole display; can't see occluded windows.
- **Private per-session event source + echo match** (C5) — they use shared HID state.
- **Dual+ scroll axes** (C4) — they set only line deltas.
- **GraphLocator stale-recovery** (E2) — they re-walk to the same index (breaks on tree change).
- **No foreground / no micro-activation, ever** — strictly enforced.
- **MCP / any-model, any-client** — Codex CU is OpenAI-app-only.

## K. Stretch (large, separate efforts)
- **K1. Locked-Mac operation.** macOS **Security authorization plug-in** that participates in the unlock flow, covers all displays while temporarily unlocked, relocks on local input, scoped to active turns. Separate signed component; Intel signing is finicky. Far-future.
- **K2. Parallel cursors across apps.** Our private per-session event source already enables it; add a multi-session test as the acceptance gate.

---

## Mapping to our architecture

| Area | Provider seam (Providers.swift) | Phase | Linux-testable now? |
|---|---|---|---|
| A1 enhanced-UI, A3 attrs, A4 window-id, A5 text-geom | `AccessibilityProvider` (+ `enableEnhancedUI`, `windowIdForElement`) | 3 | flags/logic only |
| A2 OCR | new `OCRProvider` | 5 | merge-logic only |
| B1–B6 capture | `CaptureProvider` | 3 | sizing/crop math only |
| C1 strategy | `InputStrategy` (Core) | — | **yes** |
| C2–C8 delivery | `InputProvider` + `CSkyLightShim` | 4 | constants/field table only |
| D1 select_text | `SelectionProvider` (+ range resolution pure) | 4 | range logic **yes** |
| D2 clipboard | new `ClipboardProvider` | 4 | — |
| D3 batch, D4 wait | Server spine | 2/now | **yes** |
| E1 debounce, E3 verdict | `SettleMonitor` + Core verdict | 4 / now | state-machine + verdict **yes** |
| F feedback | `OutcomeMonitor` + ToolResponse | 4 | shape **yes** |
| G safety | `SafetyBlocklist`, lock guard, taps | 5 | blocklist logic **yes** |
| H overlay | new `Overlay` (AppKit) | 6 | — |
| I playbooks | `guidanceCache` content | any | **yes** (content) |

**Do-now (Linux, no Mac):** D3 batch · D4 wait · E3 change-summary verdict · E1 debounce state machine · C1 InputStrategy pointer-first for Chromium · D1 select-range resolution · the CGEvent field-constant table (Appendix) as Core constants.

---

## Appendix — exact private/SPI symbols & constants (verified)

### CGEvent fields (`CGEventField`, CoreGraphics — public header, some "advanced")
```
kCGMouseEventNumber=0  ClickState=1  Pressure=2  ButtonNumber=3  DeltaX=4  DeltaY=5  Subtype=7
kCGKeyboardEventKeycode=9
kCGScrollWheelEventDeltaAxis1=11   Axis2=12   Axis3=13        (line/integer)
kCGScrollWheelEventFixedPtDeltaAxis1=93  Axis2=94  Axis3=95    (double, native Cocoa)
kCGScrollWheelEventPointDeltaAxis1=96    Axis2=97  Axis3=98    (integer px, Chromium/Electron)
kCGScrollWheelEventIsContinuous=88   ScrollPhase=99
kCGMouseEventWindowUnderMousePointer=91
kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent=92
kCGEventSourceStateID=45
CGEventSourceStateID: Private=-1  CombinedSession=0  HIDSystemState=1
CGMouseButton: Left=0 Right=1 Center=2 ;  flag masks: Shift=0x20000 Control=0x40000 Alt=0x80000 Cmd=0x100000
```

### SkyLight (`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`) — input/window
```
uint32_t CGSMainConnectionID(void)
void     SLEventPostToPid(int32_t pid, CGEventRef e)
void     SLEventSetIntegerValueField(CGEventRef e, uint32_t field, int64_t v)   // field 40 = target pid
void     SLEventSetAuthenticationMessage(CGEventRef e, id message)
void     CGEventSetWindowLocation(CGEventRef e, CGPoint p)                       // window-local coords (SkyLight!)
int32_t  SLSGetWindowOwner(uint32_t cid, uint32_t wid, uint32_t *ownerCidOut)
int32_t  SLSGetConnectionPSN(uint32_t cid, ProcessSerialNumber *psnOut)          // psn buffer = 8 bytes
ObjC: SLSEventAuthenticationMessage +messageWithEventRecord:pid:version:
// capture (private, optional): CGSHWCaptureWindowList ; SLSHWCaptureStreamCreateWithWindow (10.15+, GPU pre-composite)
// REMOVED in macOS 26: CGSPostKeyboardEventToProcess, CGSPostMouseEventToProcess, CGSGetConnectionIDForPID
// FORBIDDEN (never port): SLPSSetFrontProcessWithOptions / CGSSetConnectionProperty "SetFrontmost"
```

### CoreGraphics — input/capture/lock (public unless noted)
```
CGEventPostToPSN(ProcessSerialNumber *psn, CGEventRef e)
CGEventSourceCreate(CGEventSourceStateID)  // use Private(-1) for our per-session source
CGEventCreateMouseEvent / KeyboardEvent / ScrollWheelEvent ; CGEventKeyboardSetUnicodeString ; CGEventSetFlags
CGDisplayCreateImage(displayID) ; CGImageCreateWithImageInRect ; CGMainDisplayID ; CGDisplayBounds ; CGGetDisplaysWithRect
CGSessionCopyCurrentDictionary() -> key "CGSSessionScreenIsLocked" (==1 when locked)
```

### Accessibility (`ApplicationServices`) — public + private
```
AXIsProcessTrusted ; AXUIElementCreateApplication(pid) ; AXUIElementCreateSystemWide
AXUIElementCopyElementAtPosition(syswide, x, y, &out)   // hit-test by screen point
AXUIElementGetPid ; AXUIElementCopyAttributeValue / SetAttributeValue ; AXUIElementCopyActionNames ; AXUIElementPerformAction
AXUIElementCopyParameterizedAttributeValue   // kAXBoundsForRange, kAXRangeForPosition
AXValueCreate(type, ptr) / AXValueGetValue / AXValueGetType   // CGPoint=1 CGSize=2 CFRange=4
PRIVATE: AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out)
Attributes to set/read: kAXEnhancedUserInterface(set true), "AXManualAccessibility"(set true),
  AXEnabled, AXFocused, AXSelected, AXValue/AXMinValue/AXMaxValue, AXPlaceholderValue, AXRoleDescription,
  AXSelectedText, AXSelectedTextRange, AXVisibleCharacterRange, AXSelectedTextMarkerRange
Text markers (HIServices private): AXTextMarkerCreate/RangeCreate, AXTextMarker(Range)GetTypeID,
  param attrs: AXStringForTextMarkerRange, AXTextMarkerRangeForUIElement, AXStartTextMarker, AXEndTextMarker,
  AXBoundsForTextMarkerRange, AXTextMarkerForPosition   (ref impl: Hammerspoon hs.axuielement.axtextmarker)
AX error codes: -25202 invalid element, -25204 cannot complete, -25205 attr unsupported, -25212 notification-ish/stale
```

### ScreenCaptureKit (public) — single-window background capture
```
SCShareableContent.getShareableContent... (cache it) ; SCWindow ; SCContentFilter(desktopIndependentWindow: SCWindow)
SCScreenshotManager.captureImage(contentFilter:configuration:)  // includes occluded window content; no activation
SCStreamConfiguration { width,height,scalesToFit, showsCursor=false, pixelFormat=32BGRA }
ImageIO encode: CGImageDestination... + kCGImageDestinationImageMaxPixelSize
```

### Vision (public) — OCR fallback
```
VNRecognizeTextRequest (recognitionLevel = .accurate, usesLanguageCorrection) over the window CGImage → strings + boxes
```
