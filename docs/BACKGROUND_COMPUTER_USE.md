# How mac-cua Achieves Background Computer Use

A from-scratch technical write-up of the mechanisms, SPIs, and design reasoning
behind driving macOS apps **in the background** — clicking, typing, scrolling, and
reading the screen of windows the user can't even see, **without ever stealing
their mouse, keyboard, or focus**.

> Scope: this describes the Swift implementation under `swift/` (a port of the
> original Python `app/`). File references are to `swift/Sources/...`. Where the
> reasoning is subtle, the original Python module is cited too.

---

## 1. The problem, stated precisely

"Computer use" agents normally drive a Mac the way a human does: move the real
mouse to a coordinate, post a global click, type into whatever is focused, take a
full-screen screenshot. This is the **HID-injection** model. It works, but it has
a fatal property for a *useful* agent: **it fights the user for the machine.**
Every click warps their cursor, every keystroke lands in their focused app, every
screenshot is of whatever happens to be on top. You cannot run it while you work.

mac-cua targets the opposite operating point, captured in one rule we call the
**Prime Invariant**:

> **The agent must NEVER steal the user's keyboard input, window focus, or mouse
> cursor. There is no fallback that foregrounds, activates, raises, or warps the
> cursor.**

Concretely (from `docs/SWIFT_PORT_DESIGN.md` §1.1):

- Input is delivered **per-process**, never via global HID injection.
- The OS cursor is **never moved**. No `CGWarpMouseCursorPosition`, no posted
  `mouseMoved`.
- Apps are **never** activated/raised — not even the invisible sub-10ms
  "micro-activation" trick the original code once used. When no background path
  works, the action **fails honestly** instead of foregrounding.
- Capture reads a window's **backing store by ID** without bringing it forward,
  with the user's cursor excluded from the image.
- When the user touches the app we're driving, the agent **yields**.

Everything below is in service of that rule. The hard part is not "can we click" —
it is "can we click a *background* window, confirm it landed, and read the result,
using only mechanisms that never touch the user's session." That requires going
underneath the public macOS APIs into the **window server's private SPIs**.

---

## 2. macOS foundations (from scratch)

To understand the mechanisms you need five pieces of the macOS architecture. Most
developers never see these because the public frameworks hide them.

### 2.1 The WindowServer, connections, and PSNs

Every GUI process on macOS talks to a single system daemon — the **WindowServer**
(historically "CoreGraphics Server", hence the `CGS` prefix). The WindowServer owns
the actual pixels, the window stacking order, event routing, and the display
hardware. Apps don't draw to the screen; they hand buffers to the WindowServer.

Key identifiers in this world:

- **CGSConnectionID (`cid`)** — a 32-bit handle for one process's link to the
  WindowServer. Your own connection is `CGSMainConnectionID()`. Every window is
  *owned* by some connection.
- **CGWindowID (`wid`)** — a 32-bit global ID for a window, unique across all apps.
  This is the same number you see in `CGWindowListCopyWindowInfo`. (Note: IDs are
  **recycled** when windows close — a cache hazard we handle in §6.2.)
- **ProcessSerialNumber (`PSN`)** — an older 8-byte process identifier (a hold-over
  from the Carbon era) that the event-routing layer still uses. A PID is *not* a
  PSN; you have to translate.

The WindowServer is what makes background delivery *possible at all*: because it,
not the app, routes events, you can ask it to route a synthetic event to a specific
window/process **without** that process being frontmost. The public API won't let
you do this; the private SkyLight API will.

### 2.2 CGS vs. SkyLight

"CGS" (CoreGraphics Services) and "SkyLight" are two generations of the same
private window-server client library:

- Old symbols are exported from **CoreGraphics** with a `CGS` prefix.
- Modern macOS moved the implementation into a private framework at
  `/System/Library/PrivateFrameworks/SkyLight.framework`, with `SLS`/`SLEvent`
  prefixes.

This matters because **macOS 26 removed several of the old `CGSPost*EventToProcess`
input SPIs.** The modern, verified-working background-delivery path is the
SkyLight `SLEvent`/`SLS` family. We target that, keep CGS only for stable
connection/owner *queries*, and treat **every** private symbol as optional (§9).

### 2.3 The Accessibility (AX) layer

Separately from pixels, macOS exposes a semantic tree of every UI element via the
**Accessibility API** (`AXUIElement`). This is what VoiceOver reads. For each app
you can get an `AXUIElementCreateApplication(pid)` root and walk children:
buttons, text fields, rows, web areas — each with a role, label, value, position,
size, and a set of *actions* (`AXPress`, `AXShowMenu`, `AXConfirm`).

