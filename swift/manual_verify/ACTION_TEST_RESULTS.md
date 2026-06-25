# mac-cua Swift — Action × App Verification

Testing each action across app categories: System / User-installed / Electron / Browser.

> **Ground rule:** Drive everything through mac-cua tools only. Do NOT use Terminal/osascript
> to open windows or set up app state — that defeats the purpose of the test.

Legend: ✅ works · ⚠️ partial · ❌ broken · — not yet tested

| Action | System | User-installed | Electron | Browser | Notes |
|--------|--------|----------------|----------|---------|-------|
| list_apps | ✅ | — | — | — | Returned running + recent apps with window_ids |
| get_app_state | ⚠️ | ❌ | ❌ | ✅ | Live window ✅; cold-start no-window (TextEdit), focus-steal + silent fallback (VS Code) |
| click | — | — | ❌ | ⚠️ | Browser: works but false-negative report. Electron: does NOT establish keyboard focus |
| type_text | ✅ | ⚠️ | ⚠️ | ✅ | Native ✅; Electron needs click-to-focus first (else silent false-positive) |
| set_value | ⚠️ | ❌ | ❌ | ⚠️ | Native/browser work (false-neg report); Electron truly fails + bad settable flag |
| press_key | — | — | — | — | |
| scroll | — | — | — | — | |
| drag | — | — | — | — | |
| select_text | — | — | — | — | |
| clipboard | — | — | — | — | |
| perform_secondary_action | — | — | — | — | |
| wait | — | — | — | — | |
| batch | — | — | — | — | |

## Stability
- 🐛 **Server segfault (2026-06-25 12:58):** mac-cua crashed on its own mid-session with `EXC_BAD_ACCESS` / `SIGSEGV` ("possible pointer authentication failure"). Crash report: `~/Library/Logs/DiagnosticReports/mac-cua-2026-06-25-125805.ips`. No user action triggered it. Memory-safety bug to investigate (backtrace not yet symbolicated).

## Fixes

### ✅ FIXED — Step limit feature removed (was: permanent lockout after 20 actions)
- Root cause: Swift `SessionLifecycle.checkStepLimit()` checked the **session-cumulative** `stepCount` (never reset) instead of the **per-turn** `currentTurn.stepCount` like the Python original (`lifecycle.py:50-55`). Tripped permanently after 20 total actions/session.
- Per user decision, the whole feature was **removed** (context/loop management is the agent's responsibility, not the server's), rather than just fixing the per-turn counter.
- Removed: `WorkaroundFlags.loopStepLimit` (+env/config parsing), `SessionLifecycle.stepLimit/stepCount/incrementStep/checkStepLimit`, `TurnMetadata.stepCount`, and the 3 enforcement blocks (Spine/Batch/SelectText). Left `AutomationError.stepLimit` case unused (harmless).
- Tests updated (Flags/Support/FoundationSmoke/Pipeline). Build clean, 51 tests pass.

### ✅ FIXED — Menu-bar duplication (+ change_summary corruption)
- Root cause: `pruneTreeNodes` (Spine.swift) appends the app menu bar via `getMenuBar`, but the snapshot path reuses already-pruned nodes from `RefetchableTree` (Spine.swift:852-853) and re-runs `pruneTreeNodes`, re-appending the menu bar (+1 per snapshot; resets on restart).
- Fix: made the append idempotent — skip it when the input already contains a `"menu bar"` node (a freshly-walked *window* tree never has one). This also fixes `change_summary`, which was counting the leaked menu-bar nodes.

### ✅ FIXED — set_value false-negative (always "Cannot set value")
- Root cause: verifier did **exact read-back equality** (`text == value`); failed when the field augments (Safari autocomplete) or normalises (multi-line/em-dash) the value → threw even on success.
- Fix (Option A): capture read-back before; if no exact verifier confirms, accept as success when the field now equals the value OR changed vs before ("delivered; verified by state change"); only otherwise return an honest **unverified** message (not "failed"). Electron true-failure still reports unverified, not success.

### ✅ FIXED — click false-negative ("Click failed" but worked)
- Root cause: `backgroundClickNode` delivers the CGEvent (transport confirmed) but verifies with a **selection** verifier; for an action button (e.g. Safari New Tab) that yields `.noEffect`, so it returned false and `handleClick` threw "Click failed".
- Fix (Option A): record the CGEvent verdict; when delivery was confirmed but effect unobserved (`.noEffect`), report "delivered, effect unverified" instead of throwing.

