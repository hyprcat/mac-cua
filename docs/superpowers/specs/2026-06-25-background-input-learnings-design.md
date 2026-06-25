# Swift Port — Background-Input Fidelity Improvements (cua-driver learnings)

**Date:** 2026-06-25
**Branch:** ralph/swift-port-completion
**Status:** Approved design

## Goal

Incorporate the publicly-documented learnings from Cua's `cua-driver` blog post
("Inside macOS window internals") into mac-cua, **without** violating the Prime
Invariant (Inv 18: never foreground / activate / raise a target window). An audit
of the article against the codebase showed mac-cua (a Swift port of the same
Python driver) already implements the core recipe — SkyLight `SLEventPostToPid`
targeted delivery, window-local coordinate stamping, authenticated keyboard
delivery, and the CGEvent trust telemetry. Four net-new items remain:

| ID | Item | Why it's net-new |
| --- | --- | --- |
| US-057 | Chromium user-activation **primer click** | Confirmed absent. Off-screen decoy gesture that ticks Chromium's user-activation gate so web-content actions (video play/pause, `window.open`, fullscreen) land. Invariant-safe (off-screen, pid-scoped, no raise). |
| US-058 | **Capture modes** `som`/`ax`/`vision` | Today snapshot always returns tree+screenshot. An `ax`-only mode lets the driver run with **no Screen Recording permission**. |
| US-059 | **Remote-aware AX observer** for occluded Electron | `_AXObserverAddNotificationAndCheckRemote` keeps occluded Electron AX trees firing notifications. Not a correctness fix (re-walk is already the source of truth) — improves snapshot freshness + settle/wait timing. |
| US-060 | **Known-limitation docs + structured error** | Web-content right-click coercion and canvas/GHOST apps (which need foreground, forbidden by Inv 18) should fail loudly + be documented. mac-cua is intentionally *stricter* than upstream here. |

## Non-goals (YAGNI)

- No foregrounding / focus-without-raise / `micro_activate` — forbidden by Inv 18,
  even though upstream `cua-driver` uses it (and falls back to full activation for
  canvas apps). mac-cua does not.
- No browser extension for true web-content right-click.
- No canvas/game support (Blender GHOST, Unity) — explicitly unsupported.
- No refactor of the verified C2/C5 trust-stamp paths (rejected Approach 3).

## Cross-cutting design

- **Core/Kit discipline:** every decision lives in pure, Linux-testable `MacCUACore`
  behind an injectable seam; macOS-only execution lives in `MacCUAKit` under
  `#if os(macOS)`. Mirrors the existing `ClickDelivery` (Core plan) → `KitInputProvider`
  / `KitSkyLightProvider` (Kit post) split.
- **Flags** (`Flags.swift` pattern — property + snake_case in `fieldNames` + get/set
  switch + `MAC_CUA_FLAG_*` env override):
  - `click_primer` — default **true** (kill-switch for US-057).
  - `electron_remote_observer` — default **true** (kill-switch for US-059).
  - Capture mode is a **tool param**, not a flag.
- **Invariant compliance:** US-057 posts off-screen pid-scoped events through the
  existing trusted channel (no warp/raise) → Inv 18 holds. US-059 adds an
  **optional dlsym-gated** symbol → Inv 17 holds (never a hard dep; absence
  degrades to the public observer API). US-058/US-060 are read-only / text.
- **Test strategy:** pure-Core unit tests run on Linux CI (`Tests/MacCUACoreTests`,
  `Tests/MacCUAServerTests`); macOS acceptance tests + a `manual_verify/` script
  cover the empirical pieces (the primer gate is the one thing that *must* be
  proven on real Chrome).

---

## US-057 — Chromium user-activation primer click

**Behavioural policy (decided):** auto-fire **only** when the surface is
Chromium-class (`AppKind.browser` / `.electron`) **and** the click is a
coordinate/pixel click (not an `element_index` AX-action click), gated by the
`click_primer` flag. No primer on native apps or AX-action clicks (Chromium
discards it everywhere else anyway).