The AX tree is the agent's **structured map of the screen**. Crucially, **reading
it never activates the app** — `AXUIElementCopyAttributeValue` is a pure read. And
many actions can be performed *through* AX (`AXPress` a button) without any
synthetic mouse event at all — the cleanest possible background action.

Two important wrinkles, both handled later:

1. Chromium/Electron apps ship an **empty** AX tree until you ask for it (§5.3).
2. AX references go **stale** when the tree changes; you must detect and rebind
   (§5.5).

### 2.4 CGEvent — synthetic events

A `CGEvent` is the kernel-level representation of an input event (a mouse down, a
key press, a scroll). The public way to inject one is `CGEvent.post(tap:)`, which
shoves it into the global HID stream — **exactly what we must never do.** But
there is also `CGEvent.postToPid(_:)`, which delivers an event **to one process's
event queue**. The process receives it as if it were focused, but the global
cursor and focus are untouched. This is the cornerstone of background input.

A CGEvent is also a bag of numbered **fields** (`CGEventField`) — pressure, click
state, scroll deltas, a window-under-pointer hint, a source-state ID, and more.
Stamping the right fields is what makes a `postToPid` event actually land on the
right window. The full table we use lives in `CGEventFields.swift`.

### 2.5 ScreenCaptureKit — capturing one window

The modern capture API, `ScreenCaptureKit` (SCK), can capture a **single window by
its backing store**, even if it is occluded or off-screen, with no activation and
the cursor excluded. `CGWindowListCreateImage` (the old way) **returns NULL on
macOS 26** and is dead to us. SCK is the primary; a private GPU one-shot is the
fallback (§6).

---

## 3. Architecture: the Core/Kit seam

The codebase is split so that *all the decision logic* is pure and the *macOS
syscalls* are a thin, swappable layer. This is not cosmetic — it is how we test
the invariant-critical logic on Linux CI and keep the dangerous code small.

```
MacCUACore   — PURE logic, no CoreGraphics import. Builds & unit-tests on Linux.
               Models · Pruning · TreeGraph · RefetchableTree · KeyParser ·
               InputStrategy · Verdict · ClickDelivery (the *plan*) · field tables ·
               SkyLight branch logic · Safety · WindowOwnerValidation
               + protocols: AccessibilityProvider, InputProvider, CaptureProvider,
                            SkyLightProviding, SettleMonitor, OutcomeMonitor, …

MacCUAServer — the orchestration spine (SessionManager actor) + MCP tools.
               Depends only on Core protocols → runs against fakes on Linux.

MacCUAKit    — the REAL macOS implementations (#if os(macOS)).
               KitInputProvider (CGEvent) · KitSkyLightProvider (dlsym SPIs) ·
               KitCaptureProvider (SCK) · KitAccessibilityProvider · observers · ghost cursor

CSkyLightShim — a C target: function-pointer typedefs + a dlsym resolver for the
                private SkyLight/CGS symbols. Declared as POINTERS so importing it
                creates no link dependency on the private frameworks.
```

The pattern repeats per capability: **Core owns the *shape* of the action; Kit
owns the *coordinate* and the syscall.** Example: `ClickDelivery.sequence(...)` (in
Core) decides "primer down/up, then real down/up, with this pressure and click
state," and is unit-tested on Linux. `KitInputProvider`/`KitSkyLightProvider` take
that plan and post the actual events. Both transports (CGEvent and SkyLight) drive
the *same* Core plan so they emit byte-identical event shapes.

---

## 4. Input delivery — the heart of it

This is where "background" is won or lost. There are three layers, tried in
fidelity order, each falling through to the next on *any* failure and **never**
foregrounding.

### 4.1 Layer 0 — the naive approach, and why it fails

The obvious implementation: `CGWarpMouseCursorPosition(target)` then
`CGEvent.post(tap:)` a click. This works and is what most automation does. It
violates the invariant three ways: it warps the user's cursor, it posts globally
(so whatever is under the *real* pointer can get it), and focus follows. Rejected
entirely. There is no code path that warps or posts globally — an invariant test
asserts those symbols are unreachable from the input path.

### 4.2 Layer 1 — the CGEvent base path (`postToPid`)

`KitInputProvider.swift` is the always-available native path, a faithful port of
the base functions in Python's `input.py`. Its contract (file header):

- Delivery is **only** via `CGEvent.postToPid(_:)` — never `post(tap:)`. *(Inv 1)*
- The cursor is **never** warped: no `CGWarpMouseCursorPosition`, no pre-positioning
  `mouseMoved`. The down/up events **carry the target point directly** in
  `mouseCursorPosition`, and a **window-under-pointer hint field** handles routing.
  *(Inv 2)*
- Modifiers ride as **flags on the key event** (`CGEventSetFlags`), never as
  discrete `flagsChanged` posted to the pid (that would corrupt the user's live
  modifier state). *(Inv 3)*
