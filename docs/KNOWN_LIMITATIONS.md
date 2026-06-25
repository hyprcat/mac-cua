# Known Limitations

**Date:** 2026-06-25
**Branch:** ralph/swift-port-completion

This document records surfaces and interactions that mac-cua **cannot** drive, and
**why**. These are not bugs — most are deliberate consequences of the **Prime
Invariant (Inv 18): mac-cua never foregrounds, activates, or raises a target
window.** That invariant is what lets the driver operate on background windows
without stealing focus from the user; the cost is that any surface which only
accepts input *after* an activation is out of reach.

mac-cua is intentionally **stricter** than the upstream `cua-driver` here. Where
upstream falls back to full window activation (and warps the cursor) to make these
surfaces work, mac-cua refuses and instead fails loudly or reports no effect.

Design reference:
[`docs/superpowers/specs/2026-06-25-background-input-learnings-design.md`](superpowers/specs/2026-06-25-background-input-learnings-design.md)
(US-060).

---

## A. Web-content right-click is coerced to left-click

**Symptom.** A right-click (secondary / context-menu click) requested at a
**coordinate** inside a web page does not open the page's context menu; it behaves
like a left-click instead.

**Why.** mac-cua delivers background input through SkyLight's targeted,
non-HID-tap path (`SLEventPostToPid` with window-local coordinates). Chromium
**drops the right-button subtype** on events that did not arrive via a real HID
tap, collapsing them to a left-click for web content. This is Chromium's
behavior, not something the driver can re-stamp on the event.

**What still works.** The accessibility **secondary action** still fires for any
target that is **AX-addressable** — links, buttons, and menu items that appear in
the AX tree. So right-clicking an `element_index` (an AX target) works; it is only
**pure web content addressed by raw pixel coordinate** that is left-click-only.

**Workaround.** Address the target by `element_index` (AX secondary action) rather
than by coordinate where possible.

**Fix.** No fix without a browser extension to inject the right-click on the web
side. That is explicitly a non-goal.

---

## B. Canvas / GHOST / Unity / game surfaces are unsupported

**Symptom.** Clicks, drags, and key input directed at a 3D / GPU canvas
application — for example **Blender** (its GHOST windowing layer), **Unity** (editor
and Unity-built players), and other game engines — have no effect. Depending on the
path, the action either returns a structured **error** up front (see below) or
verifies as a **no-op** with a hint.

**Why.** These surfaces only process synthetic input events **after a window
activation** (foreground / raise). The Prime Invariant (Inv 18) forbids mac-cua
from performing that activation, so the events arrive but are never serviced.
Upstream `cua-driver` works around this by activating the window and warping the
cursor; **mac-cua deliberately does not** — it keeps the user's focus and reports
the limitation instead.

**Structured error.** When mac-cua can recognize the surface up front (best-effort,
by bundle id — e.g. `org.blender.blender`, `com.unity3d.*`), it returns an
`UnsupportedSurfaceError` with reason code **`unsupported_canvas_surface`** instead
of silently dropping the click. The message reads, in substance:

> This surface requires window activation to accept input, which mac-cua does not
> perform by design (Prime Invariant): the driver never foregrounds, activates, or
> raises a window. Canvas / game surfaces (e.g. Blender GHOST, Unity) are therefore
> unsupported.

**Best-effort detection.** Recognition is intentionally **conservative** — a false
positive would wrongly block a legitimate app, which is worse than missing one. The
heuristic (`CanvasSurfaceHeuristic.isLikelyCanvasSurface`) flags a surface only when
its **bundle id** is a known canvas surface or matches a known game-engine prefix.
A near-empty accessibility tree alone is **not** treated as canvas (an empty tree
also happens before Accessibility permission is granted, and for Chromium/Electron
before enhanced-UI is enabled). For surfaces not recognized up front, outcome
verification may instead append a soft **hint**
(`CanvasSurfaceHeuristic.noEffectHint`) when a pixel click verifies as a no-op,
pointing the caller at this limitation without falsely asserting detection.

**Known canvas bundle ids** are maintained in
`swift/Sources/MacCUACore/CanvasSurfaceHeuristic.swift` and the list is
**extensible** — add newly confirmed surfaces there.

**Fix.** None without violating Inv 18. Canvas / game support is an explicit
non-goal.

---

## Related: `vision` capture mode has no element indices

Not an unsupported surface, but worth noting alongside the above: the `vision`
capture mode (US-058) returns a screenshot with **no AX tree**, so `element_index`
addressing is unavailable in that mode — callers must address by coordinate. Use
the default `som` (or `ax`) mode when you need `element_index` targets.