All four fixes: build clean, **880 tests pass**.

### Live verification (after install + server restart)
- ✅ **Menu-bar duplication: FIXED & verified** — two consecutive Safari snapshots stayed at a single menu bar (#68). No accumulation.
- ⚠️ **set_value: false-FAILURE removed, but deeper root cause found** — no longer says "Cannot set value"; now "delivered but could not be verified". BUT live testing shows the value DID change on screen (Safari→apple.com, TextEdit→new sentence) while **the AX read-back AND the returned snapshot both show the OLD value**. Root cause: a programmatic AXValue set does not fire the AX notifications the settle monitor watches, so `RefetchableTree.isInvalidated` stays false → `getNodes()` fast-path returns stale cached nodes; the verifier reads the same stale value. Option A's "changed vs before" can't help because both reads are stale.
- ❌ **click: still false-negative** — "Click failed for element 56" but a 3rd tab opened. My `.noEffect` fix only covers the background CGEvent path; this click delivered via the **AX-press path** (`tryAXClickNode`) which "fails verification but works". Same stale-AX class.
- **➡️ Correct fix (per user): re-walk the AX tree after a mutating action and verify the change against the fresh walk** (force re-walk / invalidate even when the settle monitor saw no notification). Replaces the unreliable stale read-back for both set_value and click.

### ✅ IMPLEMENTED — Forced post-action AX re-walk (snapshot truthfulness + verification)
Scope (user choice): **all mutating actions**.
- `RefetchableTree.forceRewalk()` — unconditional re-walk bypassing the `isInvalidated` fast path; updates the cache + resets the monitor.
- Spine step 9b: after a non-state-only dispatch, `resolved.refetchableTree?.forceRewalk()` before `takeSnapshot` → **returned snapshot now reflects reality** (fixes stale values after set_value).
- `set_value`: verdict now reads the element's value from a forced re-walk (`freshNodeText`, matched by `refsEqual`); success if it equals the value OR changed vs before; else honest "unverified".
- `click`: captures a pre-click `treeSignature` (role/value/label/description; ignores volatile focus/geometry); before throwing, force-rewalks and if the signature changed → "effect confirmed via AX re-walk"; else delivered-unverified; else fail.
- Build clean, **880 tests pass**. Pending live re-verification after restart.

### ✅ IMPLEMENTED — Electron/Chromium support (A + B, background & non-intrusive)
Root cause of empty Electron trees: the enhanced-UI mechanism (set `AXEnhancedUserInterface` + `AXManualAccessibility`, then re-walk) existed, but the poll stop condition was `nodeCount > 0`. An Electron *window* exposes a few chrome nodes immediately, so the poll exited on the **first** walk — before Chromium built its web a11y tree (which it does lazily over a few hundred ms→~1s).
- **A (tree population):** added `EnhancedUIRewalkPolicy.priming` (12 attempts × 100ms) and a content-aware stop `shouldContinue(attempt:hasWebContent:)`. The prime poll now continues until an **AXWebArea** appears (real web content), not just chrome. `EnhancedUI.swift` + `primeEnhancedUI`.
- **B (focus, background):** already in place and non-intrusive — `focusNodeForKeyboardInput` sets `AXFocused` via pure AX (no activation), falling back to a background CGEvent click; `type_text`/`set_value` use it. Once A populates the tree, element-indexed click/set_value/type_text work on Electron with no activation.
- Nothing activates or raises the window; all paths stay background (Invariant 14/15 preserved).
- Build clean, **881 tests pass**.
- ✅ **VERIFIED LIVE on VS Code:** `get_app_state` now returns the **full web AX tree** (HTML content, toolbars, Explorer w/ demo.txt, editor tab, CHAT panel, composer text area, status bar) — previously just window + menu bar. `type_text(element_index: composer)` landed "typed into the Electron composer by element_index, fully background" with the Send button enabling — fully background (CGEvent, no activation). `change_summary: +12 -25 ~4` = a real, meaningful diff (menu-bar-leak fix also fixed change_summary accuracy).
- Caveat (not a mac-cua issue): VS Code's Monaco **editor** reports "The editor is not accessible at this time… Shift+Option+F1" — its own screen-reader opt-in. All other web controls are driveable.

### ✅ Live verification of re-walk verdicts (post-restart)
- **set_value (TextEdit):** `Set value of element 2 … (verified via AX re-walk, read-back=…)` — success reported, snapshot showed the NEW text in node 2 (no longer stale), `change_summary: +1 -1 ~0` accurate.
- **click (Safari New Tab):** `Clicked element 56 (effect confirmed via AX re-walk)` — a 3rd tab opened (tree "3 tabs"), `change_summary: +5 -2 ~1` accurate. No more false "Click failed".
- **Step limit:** 20+ actions this session, no lockout — feature removal confirmed live.

### ✅ FIXED — Performance regression from the re-walk (extra AX walks per action)
The forced re-walk added latency: step 9b re-walked **unconditionally** after every mutating action (even when the settle monitor already invalidated the tree and `takeSnapshot` re-walks anyway → double walk), and `set_value`/`click` re-walked again inside their handlers → up to 2–3 full AX walks/action (expensive on Electron's ~180-node tree).
- Added `AppSession.didForceRewalkThisAction` (reset each `execute()`).
- Step 9b now forces a re-walk **only when** the monitor is quiet (`!isInvalidated`) AND no handler already re-walked — otherwise the existing snapshot walk covers it. → **at most one AX walk per action** (back to baseline).
- `click` verdict: uses the cheap `isInvalidated` signal first (monitor saw changes ⇒ effect confirmed, no walk); only forces a walk when the monitor is quiet.
- `set_value`/`click` handler re-walks set the flag so step 9b skips.
- Build clean, **883 tests pass**. Pending live latency check.

### Install gotcha (Apple Silicon)
`cp`-ing the rebuilt binary over `~/.local/bin/mac-cua` left an AMFI-invalid signature → SIGKILL at launch ("Code Signature Invalid"), `/mcp` reconnect failed `-32000`. Fix: `codesign --force --sign -` after copy. Saved to memory.

## Detailed log

### list_apps
- ✅ Returned Terminal, Finder, Safari, TextEdit, Window Server, Notification Centre, Dock with window_ids, pids, bounds, titles.

### get_app_state
- ✅ Stale window_id (138) → clean error: "Window 138 is not available. Call list_apps or get_app_state to refresh."
- ✅ Running window (Terminal): full AX tree + focused-element marker + app-specific instructions + screenshot.
- ❌ **Cold-start bug**: `get_app_state(app="com.apple.TextEdit")` *did* launch TextEdit, but the launched app had **no window**, so the call returned Terminal's state instead of TextEdit. Cold-start should bring up (or wait for) the app's own window.
- ❌ **Screenshot scope bug**: the returned screenshot is the **whole screen**, not just the targeted app window. It should be cropped to the app/window being worked on.

**Browser (Safari):** ✅ Cold-start launched Safari *with* a window (Start Page). Rich AX tree, Safari-specific tips injected, focused element = address bar, screenshot correctly scoped to the window. Cold-start itself works when the app opens a default window.

**Electron / user-installed (VS Code):** ❌ Multiple problems:
- `get_app_state(app="com.microsoft.VSCode")` returned **Terminal's** state (silent fallback to frontmost), both immediately and on retry — even though VS Code is installed and launched. Targeting by bundle ID is not reaching VS Code.
- **Focus-stealing bug (user-confirmed):** the cold-start launch brought VS Code up with **full foreground focus**, NOT in the background. Violates the "stays background-targeted, does not activate the window" guarantee. Safari/TextEdit launches should be re-checked for the same.
- Minor: returned a **duplicate menu bar node** in the AX tree (two identical menu bars #15 and #22).
- **Silent-fallback design issue:** when the requested app can't be targeted, the tool returns the frontmost app's state with no error/warning — misleading; caller thinks they got the requested app.

### click
**Browser (Safari):** ⚠️ Clicked New Tab button (#56). Tool returned `"Click failed for element 56. Try a different element or use perform_secondary_action."` — **but the click actually succeeded** (a second tab opened, confirmed by user). **False-negative failure report.** Likely AXPress returns a non-success code on web-toolbar controls while the action still takes effect; the wrapper should verify state change before declaring failure.
- Related (tree output, low severity): the AX dump emits the menu bar node multiple times (1→2→3 across successive calls). User confirms only ONE real menu bar in the UI, so this is a **tree-serialization artifact**, not a duplicate UI element. Resets to 1 on server restart, then re-accumulates ~1 per snapshot.

**Electron (VS Code):** ❌ **`click` does NOT establish keyboard focus.** A coordinate click at (950,250) squarely in the demo.txt editor reported success (`CGEventPostToPid`) but did not move the caret/focus into the editor — a subsequent `type_text` went to the previously-focused agent composer instead, and demo.txt stayed empty (Ln1 Col1, ghost text intact). The background CGEventPostToPid click is not registering as a real focus-changing click in Electron web content. (Corrects an earlier assumption: the composer typing "worked" only because the user had already focused the composer, NOT because our click focused it.)

### type_text
**Browser (Safari):** ✅ Typed `example.com` into the address bar (#54); autocomplete suggestions appeared. User: "worked perfectly."
**System (TextEdit):** ✅ Typed a 44-char sentence into the text area (#2); document marked "Edited". User: "worked perfectly within the app."
- 🐛 **action_feedback `change_summary` is inaccurate (user cares about this):** reported `+10` for an 11-char string (Safari) and `+8` for a 44-char string (TextEdit). Does not reflect actual characters inserted.
- 🐛 **action_feedback `cursor_before`/`cursor_after` always (0,0)** in both apps — cursor position not tracked.

**Electron (VS Code, demo.txt + agent CHAT composer):**
- ❌ `type_text` with no element (relying on existing focus) into the editor → **false-positive**: reported success (`+11`) but editor stayed empty (Ln1 Col1, ghost text intact); confirmed unchanged after `wait`.
- ❌ Same false-positive typing into the focused agent composer.
- ⚠️ Text landed in the composer ONLY because the user had manually focused it; a later test showed our coordinate `click` does NOT actually move Electron focus (see click§Electron), so click-then-type into the editor failed (text leaked back to the composer).
- **Conclusion:** On Electron, `type_text` only works if the target already has real keyboard focus. mac-cua cannot currently establish that focus itself (neither the "current focused element" path nor a background `click` reaches Electron web inputs), yet it reports success anyway. Native apps don't need this.
- Stale window node title: AX node 0 reads `index.html` while the real window is `demo.txt — temp`.

### set_value
**Browser (Safari address bar #54):** ⚠️ **False-negative** (same class as `click`). Tool returned `"Cannot set value of element 54. Element may not support direct value setting. Try type_text with element_index instead."` — but the value WAS applied: address bar changed to `wikipedia.org` and triggered the Wikipedia autocomplete dropdown.
**System (TextEdit text area #2):** ⚠️ **Same false-negative** on a plain native AXValue text area. Tool returned the identical `"Cannot set value of element 2..."` error, but the multi-line value WAS fully applied (replaced existing text with both lines).
**Electron (VS Code, node 1 `container (settable, string)`):** ❌ **True negative** — same `"Cannot set value of element 1..."` message AND nothing changed (editor empty, composer placeholder). The one element advertised as `(settable, string)` is the Electron window root (stale title "index.html") and is NOT actually settable → **misleading AX `settable` flag**.
- **Conclusion:** `set_value`'s return status is **uniformly "Cannot set value" and therefore useless as a signal** — it reads identical whether the value was actually applied (native/browser false-negative) or genuinely failed (Electron true-negative). Two distinct fixes needed: (a) correct success/failure detection, (b) stop flagging non-settable Electron containers as `settable`. Electron has no working AX-direct value surface.

### change_summary root cause (action_feedback) 🐛 IMPORTANT
`change_summary` is NOT measuring the text edit — it equals the number of nodes in the
**duplicated menu bar** that leaks into the tree each snapshot:
- Safari menu bar = 10 nodes → reported `+10`
- TextEdit menu bar = 8 nodes → reported `+8`
- VS Code menu bar = 11 nodes → reported `+11`
The per-snapshot menu-bar duplication pollutes the tree diff; the real text change shows as
`~0`. Fixing the menu-bar duplication leak should fix both the bloated tree AND change_summary.