- Each session uses a **private `CGEventSource(stateID: .privateState)`** so
  concurrent sessions never share HID state and our events are taggable. *(Inv 4)*

The click itself (`postClick`, `KitInputProvider.swift:158`):

```swift
for step in ClickDelivery.sequence(count: count) {     // Core-owned plan
    let down = CGEvent(mouseEventSource: source, mouseType: downType,
                       mouseCursorPosition: point, mouseButton: btn)
    decorateMouseEvent(down, windowId: windowId, pressure: step.pressure,
                       clickState: ..., eventNumber: nextEventNumber())
    down.postToPid(pid_t(pid))         // ← per-process delivery, no global post
    Thread.sleep(forTimeInterval: 0.005)
    // ... matching mouseUp ...
}
```

`decorateMouseEvent` stamps two fields that make routing work without a cursor
move (`KitInputProvider.swift:135`):

```swift
event.setIntegerValueField(.mouseEventWindowUnderMousePointer, windowId)              // field 91
event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, windowId)  // field 92
```

These tell the WindowServer "treat this as if it occurred over window N" — routing
metadata, **not** a warp. This is the key trick: the *event* carries the target,
the *cursor* never moves.

Keyboard, scroll, and drag all live here too and obey the same rules:

- **Keyboard** (`postKeyEvent`): `event.flags = CGEventFlags(rawValue: modifiers)`
  — modifiers as flags, then `postToPid`. Unicode text uses
  `keyboardSetUnicodeString` per grapheme so emoji/accents stay one keystroke.
- **Scroll** (`scrollPidPixel`): sets **every** delta axis on one event — integer
  *point* deltas (fields 96/97, read by Chromium/Electron) **and** double
  *fixed-point* deltas (93/94, read by native Cocoa) **and** coarse *line* deltas
  (11/12, for discrete-wheel apps), plus `isContinuous`=1 (field 88). Setting all
  three families is why scroll works across the whole app zoo. *(Inv 6)*
- **Drag** (`drag`): a left-down, 10 interpolated `leftMouseDragged` steps, a
  left-up — all `postToPid`, all carrying their points directly.

This path is **guaranteed to exist** (no private symbols) and is the primary for
native Cocoa apps. For Chromium/Electron and for higher fidelity, Layer 2 runs
first.

### 4.3 Layer 2 — SkyLight targeted mouse delivery

Native `postToPid` clicks are sometimes ignored by apps that hit-test against the
**window server's** notion of "what window is under the pointer" — notably Chromium
and Electron. To satisfy them we build the event the way the WindowServer itself
would and post it through SkyLight's per-PID channel.

The *plan* is pure (`SkyLightMouseDelivery.swift`); the *posting* is in
`KitSkyLightProvider.deliverMouse` (`KitSkyLightProvider.swift:121`). Steps:

1. **Build an NSEvent-backed CGEvent** via
   `+[NSEvent mouseEventWithType:…windowNumber:windowId…].cgEvent`. Going through
   NSEvent makes the WindowServer associate the event with `windowId` properly —
   better than hand-rolling a CGEvent.
2. **Stamp public fields** (`SkyLightMouseDelivery.cgStamps`):
   - `mouseEventSubtype` (field 7) = `3` (tablet-proximity subtype — observed to
     make routed events behave),
   - `windowUnderMousePointer` (91) = `windowId`,
   - `…ThatCanHandleThisEvent` (92) = `windowId`.
3. **Set window-local coordinates** via `CGEventSetWindowLocation(event, pt)` —
   note this is a **SkyLight export**, not CoreGraphics. The point is in the target
   window's own coordinate space. Routing metadata, not a warp.
4. **Stamp the target pid** in **field 40** via the private
   `SLEventSetIntegerValueField(event, 40, pid)`.
5. **Post** via the private `SLEventPostToPid(pid, event)`.

```swift
guard capabilities.canDeliverMouse,
      let post = fnEventPostToPid,            // SLEventPostToPid
      let setSkyInt = fnEventSetIntegerValueField,
      let setWindowLocation = fnEventSetWindowLocation else { return false }   // ← absent? fall to Layer 1
// build NSEvent → .cgEvent, stamp 7/91/92, setWindowLocation(local),
// SLEventSetIntegerValueField(e, 40, pid), then:
post(Int32(pid), event)
```

If **any** symbol is missing or any step fails, `deliverMouse` returns `false` and
the caller falls through to Layer 1 — it **never foregrounds** *(Inv 18)*. On
Linux/CI and on hosts where the symbols don't resolve, Layer 1 is the transport.

### 4.4 Layer 2 — SkyLight authenticated keyboard delivery

