"""OS-level invariant probes for the tool x app verification matrix.

Captures the desktop state that the mac-cua background-invisibility invariants
depend on (frontmost app, real cursor position, on-screen window stacking
order) and diffs two snapshots into human-readable invariant-violation strings.

See: docs/superpowers/specs/2026-06-25-swift-port-tool-matrix-design.md
("Invariants" and "Data contracts").
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass, field

import Quartz
from AppKit import NSWorkspace

# Cursor moves smaller than this (euclidean px) are treated as noise, not warps.
CURSOR_TOLERANCE_PX = 1.0

# Quartz constants. Imported defensively via attribute access so a missing
# symbol in some PyObjC build fails loudly here rather than at call time.
_kCGWindowListOptionOnScreenOnly = Quartz.kCGWindowListOptionOnScreenOnly
_kCGWindowListExcludeDesktopElements = Quartz.kCGWindowListExcludeDesktopElements
_kCGNullWindowID = Quartz.kCGNullWindowID
_kCGWindowNumber = Quartz.kCGWindowNumber


@dataclass
class Snapshot:
    frontmost_bundle: str
    cursor: tuple[float, float]
    window_order: list[int] = field(default_factory=list)  # window numbers, front-to-back


def frontmost_bundle() -> str:
    """Bundle identifier of the frontmost app, or "" if none/unknown."""
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    if app is None:
        return ""
    bundle = app.bundleIdentifier()
    return str(bundle) if bundle is not None else ""


def cursor_pos() -> tuple[float, float]:
    """Real hardware cursor location in global display coordinates."""
    event = Quartz.CGEventCreate(None)
    loc = Quartz.CGEventGetLocation(event)
    return (float(loc.x), float(loc.y))


def _window_order() -> list[int]:
    """Front-to-back window numbers of on-screen, non-desktop windows."""
    options = _kCGWindowListOptionOnScreenOnly | _kCGWindowListExcludeDesktopElements
    infos = Quartz.CGWindowListCopyWindowInfo(options, _kCGNullWindowID)
    order: list[int] = []
    if infos is None:
        return order
    for info in infos:
        num = info.get(_kCGWindowNumber)
        if num is not None:
            order.append(int(num))
    return order


def snapshot() -> Snapshot:
    """Capture frontmost app, cursor, and window stacking order right now."""
    return Snapshot(
        frontmost_bundle=frontmost_bundle(),
        cursor=cursor_pos(),
        window_order=_window_order(),
    )


def diff(before: Snapshot, after: Snapshot) -> list[str]:
    """Return invariant-violation strings (empty list == clean)."""
    violations: list[str] = []

    # Foreground invariant.
    if before.frontmost_bundle != after.frontmost_bundle:
        violations.append(
            f"FOREGROUND: frontmost changed {before.frontmost_bundle} -> "
            f"{after.frontmost_bundle}"
        )

    # Cursor-warp invariant.
    dx = after.cursor[0] - before.cursor[0]
    dy = after.cursor[1] - before.cursor[1]
    dist = math.hypot(dx, dy)
    if dist > CURSOR_TOLERANCE_PX:
        violations.append(
            f"CURSOR WARP: {before.cursor} -> {after.cursor} (Δ={dist:.2f}px)"
        )

    # Window-raise invariant. Only flag a *pre-existing* window that moved to a
    # strictly earlier (more-forward) index. New/closed windows (e.g. the
    # ghost-cursor overlay appearing/disappearing) are tolerated: we compute
    # each window's position among the windows that exist in BOTH snapshots, so
    # overlay churn shifts no indices.
    common = set(before.window_order) & set(after.window_order)
    before_common = [w for w in before.window_order if w in common]
    after_common = [w for w in after.window_order if w in common]
    before_idx = {w: i for i, w in enumerate(before_common)}
    after_idx = {w: i for i, w in enumerate(after_common)}
    for win, i in before_idx.items():
        j = after_idx[win]
        if j < i:
            violations.append(
                f"WINDOW RAISED: window {win} moved from index {i} to {j}"
            )

    return violations


if __name__ == "__main__":
    # 1. Idle: nothing should change across a short sleep.
    s1 = snapshot()
    time.sleep(0.3)
    s2 = snapshot()
    idle_violations = diff(s1, s2)
    assert idle_violations == [], f"idle snapshot drifted: {idle_violations}"

    # 2. Fabricated change: different frontmost + 50px cursor move -> exactly
    #    the FOREGROUND and CURSOR WARP violations (no window violations).
    a = Snapshot(
        frontmost_bundle="com.apple.TextEdit",
        cursor=(100.0, 100.0),
        window_order=[1, 2, 3],
    )
    b = Snapshot(
        frontmost_bundle="com.apple.Safari",
        cursor=(100.0, 150.0),  # 50px down
        window_order=[1, 2, 3],
    )
    fab = diff(a, b)
    assert len(fab) == 2, f"expected 2 violations, got: {fab}"
    assert any(v.startswith("FOREGROUND:") for v in fab), fab
    assert any(v.startswith("CURSOR WARP:") for v in fab), fab
    assert not any(v.startswith("WINDOW RAISED:") for v in fab), fab

    # Sanity: a window genuinely raised IS flagged; overlay churn is not.
    raised = diff(
        Snapshot("x", (0.0, 0.0), [10, 20, 30]),
        Snapshot("x", (0.0, 0.0), [30, 10, 20]),  # 30 jumped to front
    )
    assert any(v.startswith("WINDOW RAISED:") for v in raised), raised
    churn = diff(
        Snapshot("x", (0.0, 0.0), [10, 20]),
        Snapshot("x", (0.0, 0.0), [99, 10, 20]),  # 99 (overlay) appeared in front
    )
    assert churn == [], f"overlay appearance flagged: {churn}"

    # 3. Live snapshot + PASS line.
    live = snapshot()
    print(f"frontmost bundle : {live.frontmost_bundle!r}")
    print(f"cursor           : {live.cursor}")
    print(f"#windows         : {len(live.window_order)}")
    print("PASS: probes self-test (idle clean, fabricated violations detected)")