### Pure-Core (`MacCUACore`)
- **New `ClickPrimerPolicy.swift`:**
  ```
  enum ClickKind { case pixel, axAction }
  enum ClickPrimerPolicy {
    static func shouldPrime(surface: AppKind, clickKind: ClickKind, flagEnabled: Bool) -> Bool
    // true  iff  flagEnabled && surface ∈ {.browser, .electron} && clickKind == .pixel
  }
  ```
  Reuses the existing `AppKind` used by `EnhancedUI`.
- **Extend `ClickDelivery.swift`:** add `isPrimer: Bool = false` to `ClickEventStep`
  (default keeps existing `sequence(count:)` and its tests byte-identical) and a new
  `sequence(count:includePrimer:)` that prepends **one** primer down/up pair
  (pressure 0 — a discard gesture) marked `isPrimer = true`. Core owns the *shape*;
  Kit owns the *coordinate*.

### Kit (`MacCUAKit`)
- The primer fires **only on the SkyLight trusted path** (`KitSkyLightProvider.deliverMouse`)
  — that is the channel Chromium trusts. If SkyLight is unavailable, the primer is a
  no-op (web content wouldn't work via the CGEvent fallback regardless, per the article).
- Primer steps inherit the existing C2/C5 trust stamps for free.
- `clickAt` orchestration: the spine computes `ClickPrimerPolicy.shouldPrime(...)` and
  passes a `prime: Bool` through the extended `InputProvider.clickAt` signature
  (`Providers.swift`). On `prime`: post primer pair at off-screen coord → ~5 ms gap →
  real click.

### Coordinate semantics — the one empirical unknown
The article primes at **screen** `(-1,-1)` ("outside every window"); mac-cua's trusted
path posts **window-local** coords + a windowId stamp.
- **Primary:** primer at **window-local `(-1,-1)`** via the trusted channel — stays
  trusted, misses every hit-test.
- **Fallback** (if on-device Chrome does not tick the gate): a true
  screen-outside-all-windows coordinate.
- **Must be verified on real Chrome** — `manual_verify/` script exercising YouTube
  fullscreen toggle and/or `window.open`. This is the single piece that cannot be
  settled by unit tests.

### Tests
- Core: `shouldPrime` truth table (browser/electron/native × pixel/axAction × flag);
  `sequence(count:includePrimer:)` step shape (primer first, marked, pressure 0,
  real clicks unchanged). Existing `sequence(count:)` tests stay green.
- macOS: acceptance that a primed click posts an extra off-screen pair before the
  real one; manual-verify backlog entry for the Chrome gate.

---

## US-058 — Capture modes (`som` / `ax` / `vision`)

### Pure-Core (`MacCUACore`)
- **New `CaptureMode.swift`:**
  ```
  enum CaptureMode: String { case som, ax, vision }   // default som
  extension CaptureMode {
    var plan: (captureTree: Bool, captureScreenshot: Bool)
    // som → (true, true)   ax → (true, false)   vision → (false, true)
  }
  ```

### Server / spine
- Add an optional `mode` param (enum `som|ax|vision`, default `som`) to `get_app_state`
  in `ToolDefs.swift`; parse with the existing input-parsing helpers.
- The snapshot handler honours the plan: skip the AX walk when `!captureTree`
  (`vision`), and **never invoke the screen-capture API** when `!captureScreenshot`
  (`ax`). Not invoking it (vs discarding the result) is what delivers the
  **no-Screen-Recording-permission** benefit.

### Constraints / back-compat
- Default `som` == today's behaviour → fully back-compatible.
- `vision` has no AX tree → no `element_index` addressing; `element_index` clicks
  require `som`/`ax`. Documented in the tool description and `KNOWN_LIMITATIONS.md`.

### Tests
- Core: `CaptureMode.plan` mapping for all three.
- Server: `mode` parse/validation + default; snapshot populates only the planned
  fields (fake capture/accessibility providers assert the screenshot API is **not**
  called in `ax` mode).

---

## US-059 — Remote-aware AX observer (occluded Electron)

### Plumbing (`CSkyLightShim` + `MacCUACore`)
- Add `_AXObserverAddNotificationAndCheckRemote` via the **same optional resolver**
  (`csky_resolve_symbol` finds it in already-linked ApplicationServices). New typedef
  in `CSkyLightShim.h`; resolved individually; **never required** (Inv 17).
- The resolve-or-fallback **decision** is a pure seam (mirrors `SkyLightAvailability`):
  "use remote variant if resolved, else public `AXObserverAddNotification`."

### Kit
- The InvalidationMonitor (port of `observer.py:TreeInvalidationMonitor`) registers
  with the remote-aware variant **when resolved + `electron_remote_observer` flag on**,
  else the public API.

> **Implementation outcome (DORMANT — premise N/A).** During wiring we confirmed
> mac-cua registers **no** `AXObserver` anywhere: per §5.3 it deliberately
> replaced the unreliable AXObserver correctness path with polling (`SettlePoller`
> + liveness-probe re-walk). The occluded-Electron *notification-pause* problem
> this SPI solves therefore does not arise — there is nothing to upgrade, and
> wiring an observer would contradict §5.3. The pure plumbing (shim typedef +
> `RemoteObserverSupport` chooser + tests + `electron_remote_observer` flag)
> ships as documented, tested, parity-complete capability and is marked dormant;
> it is the invariant-safe chooser a future optional observer-driven settle
> *accelerator* would use. Intentionally unwired.

### Honest framing
- **Correctness is unchanged** — `RefetchableTree` already treats AX observers as a
  fast-path optimisation, not a correctness gate (re-walk + liveness probe is the
  truth, per §5.3). The benefit is: (1) fresh snapshot fast-path on occluded Electron
  (fewer redundant re-walks), and (2) **reliable settle/wait timing** there — priming
  ("web content appeared") and settle detection stop depending on notifications an
  occluded window never sends. Not a final-state correctness fix.

### Tests
- Core: the pure resolve-or-fallback decision (symbol present → remote; absent →
  public). Symbol-removal resilience assertion (remote symbol never in any required set).
- macOS: register on a real occluded Electron app (VS Code / Slack), mutate, confirm
  an invalidation fires (manual-verify backlog).

---

## US-060 — Known-limitation docs + structured error

### Docs
- **New `docs/KNOWN_LIMITATIONS.md`:**
  1. Web-content **right-click coerced to left** on non-AX paths; AX secondary-action
     still works for AX-addressable targets.
  2. **Canvas / GHOST / Unity / games** need foreground activation → **forbidden by
     Inv 18** → unsupported. Explicitly *stricter* than upstream `cua-driver` (which
     falls back to activation and warps the cursor).

### Structured error (`MacCUACore`)
- New error variant (e.g. `unsupported_canvas_surface`) returned instead of a silent
  dropped click, with a clear message ("this surface requires window activation, which
  mac-cua does not perform by design — Prime Invariant").
- **Detection is best-effort:** a small known-canvas heuristic (bundle-id / window-role)
  for an up-front error, **plus** an outcome-verification *hint* ("no effect — may be a
  canvas surface requiring foreground") when a pixel-click on a non-AX surface verifies
  as a no-op. Deliberately modest — a hint, not a detection engine.

### Tests
- Core: error variant formatting/code; heuristic classification table.
- Server: outcome-verification adds the hint on no-op pixel-click against a non-AX,
  known-canvas surface.

---

## Rollout / sequencing

1. **Wave 1 (parallel, file-disjoint pure-Core):** US-057 Core (`ClickPrimerPolicy` +
   `ClickDelivery`), US-058 Core (`CaptureMode`), US-059 plumbing (shim + symbol +
   pure decision), US-060 Core (error variant + docs). No shared files.
2. **Integration (single hand):** cross-cutting wiring — `Flags.swift`,
   `Providers.swift` (protocol), `ToolDefs.swift`, spine handlers. Quality gate.
3. **Wave 2 (parallel, Kit-side):** primer posting, capture-mode gating, remote
   observer registration — separate Kit files.
4. Per-story: `swift build` + `swift test` green, commit, `ralph/progress.txt` entry,
   manual-verify backlog note.

## Acceptance

- All four flag/param-gated, default behaviour unchanged (`click_primer` on but
  scoped; `som` default; remote observer optional; errors only on actually-failing
  surfaces).
- Linux CI stays green (all new decisions are pure Core).
- No new foregrounding path anywhere (Inv 18); no new hard symbol dependency (Inv 17).
- Primer verified on real Chrome (manual-verify) before US-057 is marked done.