Keyboard is harder than mouse because modern macOS **authenticates** keyboard
events posted to a background process — an unauthenticated key event to a window
the user isn't focused on is dropped. The recipe (`SkyLightKeyboardDelivery.swift`
plan + `KitSkyLightProvider.deliverKeyboard`, `:186`):

1. Build a CGEvent keyboard event from the **per-session private source**.
2. Set modifiers as **flags** (`event.flags = cgEventFlags(modifierMask)`) — never
   discrete `flagsChanged`. *(Inv 3 — the chokepoint that protects the user's
   physical keyboard.)*
3. Resolve the **window owner's PSN**: `SLSGetWindowOwner(cid, wid, &ownerCid)` →
   `SLSGetConnectionPSN(ownerCid, &psn)`. (Window → owning connection → process
   serial number.)
4. **Authenticate** the event:
   `+[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:]` (resolved
   via the ObjC runtime, since it's a class method with mixed C/object args) →
   `SLEventSetAuthenticationMessage(event, msg)`.
5. **Deliver on two routes** for robustness
   (`SkyLightKeyboardDelivery.deliveryRoutes`):
   - Route 1: the authenticated `SLEventPostToPid(pid, event)`.
   - Route 2: a secondary `CGEventPostToPSN(&psn, event)` to the resolved owner.

Again: any missing symbol → `false` → fall to the Layer-1 CGEvent keyboard path,
never foreground.

### 4.5 Why the AX path is preferred when it exists

The cleanest background action isn't a synthetic event at all — it's telling the AX
element to perform its action: `AXPress` a button, `AXConfirm` a default control,
`AXShowMenu` for a right-click, `setValue` on a text field. No coordinates, no
WindowServer routing, no authentication. `InputStrategy` (§7) decides per app +
per element whether to go **AX-first** (native Cocoa controls) or **pointer-first**
(Chromium/Electron web content, which exposes a poor/uncooperative AX tree).

### 4.6 The Chromium user-activation primer (US-057)

Browsers gate certain web APIs (video play/pause, `window.open`, fullscreen)
behind a **user-activation** signal — they only fire if a "real" user gesture
preceded them. A background click can land yet still be treated as
non-user-initiated. The fix (`ClickPrimerPolicy.swift` + `trySkyLightClick`):

before the real click, post **one extra off-screen down/up pair** at window-local
`(-1, -1)` **through the same trusted SkyLight channel**. The decoy lands on no
window (so it does nothing visible) but **ticks Chromium's user-activation gate**,
so the real click's web action is honored. It fires **only** when:
`flagEnabled && surface ∈ {browser, electron} && clickKind == .pixel`. It's
off-screen and pid-scoped → no warp, no foreground *(Inv 18)*. It rides only the
SkyLight path (the CGEvent fallback can't satisfy the gate anyway).

---

## 5. Reading state — the AX tree without activation

A click is useless if you can't see the result. The agent's view of an app is a
**pruned, indexed AX tree** plus an optional screenshot. Reading it must also obey
the invariant: no activation, no focus changes.

### 5.1 The walk

`KitAccessibilityProvider` wraps the AX framework; `AXWalk.swift` is the pure walk
logic. Algorithm: **preorder, reverse-push DFS** over `kAXChildrenAttribute`,
producing a **flat array of `Node`** each carrying a monotonic `index` and a
`depth`:

```swift
var stack = [(root, 0)]
while let (element, depth) = stack.popLast(), nodes.count < maxNodes {
    if depth > maxDepth { continue }
    let attrs = reader.readAttributes(element)        // one batched AX round-trip
    nodes.append(Node(..., index: nodes.count, depth: depth))
    for child in children.prefix(maxChildren).reversed() { stack.append((child, depth+1)) }
}
```

Caps: `maxDepth=30`, `maxNodes=5000`, `maxChildren=100`. Attributes are read in a
**single** `AXUIElementCopyMultipleAttributeValues` per element (a batch of ~18
scalar attrs) to minimize cross-process AX round-trips. Every read uses
`AXUIElementCopy*` — **never** sets `AXMain`/`AXFocused`, never `AXRaise`. *(Inv 7)*

The walk is wrapped in a **ref-counted assertion** (`assertions.withAssertion(pid: .readAttributes)`) that balances even on throw *(Inv 11)*. Out-of-process elements
(XPC-hosted webviews) are flagged by comparing `AXUIElementGetPid(element)` to the
target pid *(Inv 9)*.

### 5.2 Pruning and stable indices

The raw tree is huge and token-expensive. `Pruning.swift` (a pure, golden-tested
port of `pruning.py`) collapses noise: drops decorative roles, merges outline rows,
caps web areas to the **newest 300** descendants (tail-biased — latest chat
messages, etc.), and **announces** every truncation rather than silently dropping.
Indices are assigned **only at the end of pruning**, in pre-order, **dense
0..N-1**. The model references elements by this index across calls, so density and
order are load-bearing *(Inv 22)*.

AX refs, graph IDs, and locators are **internal only** — `Serialize.swift` never
emits them and scrubs any leaked `<AXUIElement 0x…>` pointer strings *(Inv 8)*.

### 5.3 The Chromium/Electron lazy-tree fix

Chrome, Electron (Slack, VS Code, Discord, Obsidian), and Chromium webviews **do
not build an AX tree until a client asks** — and the *first* walk after asking
returns empty (lazy build). A naive "walk once → empty → give up" pipeline silently
misses every modern app. The fix (`EnhancedUI.swift` + `KitAccessibilityProvider`):

1. On attach, for `.electron`/`.browser` apps only, set **both**
   `AXEnhancedUserInterface` (VoiceOver's flag) and `AXManualAccessibility` =
   `true` on the **AXApplication** element. (A sanctioned config write — it does
   not focus/raise/activate.)
2. **Re-walk in a poll loop** (≤12 attempts × 100ms ≈ 1.2s budget) until the tree
   actually contains an `AXWebArea` — not merely "non-empty," because the Electron
   window chrome appears immediately while the web content builds lazily.
3. The flag is captured-and-reversible (restored on teardown), per-pid,
   remembered, and logged (it makes some apps behave as if a screen reader is
   active).

For genuinely tree-less surfaces (canvas, video, PDF-image) there's a **Vision OCR
fallback** (§6.4).

### 5.4 Binding an AX window to a CGWindowID

Input routing and capture both need the **CGWindowID** for an AX window. Primary
path: the private `_AXUIElementGetWindow(axWindow, &wid)`, resolved by `dlsym`
(`KitAccessibilityProvider.swift:35`) — a direct, exact binding. If the symbol is
absent, fall back to **scoring** candidates from `CGWindowListCopyWindowInfo` by
owner-pid + title + position/size proximity (`WindowMatch.swift`). Read-only; never
activates.

### 5.5 Staleness and refetch — accuracy under a changing tree

AX references die when the UI changes. Acting on a stale ref would click the wrong
(or a dead) element — a silent accuracy bug. We do **not** rely on `AXObserver`
notifications for this (they're known-unreliable for background/Electron windows;
see `docs/SWIFT_PORT_DESIGN.md` §5.3). Instead:

- **Liveness probe** before acting: read one cheap attribute (`AXRole`). If it
  returns a stale code (`-25202/-25204/-25205/-25212`,
  `AXStaleness.staleActCodes`), the ref is dead.
- **Re-walk + rebind**: `RefetchableTree` re-walks the tree and re-locates the
  intended element using a `GraphLocator` — a signature of role + label + axId +
  depth + a 4-deep parent-path + sibling ordinal. `TreeGraph.locatorScore`
  re-finds the same logical node even after the tree shifted, with a deterministic
  scoring/tie-break. This is the "the element the model picked is the element acted
  on" guarantee.

So the source of truth for staleness is **liveness-check + re-walk + locator
match**, computed synchronously — not a notification flag.

---

## 6. Capturing the screen — one occluded window at a time

`get_app_state` (and the snapshot after every action) optionally returns a PNG of
the **target window only**, captured from its backing store with no activation and
the user's cursor excluded.

### 6.1 Primary: ScreenCaptureKit

`KitCaptureProvider` uses SCK:

```
SCShareableContent.getExcludingDesktopWindows(...)         → find the SCWindow by id
SCContentFilter(desktopIndependentWindow: scWindow)        → that window's backing store
SCStreamConfiguration { showsCursor = false; width/height = scaled; scalesToFit = true }
SCScreenshotManager.captureImage(filter, config)           → CGImage (occluded/background OK)
```

`SCContentFilter(desktopIndependentWindow:)` is the key: it captures the window's
**own** buffer regardless of what's stacked on top, with **no foregrounding**, GPU-
scaled. `showsCursor = false` keeps the user's pointer out of the image *(Inv 13)*.
The async completion handler is bridged to sync with a `DispatchSemaphore` +
timeout.

### 6.2 The SCContentFilter cache and its hazard

Resolving the filter is expensive, so it's cached per window. But **CGWindowIDs are
recycled** — a stale filter would capture the wrong window. `CaptureFilterCache`
guards every hit with a **window signature** `(ownerPid, bounds, title)`; a
mismatch evicts. Display reconfiguration bumps a generation and invalidates all.

### 6.3 Fallback: the private GPU one-shot

If SCK fails, `KitCaptureFallback` uses the private
`CGSHWCaptureWindowList(cid, &wid, 1, opts)` with options
`NominalResolution | IgnoreGlobalClipShape` (`0x0A00`) — a pure hardware-composited
read of the window backing store, returning a `CFArray` of `CGImage`. Both
`CGSMainConnectionID` and `CGSHWCaptureWindowList` are optional `dlsym` symbols;
absent → nil, never a crash, never a foreground.

A **circuit breaker** (`CircuitBreaker.swift`: 2 consecutive failures → 30s
cooldown, time-injected for testing) skips SCK entirely after repeated failures and
goes straight to the fallback, so a wedged SCK never stalls the agent.

### 6.4 OCR for tree-less surfaces

When the AX tree is empty/near-empty (`shouldRunOCR`: `!axAvailable || nodeCount ≤ 2`), `KitOCRProvider` runs Vision `VNRecognizeTextRequest` (`.accurate`, language
correction on) over the captured image, converts Vision's normalized bottom-left
boxes to top-left pixel rects, and **merges synthetic `source: "ocr"` nodes** into
the same packet with dense continuation indices. This is the only way to address
canvas/game/video text — and it only runs when the structured path is empty (hot-
path protection).

### 6.5 Capture modes (US-058)

`get_app_state` takes a `mode`:

- `som` (default) — AX tree **+** screenshot (needs Screen Recording permission).
- `ax` — AX tree only; the screen-capture API is **never invoked**, so the driver
  runs with **no Screen Recording permission**.
- `vision` — screenshot only, no tree (so no `element_index` addressing).

`CaptureMode.plan` maps each to `(captureTree, captureScreenshot)`; the spine
honors it.

### 6.6 Downscaling and metadata

Output is sized as `windowSize × backingScale` then clamped so the longest side ≤
1920 — once on the GPU (`SCStreamConfiguration.width/height`) and again at encode
(`kCGImageDestinationImageMaxPixelSize`), belt-and-suspenders. Each image carries
`CaptureMetadata` (produced pixel size, backing scale, crop origin, windowId,
title, displayId) so the spine knows the exact coordinate mapping for the next
click.

---

## 7. Choosing the path — InputStrategy

`InputStrategy.swift` (pure, Linux-tested) is the policy brain. It classifies the
app and picks AX-first vs pointer-first per action:

- **App-type detection**: known browser/Electron bundle IDs, else a framework
  sniff (lsof → `Electron Framework` / `libjvm` / `QtCore`) → `.java`/`.qt`, else
  `.nativeCocoa`.
- **Matrix**: native Cocoa → AX-preferred for click/type/scroll/focus; Electron and
  browser-web → CGEvent/pointer-first; Java/Qt → pointer-first (poor AX).
- **Web-content gate**: any element inside a browser web area → pointer-first.
- **Auto-escalation**: after **2** AX failures, force the CGEvent path.

Concretely for a click, `shouldPreferPointerInput` walks: strategy says pointer for
this surface? → pointer. Role isn't pointer-preferred? → AX. Buttonish with no
activation action? → pointer. Inside a web container? → pointer. Else → AX.

---

## 8. The spine — what one tool call actually does

`SessionManager` is an `actor` (the sole owner of session state; the MCP handler
`await`s it). The Python got serialization free from the GIL; Swift gets it from
the actor. The `execute()` pipeline (`SessionManager.swift:42`), per action tool:

1. **Resolve target** → session (by `window_id` preferred, else app hint; launch
   non-activating if needed).
2. **Save the user's current frontmost app** — to restore later *(Inv 15)*.
3. **Safety + approval + usage** — refuse blocked apps; auto-approve session;
   prepare audit.
4. **Start the user-interruption tap** on the target pid.
5. **Resolve element + dispatch** to the handler
   (click/type/set_value/press_key/scroll/drag/secondary). Input is refused on
   terminals / locked screen here.
6. **Transient fast-path**: if a menu/popover opened, snapshot just that (skip the
   full re-walk) and return early.
7. **Settle** — `SettleMonitor.waitForSettle(timeout, quietPeriod)` with a
   per-tool budget (click 1.0s, scroll 0.3s, set_value 0.6s; quiet 0.15s). **Poll-
   based, animation-aware — never a fixed sleep** (§8.2).
8. **Interruption check** — if the user touched the app, yield (§10).
9. **Single re-walk guarantee** — if settle saw no change and the handler didn't
   already re-walk, force exactly one re-walk.
10. **Snapshot** — walk → prune → screenshot (retry once on nil) → wire
    `RefetchableTree`.
11. **Action-feedback packet** — which delivery path was used, cursor before/after,
    and a tree change-summary.
12. **Restore the user's previous frontmost** — and **only** if the target somehow
    became frontmost; never raise the target *(Inv 15)*.

Errors anywhere return a fresh snapshot + a hint, never a bare exception (the
"failproof" goal).

### 8.1 The tool surface

| Tool                         | What it does (background)                                                                                                   |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `list_apps`                | Enumerate running apps + usage. Read-only.                                                                                  |
| `get_app_state`            | Snapshot: AX walk (+ optional screenshot) with mode`som`/`ax`/`vision`. Pure read.                                    |
| `click`                    | AX action (`AXPress`/`AXShowMenu`/select) or pointer click (SkyLight→CGEvent), per InputStrategy.                      |
| `type_text`                | `AX insertText` first, else focus + CGEvent/SkyLight keyboard. Per-grapheme Unicode.                                      |
| `set_value`                | Pure-AX: set the element's value attribute; verify by read-back.                                                            |
| `press_key`                | Return/Enter/Escape →`AXConfirm`/`AXCancel`; else focus + key event. Chords supported.                                 |
| `scroll`                   | AX scroll or wheel event with all delta axes set.                                                                           |
| `drag`                     | Pure CGEvent: down + interpolated drags + up,`postToPid`.                                                                 |
| `perform_secondary_action` | Invoke a named AX action; detect menu open/close; fall back to`AXPress`.                                                  |
| `batch`                    | N actions, one call, stop-on-first-failure,**one** final snapshot; per-turn tree cache reused for element resolution. |
| `wait`                     | Drive the same settle machine with no input; return a fresh snapshot. Read-only.                                            |
| `select_text`              | Select/caret by content substring (CFRange for simple fields, AXTextMarker for web).                                        |
| `clipboard`                | Read/write/clear the pasteboard. No target, no focus change.                                                                |

### 8.2 Settle by observation, not notification

Because AX notifications are unreliable for our envelope, settle is a **polling
debounce state machine**: poll a cheap tree fingerprint (~30–40ms) until N ms of
quiet, treating changing frame rects as in-flight animation (keep waiting), with a
hard cap and early exit. Pure logic, Linux-testable. `wait` exposes the same
machine directly.

---

## 9. Verification — transport ≠ outcome

The subtlest correctness idea in the system. A background action has **two**
independent questions:

1. **Transport** — did the synthetic event reach the app's process?
2. **Outcome** — did the UI actually change?

These are orthogonal. A click can be *delivered* and still do nothing (already-
checked checkbox, disabled control). That is **not** a delivery failure, and
reporting it as one would make the agent thrash.

**Transport** is confirmed by a **listen-only** CGEventTap
(`OutcomeVerification.swift` pure half + `KitOutcomeMonitor`). Before posting, we
`mark()` a sequence high-water. The tap observes events and records only those that
**echo our private source-state ID** (field 45) — that's how we tell our own
synthetic events apart from the user's real input *(Inv 4/5)*. If a matching echo
appears after the mark (`hasEventsSince`), transport happened. The tap **never
suppresses or modifies** user events.

**Outcome** is the **fresh snapshot** — a tree change-summary (added/removed/changed
stable-key nodes). The verdict is pure (`Verdict.swift`):

- no transport → `transportFailed` (real failure);
- transport, and the action's expectation *was* transport-only (e.g. scroll) →
  `confirmed`;
- transport + any UI diff → `confirmed`;
- transport + zero diff → **`deliveredNoEffect`** (a non-failure the model is told
  about plainly).

A deliberate decision (`docs/SWIFT_PORT_DESIGN.md` Inv 21): inline post-delivery AX
verification is **disabled** on the primary paths because AX lags transport by ~one
call and produces false negatives. **The snapshot is ground truth.** Do not "fix"
this back.

---

## 10. Yielding, safety, permissions

- **User-interruption yield** (`KitUserInteractionMonitor`): a session-level,
  `.listenOnly`, head-insert CGEventTap on `leftMouseDown/rightMouseDown/keyDown`.
  It reads the event's target pid (field 39) and, if the user acts on the app we're
  driving, a 0.5s-debounced one-shot warning is surfaced: *"The user changed
  'Safari'. Re-query the latest state before sending more actions."* The agent
  yields.
- **Safety blocklist** (`Safety.swift`): some apps are blocked for **all** access
  (Keychain, SecurityAgent, Passwords, screen-sharing/notification agents); others
  are **input-blocked but readable** (Terminal and 7 other emulators, auth prompts)
  — you can read a terminal but never synthesize input into it, and never drive our
  own process. `allow_forbidden` is intentionally **not** honored.
- **Lock-screen guard**: `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]`;
  refuse input when locked (fail-open if the key is absent).
- **SSRF guard**: URLs resolving to private/loopback/link-local ranges are blocked
  (`Safety.checkURL`).
- **Permissions** (`Permissions.swift`): on the first tool call, prompt
  Accessibility (`AXIsProcessTrustedWithOptions([.prompt:true])`) and Screen
  Recording (`CGRequestScreenCaptureAccess`); thereafter just check
  (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`). Return a "permissions
  pending, call again" message until granted (non-blocking). `ax` capture mode needs
  no Screen Recording at all.
- **Window-owner validation** (`WindowOwnerValidation.swift`): confirm a window
  still belongs to the expected pid via CGS connection↔pid lookups (two strategies,
  pre-26 and 26+). Critically, it **assumes valid** whenever it *cannot* check —
  validation never blocks an action it couldn't perform *(Inv 19)*.
- **Redacted audit** (`Audit.swift`): one JSONL line per action; `text`/`value`
  fields become `<redacted len=N>`; any `0x…`/`<AXUIElement …>` pointer is scrubbed.

---

## 11. The ghost cursor (the additive payoff)

Because the OS cursor never moves, the agent's "pointer" is purely **logical** — a
per-session `BackgroundCursor` that only updates an internal coordinate and drives
delivery. On top of that we *optionally* render a **decorative** translucent cursor
**per driven window**: a borderless, **non-activating** `NSPanel`
(`.nonactivatingPanel`, `ignoresMouseEvents = true`, can't become key/main,
`.screenSaver` level, joins all spaces). It's clamped to the window's screen rect
(and, in v2, to the window's *visible* region via CGS z-order occlusion math, hidden
when fully covered), follows the window on move/resize, and is tinted per session so
N concurrent agents are visually separable. **Hard rule:** decorative only — it
never routes through the system cursor, never warps, never foregrounds. This is why
the port is in Swift: the native overlay is trivial in AppKit and was impossible to
do well from Python — and it never touches the Prime Invariant.

---

## 12. Resilience philosophy — optional symbols, honest failure

Every private symbol is resolved **individually and optionally** via
`csky_resolve_symbol` (dlopen+dlsym; `CSkyLightShim.h` declares them as
function-*pointer* typedefs precisely so importing the module creates **no link
dependency** on the private frameworks). A missing symbol resolves to `nil` and the
caller falls through to the always-available public path — **never crash, never a
focus-stealing fallback** *(Inv 17)*. The forbidden foregrounding symbols
(`SLPSSetFrontProcessWithOptions`, `CGSSetConnectionProperty "SetFrontmost"`) are
**never declared**, so the micro-activation path is unreachable by construction
*(Inv 18)*.

This is what lets the same binary run across macOS versions (including the macOS 26
SPI removals): SkyLight delivery is an *optimization for non-Cocoa apps*;
`CGEventPostToPid` is the guaranteed primary for native apps; capture degrades
SCK → private GPU one-shot → (mode-gated) nothing; AX degrades to OCR. And when no
background path can perform an action, the agent returns
`transport_confirmed = false` and tells the model to try AX or another element —
**it fails honestly rather than foregrounding.** That honest failure *is* the
product.

---

## Appendix — the CGEvent fields that make routing work

From `CGEventFields.swift` (verified against `docs/CODEX_PARITY_CHANGES.md`):

| Field                                   | #     | Purpose                                                       |
| --------------------------------------- | ----- | ------------------------------------------------------------- |
| `mouseEventSubtype`                   | 7     | `=3` (tablet-proximity) on SkyLight-routed mouse events     |
| `keyboardEventKeycode`                | 9     | virtual keycode                                               |
| `scrollWheelEventDeltaAxis1/2`        | 11/12 | line deltas (discrete-wheel Cocoa)                            |
| `scrollWheelEventIsContinuous`        | 88    | mark pixel/continuous scroll                                  |
| `mouseEventWindowUnderMousePointer`   | 91    | route hint = target windowId                                  |
| `…ThatCanHandleThisEvent`            | 92    | route hint = target windowId                                  |
| `scrollWheelEventFixedPtDeltaAxis1/2` | 93/94 | fixed-point deltas (native Cocoa)                             |
| `scrollWheelEventPointDeltaAxis1/2`   | 96/97 | integer point deltas (Chromium/Electron)                      |
| `eventSourceStateID`                  | 45    | echo-match our private source on the confirmation tap         |
| SkyLight`pid`                         | 40    | `SLEventSetIntegerValueField(e, 40, pid)` — target process |

Private SkyLight/CGS symbols (all optional, dlsym'd):
`CGSMainConnectionID`, `SLSGetWindowOwner`, `SLSGetConnectionPSN`,
`CGSConnectionGetPID`, `CGSGetConnectionIDForPID` (pre-26), `SLEventPostToPid`,
`SLEventSetIntegerValueField`, `SLEventSetAuthenticationMessage`,
`CGEventSetWindowLocation`, `CGEventPostToPSN`, `_AXUIElementGetWindow`,
`CGSHWCaptureWindowList`, `_AXObserverAddNotificationAndCheckRemote`.
