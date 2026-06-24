# US-050 — macOS-26 Release-Gate Audit (invariants + Python parity)

Date: 2026-06-24. Branch: `ralph/swift-port-completion`.
Gate at audit time: `swift build` clean; `swift test` **842 passed / 0 failed**.

This is the release-gate walk required by US-050: the design §3 invariant checklist and the
Python (`app/`, `app/_lib/`) feature set were walked against the Swift port. Any residual gap is
filed below as a follow-up. **No real functional gaps were found** — every "missing" Python class is
either deferred-by-design to a macOS-integration story already in the PRD, or a pure-logic seam already
ported to `MacCUACore`.

## §3 invariant checklist — all 23 SATISFIED

| # | Invariant | Status | Evidence |
|---|-----------|--------|----------|
| Prime | No foreground/activate/cursor-warp/global-post | OK | guarded by `InvariantGuardTests` banned-symbol scan (US-012); 0 banned symbols in `Sources/` |
| 1 | Synthetic input only via `postToPid` | OK | `KitInputProvider` — all posts `.postToPid(pid)` |
| 2 | No cursor warp; window-hint fields | OK | `KitInputProvider.decorateMouseEvent` (windowUnderMousePointer + ThatCanHandle); no `CGWarpMouseCursorPosition` |
| 3 | Modifiers as flags, never discrete flagsChanged on postToPid | OK | `PressKeyPlan`/`KitInputProvider`; discrete only on SkyLight path |
| 4 | Per-session private `CGEventSource(.privateState)` + echo field 45 | OK | `KitEventSource`, `KitOutcomeMonitor` field 45 |
| 5 | Monitoring taps listen-only | OK | `KitOutcomeMonitor` / `KitUserInteractionMonitor` `.listenOnly`, callback returns event untouched |
| 6 | Dual scroll deltas (point + fixedPt) | OK | `KitInputProvider.scrollPidPixel` sets line/point/fixedPt + isContinuous |
| 7 | Reads never activate; copy/read APIs only | OK | `KitAccessibilityProvider` — no AXMain/AXFocused writes on read |
| 8 | AX refs never reach model; scrub pointer strings | OK | `Serialize.swift` axElementRegex scrub; `InvariantGuardTests` leak guard |
| 9 | OOP detection by PID | OK | `AXWalk` `isOop = targetPid != elementPid` |
| 10 | `-25205`/`-25212` → stale recovery | OK | `Errors.axError` mapping → `staleReference` |
| 11 | PID-scoped ref-counted write assertions, balanced | OK | `KitAccessibilityProvider.withWriteAssertion` / `KitAXEnablement` |
| 12 | Preorder reverse-push DFS, monotonic depth | OK | `Pruning.swift` flat array + depth-based index builders |
| 13 | Capture by window id, no foreground, cursor excluded | OK | `KitCaptureProvider` SCK + `showsCursor=false` |
| 14 | Launch `activates=false` (+ `open -g`) | OK | `KitAppResolver` config.activates=false, `open -g` fallback |
| 15 | Focus enforcement observe-only; only restore prior frontmost | OK | `KitAppResolver.restoreFrontmostApp` (sole sanctioned activation) |
| 16 | Yield on user interaction with driven app | OK | `UserInteractionMonitoring` + `UserInteractionState` debounce + one-shot warning |
| 17 | Every private symbol optional → nil → no-op | OK | `SkyLightSymbols`/`SkyLightAvailability` per-symbol resolution |
| 18 | Micro-activation FORBIDDEN; fail honestly | OK | `SetFrontmost` never ported; input failure throws |
| 19 | `validate_window_owner` assume-valid when unverifiable | OK | `WindowOwnerValidation` falls through to assume-valid |
| 20 | Transport ≠ outcome → DELIVERED_NO_EFFECT | OK | `Verdict.computeVerdict` |
| 21 | Snapshot is ground truth; inline AX verify disabled | OK | `Verdict.swift`; `KitOutcomeMonitor.verifyAX` returns `.timeout` |
| 22 | Indices dense 0..N-1, pre-order, at end of pruning | OK | `Pruning.swift` final reindex loop |
| 23 | Token-light; prune before serialize; caps; announced truncations | OK | `Serialize`/`Pruning` caps + explicit truncation notices |

The banned-symbol scan, leak guard, and M4 regression guards in
`Tests/MacCUACoreTests/InvariantGuardTests.swift` are the standing automated enforcement for the
Prime Invariant and Inv 8 across all of `Sources/` (Core + Server + Kit).

## Python parity — no missing behavior

All pure-logic Python modules (`observer`, `tree`, `markdown_writer`, `keys`, `retry`, `flags`,
`virtual_cursor`, `confirmed_verification`, `action_verification`, `safety`, `errors`,
`refetchable_tree`, `graphs`, `pruning`, `response`, `lifecycle`, `tracing`) are ported to
`MacCUACore`/`MacCUAServer`. The macOS-adapter modules (`accessibility`, `apps`, `input`,
`screen_capture`, `selection`, `screenshot`, `focus`, `event_tap`, `delivery_tap`) live in
`MacCUAKit` behind `#if os(macOS)` and are exercised by their fake-backed unit tests; their real-app
behavior is tracked in the Manual-Verify Backlog (US-015..047).

## Residual gaps filed as follow-ups

None new. The only behavior not yet in the Swift port is the **ghost-cursor overlay** suite, already
captured as PRD stories **US-051..US-056** (GhostCursorOverlay AppKit panel, window tracking,
multi-cursor identity, animations, occlusion clipping v2, multi-session acceptance test). These are
the next stories in the queue and require no additional filing.

## MANUAL-VERIFY (release smoke, target macOS 26, background-only)

A human must run a full read+write smoke across Safari (web), Slack (Electron), and a native Cocoa app
on the target macOS, driving each strictly in the background, and confirm: `get_app_state` returns a
populated pruned tree; `click`/`type_text`/`scroll`/`set_value` land via the background delivery path;
and NOTHING foregrounds, activates, raises, or moves the cursor at any point. This is the standing
release sign-off and aggregates the per-story Manual-Verify Backlog items above.
