import Foundation

// ---------------------------------------------------------------------------
// Ghost cursor seam (decorative virtual-cursor overlay) — SWIFT_PORT_DESIGN §7
// ---------------------------------------------------------------------------
//
// The *logical* cursor lives in `BackgroundCursor` (one per AppSession): its
// `moveTo` only updates an internal coordinate; the OS cursor never moves. This
// file adds the **decorative** half: a per-window translucent ghost sprite that
// renders where the logical cursor already is. It is decorative ONLY — it never
// routes through the system cursor, never warps, never foregrounds.
//
// Phase split (§7.4):
//   - This file is the Linux-buildable/testable Core seam: the pure
//     `GhostCursorController` (rotating tint palette + `clampPointToWindow` +
//     per-window registry) driving the `GhostCursorOverlay` protocol.
//   - Phase 6 supplies the AppKit `GhostCursorOverlay` impl (NSPanel per window,
//     CALayer sprite, window-follow, animations) in MacCUAKit.
//   - Phase 4 (this story, US-039) wires `BackgroundCursor` position changes →
//     `GhostCursorController.move(windowId:)` through the `GhostCursorDriving`
//     chokepoint, so every logical move updates the ghost automatically.

/// A translucent tint assigned to one driven window's ghost cursor. Concurrent
/// sessions get distinct tints from a rotating palette so parallel agents are
/// visually separable (§7.3, K2). RGBA components are 0…1.
public struct GhostCursorStyle: Sendable, Equatable {
    public let name: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(name: String, red: Double, green: Double, blue: Double, alpha: Double = 0.75) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Which pointer shape the ghost renders — chosen from the accessibility role of
/// the element the agent is acting on, mirroring the macOS system cursors:
/// arrow (default), I-beam (text fields/editable text), and pointing hand
/// (buttons/links/clickable controls). The AppKit overlay maps each to the real
/// Bibata-Modern pointer outline.
public enum GhostCursorKind: String, Sendable, Equatable {
    case arrow
    case ibeam
    case hand
}

/// The default rotating palette (distinct, high-contrast translucent tints).
public enum GhostCursorPalette {
    public static let styles: [GhostCursorStyle] = [
        GhostCursorStyle(name: "cyan", red: 0.0, green: 0.78, blue: 0.92),
        GhostCursorStyle(name: "magenta", red: 0.93, green: 0.18, blue: 0.66),
        GhostCursorStyle(name: "amber", red: 1.0, green: 0.65, blue: 0.0),
        GhostCursorStyle(name: "green", red: 0.20, green: 0.80, blue: 0.35),
        GhostCursorStyle(name: "violet", red: 0.55, green: 0.36, blue: 0.96),
        GhostCursorStyle(name: "red", red: 0.92, green: 0.26, blue: 0.21),
    ]
}

/// The AppKit rendering seam (impl deferred to Phase 6 in MacCUAKit). Every call
/// is decorative: the overlay must be a non-activating, click-through panel
/// (`ignoresMouseEvents = true`, `canBecomeKey/Main = false`) clamped to the
/// target window's screen rect. NONE of these may foreground/raise/warp.
public protocol GhostCursorOverlay: AnyObject {
    /// Begin showing a ghost for a window with the given tint + window screen rect.
    func show(windowId: Int, style: GhostCursorStyle, windowFrame: Rect?)
    /// Move the ghost sprite to a (window-clamped) screen point.
    func move(windowId: Int, to point: Point, animated: Bool)
    /// Follow the window when it moves/resizes (or hide if off-screen → nil).
    func setWindowFrame(windowId: Int, _ frame: Rect?)
    /// Temporarily hide (minimize/occlusion) without forgetting the window.
    func hide(windowId: Int)
    /// Tear down the ghost for a window (session teardown).
    func remove(windowId: Int)
    // US-054 decorative animations (default no-op so existing fakes keep building).
    /// Play a one-shot click ripple/pulse on the sprite at its current position.
    func pulse(windowId: Int)
    /// Briefly outline an element's bounds inside the window (CG-global rect).
    func highlight(windowId: Int, bounds: Rect)
    /// Start/stop the idle thinking wiggle on the sprite.
    func setThinking(windowId: Int, active: Bool)
    // US-055 occlusion clipping (default no-op so existing fakes keep building).
    /// Clip the ghost to the window's still-visible rectilinear region (CG-global
    /// rects). An empty region means fully occluded — equivalent to `hide`.
    func setClipRegion(windowId: Int, region: [Rect])
    /// Switch the rendered pointer shape (arrow / I-beam / hand) — decorative.
    func setKind(windowId: Int, _ kind: GhostCursorKind)
}

public extension GhostCursorOverlay {
    func pulse(windowId: Int) {}
    func highlight(windowId: Int, bounds: Rect) {}
    func setThinking(windowId: Int, active: Bool) {}
    func setClipRegion(windowId: Int, region: [Rect]) {}
    func setKind(windowId: Int, _ kind: GhostCursorKind) {}
}

// ---------------------------------------------------------------------------
// US-054 — Ghost cursor animations (§7.3): pure animation geometry/params
// ---------------------------------------------------------------------------
//
// The *timing* and *shape* of every decorative animation is pure math so it can
// be unit-tested on Linux; the AppKit overlay (MacCUAKit) only translates these
// values into Core Animation objects. Nothing here touches the OS cursor.

/// Tunable durations/magnitudes shared by Core (tests) and the AppKit overlay.
public enum GhostAnimationParams {
    /// Bezier "scoot" base duration when `moveTo(animated: true)`.
    public static let scootDuration: Double = 0.18

    /// Human-like glide duration for a travel of `distance` points: a small base
    /// plus a per-point term, clamped so long jumps stay snappy and tiny nudges
    /// aren't sluggish. Pure/deterministic — the overlay uses this so the ghost's
    /// pacing feels hand-driven rather than a fixed-time teleport-with-tween.
    public static func glideDuration(forDistance distance: Double) -> Double {
        let d = max(0, distance)
        return min(0.5, 0.11 + d / 2200.0)
    }
    /// Click ripple duration.
    public static let pulseDuration: Double = 0.35
    /// Peak sprite scale at the apex of a click pulse.
    public static let pulseMaxScale: Double = 1.9
    /// Idle wiggle period (one full back-and-forth).
    public static let wigglePeriod: Double = 0.6
    /// Idle wiggle peak rotation, radians.
    public static let wiggleAmplitude: Double = 0.12
    /// Element-bounds highlight fade duration.
    public static let highlightDuration: Double = 0.6
}

/// Pure animation geometry helpers (Linux-tested).
public enum GhostAnimationGeometry {
    /// Two cubic-bezier control points for a gentle arced "scoot" from `a` to `b`.
    /// The controls sit at 1/3 and 2/3 along the segment, pushed perpendicular by
    /// a fraction of the travel distance so the path bows rather than going
    /// dead-straight. A zero-length move returns both controls at `a` (no arc).
    public static func scootControlPoints(from a: Point, to b: Point,
                                          bow: Double = 0.18) -> (c1: Point, c2: Point) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dist = (dx * dx + dy * dy).squareRoot()
        if dist == 0 { return (a, a) }
        // Unit perpendicular to the travel direction.
        let px = -dy / dist
        let py = dx / dist
        let offset = dist * bow
        let p1 = Point(x: a.x + dx / 3.0, y: a.y + dy / 3.0)
        let p2 = Point(x: a.x + dx * 2.0 / 3.0, y: a.y + dy * 2.0 / 3.0)
        return (Point(x: p1.x + px * offset, y: p1.y + py * offset),
                Point(x: p2.x + px * offset, y: p2.y + py * offset))
    }

    /// Rotation (radians) of the idle wiggle at phase `t` (seconds), a sine wave
    /// of `wiggleAmplitude` and period `wigglePeriod`. Pure/deterministic.
    public static func wiggleRotation(atPhase t: Double) -> Double {
        let twoPi = 2.0 * Double.pi
        return GhostAnimationParams.wiggleAmplitude
            * sin(twoPi * t / GhostAnimationParams.wigglePeriod)
    }
}

/// The single chokepoint a `BackgroundCursor` drives on every logical move.
/// `GhostCursorController` conforms; `BackgroundCursor` holds a `weak` reference
/// so the controller's per-window registry never keeps a session alive.
///
/// US-054 adds the decorative animation hooks (`pulse`/`highlight`/`setThinking`)
/// alongside the move chokepoint. They have default no-op extension impls so
/// existing conformers/mocks keep compiling; the real animations are driven off
/// `BackgroundCursor` position/click changes (still the single chokepoint).
public protocol GhostCursorDriving: AnyObject {
    func move(windowId: Int, to point: Point, animated: Bool)
    /// A click happened at the current logical position → ripple/pulse the sprite.
    func pulse(windowId: Int)
    /// Briefly outline an element's screen bounds (CG-global rect) — decorative.
    func highlight(windowId: Int, bounds: Rect)
    /// Toggle the idle "thinking" wiggle while the agent deliberates.
    func setThinking(windowId: Int, active: Bool)
}

public extension GhostCursorDriving {
    func pulse(windowId: Int) {}
    func highlight(windowId: Int, bounds: Rect) {}
    func setThinking(windowId: Int, active: Bool) {}
}

/// Pure ghost-cursor geometry helpers (Linux-testable). The overlay receives
/// window rects + logical points in **CG global** coordinates (top-left origin,
/// y grows downward — what `CaptureProvider.getWindowBounds` returns), but AppKit
/// panels/layers live in **bottom-left** screen coordinates. These convert
/// between the two so the AppKit impl owns no coordinate math of its own.
public enum GhostCursorGeometry {
    /// Convert a CG-global (top-left origin) window rect into an AppKit screen
    /// frame (bottom-left origin). `primaryScreenHeight` is the height of the
    /// primary display (the AppKit y-flip reference). Pure.
    public static func appKitFrame(forCGRect cg: Rect, primaryScreenHeight: Double) -> Rect {
        let flippedY = primaryScreenHeight - (cg.y + cg.h)
        return Rect(x: cg.x, y: flippedY, w: cg.w, h: cg.h)
    }

    /// Position of a (window-clamped) CG-global point inside the panel's own
    /// bottom-left local coordinate space, given the window's CG-global rect.
    /// The panel origin is the window's top-left; inside the panel y is flipped.
    /// Pure — used to place the sprite layer within the overlay panel.
    public static func spritePointInPanel(screenPoint cg: Point, windowCGRect rect: Rect) -> Point {
        let localX = cg.x - rect.x
        let localY = rect.h - (cg.y - rect.y)
        return Point(x: localX, y: localY)
    }
}

// ---------------------------------------------------------------------------
// US-052 — Ghost cursor window tracking (§7.2)
// ---------------------------------------------------------------------------
//
// The decorative ghost must FOLLOW its driven window: when the user (or the
// agent) moves/resizes the window the sprite tracks it; when the window is
// minimized, closed, sent to another Space, or otherwise off-screen the ghost
// hides; and when the window moves across displays the panel repositions. The
// OS sampling (CGWindowList polling on the run-loop thread) lives in the Kit
// `KitGhostWindowTracker`; the *decision* — given the latest sample for one
// window, what should the overlay do — is this pure, Linux-tested state machine.
//
// It deliberately emits an action ONLY on change (edge-triggered) so the overlay
// is not spammed with redundant frame/hide calls every poll tick.

/// A single poll observation of a tracked window. `bounds` is the window's
/// CG-global rect (top-left origin); `isOnscreen` mirrors `kCGWindowIsOnscreen`
/// (false when minimized or on another Space). Absence from the window list
/// entirely (closed / minimized off the all-windows list) is modelled as a `nil`
/// sample passed to `update`.
public struct GhostWindowSample: Equatable, Sendable {
    public let bounds: Rect
    public let isOnscreen: Bool
    public init(bounds: Rect, isOnscreen: Bool) {
        self.bounds = bounds
        self.isOnscreen = isOnscreen
    }
}

/// The edge-triggered decision for one window's ghost on a single poll.
public enum GhostTrackAction: Equatable, Sendable {
    /// No change since the last emitted action — overlay untouched.
    case none
    /// Window is visible at a new frame (moved/resized/changed display) → the
    /// overlay should follow to this CG-global rect.
    case follow(Rect)
    /// Window is gone/minimized/off-Space/off-screen → the overlay should hide
    /// (keep the entry; a later `follow` re-shows it).
    case hide
}

/// Pure per-window follow/hide state machine. One instance per tracked window.
/// `update(nil)` (window absent from the list) and `update(offscreen)` both
/// resolve to a single `.hide`; a visible sample with a new frame resolves to
/// `.follow`. Repeated identical samples resolve to `.none`.
public struct GhostWindowTrackingState: Sendable {
    private var lastFrame: Rect?
    private var hidden = false

    public init() {}

    public mutating func update(_ sample: GhostWindowSample?) -> GhostTrackAction {
        guard let sample, sample.isOnscreen else {
            if hidden { return .none }
            hidden = true
            return .hide
        }
        if hidden || lastFrame != sample.bounds {
            hidden = false
            lastFrame = sample.bounds
            return .follow(sample.bounds)
        }
        return .none
    }

    /// Reset to the initial state (tracker stop / window re-registered).
    public mutating func reset() {
        lastFrame = nil
        hidden = false
    }
}

// ---------------------------------------------------------------------------
// US-055 — Occlusion clipping v2 (§7.2)
// ---------------------------------------------------------------------------
//
// The decorative ghost must not paint over the parts of its driven window that
// are *covered by other windows*: when another app's window is stacked above the
// driven window (in CGS z-order), the ghost should be clipped to only the
// driven window's still-visible region, and hidden entirely when the driven
// window is fully occluded. The OS sampling (CGWindowList front-to-back order +
// bounds) lives in the Kit `KitGhostWindowTracker`; the *geometry* — given the
// target rect and the rects of the windows above it, what region is still
// visible — is this pure, Linux-tested code.
//
// The visible region is modelled as a list of axis-aligned rectangles (a
// rectilinear region = target minus the union of the occluder rects). An empty
// list means the target is fully covered → hide. The AppKit overlay turns the
// region into a layer mask so the sprite/ripple/highlight are clipped to it.

/// Pure window-occlusion geometry (Linux-tested). All rects are CG-global
/// (top-left origin); the y-axis orientation is irrelevant to the set algebra.
public enum GhostOcclusion {
    /// Compute the still-visible region of `target` after subtracting every
    /// occluder rect (windows stacked above it). Returns a rectilinear cover:
    /// a list of disjoint rects whose union is exactly `target \ ∪occluders`.
    /// An empty result means `target` is fully occluded. A target with no
    /// occluders returns `[target]` (whole window visible).
    ///
    /// Algorithm: slab decomposition. Collect every distinct x- and y-edge from
    /// the target and the clipped occluders, forming a grid; keep each grid cell
    /// whose center lies inside the target but inside NO occluder; merge adjacent
    /// kept cells row-wise then column-wise so the output stays compact.
    public static func visibleRegion(target: Rect, occluders: [Rect]) -> [Rect] {
        if target.w <= 0 || target.h <= 0 { return [] }
        // Clip occluders to the target; drop empties and those that don't overlap.
        let clipped = occluders.compactMap { intersection(target, $0) }
                               .filter { $0.w > 0 && $0.h > 0 }
        if clipped.isEmpty { return [target] }

        // Build the slab grid from all unique edges.
        var xs: [Double] = [target.x, target.x + target.w]
        var ys: [Double] = [target.y, target.y + target.h]
        for o in clipped {
            xs.append(o.x); xs.append(o.x + o.w)
            ys.append(o.y); ys.append(o.y + o.h)
        }
        xs = uniqueSorted(xs); ys = uniqueSorted(ys)

        // Walk the grid row by row. For each row, build the kept horizontal runs
        // (maximal x-spans whose cell centers are inside the target and outside
        // every occluder). Carry "open" rects downward: a run that exactly matches
        // an open rect's x-span and abuts its bottom edge extends that rect; any
        // open rect not matched this row is flushed to the output.
        struct OpenRect { var x0: Double; var x1: Double; var top: Double; var bottom: Double }
        var out: [Rect] = []
        var open: [OpenRect] = []

        for yi in 0..<(ys.count - 1) {
            let y0 = ys[yi], y1 = ys[yi + 1]
            if y1 <= y0 { continue }
            let cy = (y0 + y1) / 2

            var runs: [(x0: Double, x1: Double)] = []
            var runStart: Double? = nil
            for xi in 0..<(xs.count - 1) {
                let x0 = xs[xi], x1 = xs[xi + 1]
                if x1 <= x0 { continue }
                let cx = (x0 + x1) / 2
                let kept = contains(target, x: cx, y: cy)
                    && !clipped.contains(where: { contains($0, x: cx, y: cy) })
                if kept {
                    if runStart == nil { runStart = x0 }
                } else if let s = runStart {
                    runs.append((s, x0)); runStart = nil
                }
            }
            if let s = runStart { runs.append((s, xs[xs.count - 1])) }

            var nextOpen: [OpenRect] = []
            var matched = Array(repeating: false, count: open.count)
            for run in runs {
                var extended = false
                for i in 0..<open.count where !matched[i] {
                    if open[i].x0 == run.x0 && open[i].x1 == run.x1 && open[i].bottom == y0 {
                        matched[i] = true
                        nextOpen.append(OpenRect(x0: open[i].x0, x1: open[i].x1,
                                                 top: open[i].top, bottom: y1))
                        extended = true
                        break
                    }
                }
                if !extended {
                    nextOpen.append(OpenRect(x0: run.x0, x1: run.x1, top: y0, bottom: y1))
                }
            }
            for i in 0..<open.count where !matched[i] {
                out.append(Rect(x: open[i].x0, y: open[i].top,
                                w: open[i].x1 - open[i].x0, h: open[i].bottom - open[i].top))
            }
            open = nextOpen
        }
        for o in open {
            out.append(Rect(x: o.x0, y: o.top, w: o.x1 - o.x0, h: o.bottom - o.top))
        }
        return out
    }

    /// Whether `target` is fully covered by the union of `occluders`.
    public static func isFullyOccluded(target: Rect, occluders: [Rect]) -> Bool {
        visibleRegion(target: target, occluders: occluders).isEmpty
    }

    static func intersection(_ a: Rect, _ b: Rect) -> Rect? {
        let x0 = max(a.x, b.x)
        let y0 = max(a.y, b.y)
        let x1 = min(a.x + a.w, b.x + b.w)
        let y1 = min(a.y + a.h, b.y + b.h)
        if x1 <= x0 || y1 <= y0 { return nil }
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    static func contains(_ r: Rect, x: Double, y: Double) -> Bool {
        x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
    }

    static func uniqueSorted(_ values: [Double]) -> [Double] {
        var seen: [Double] = []
        for v in values.sorted() where seen.last != v { seen.append(v) }
        return seen
    }
}

/// The edge-triggered decision for one window's ghost occlusion on a single poll.
public enum GhostOcclusionAction: Equatable, Sendable {
    /// No change since the last emitted action — overlay clip untouched.
    case none
    /// Target fully covered → hide the ghost (kept entry; a later `clip` re-shows).
    case hide
    /// Target partly/fully visible at this rectilinear region → clip the ghost.
    case clip([Rect])
}

/// Pure per-window occlusion state machine. One instance per tracked window;
/// emits a `.clip`/`.hide` only when the visible region changes (edge-triggered),
/// so the overlay is not re-masked every poll tick. Mirrors
/// `GhostWindowTrackingState`.
public struct GhostOcclusionState: Sendable {
    private var lastRegion: [Rect]?
    private var hidden = false

    public init() {}

    /// Feed the freshly-computed visible region for this window.
    public mutating func update(region: [Rect]) -> GhostOcclusionAction {
        if region.isEmpty {
            if hidden { return .none }
            hidden = true
            lastRegion = []
            return .hide
        }
        if hidden || lastRegion != region {
            hidden = false
            lastRegion = region
            return .clip(region)
        }
        return .none
    }

    public mutating func reset() {
        lastRegion = nil
        hidden = false
    }
}

/// Pure per-window ghost-cursor registry: assigns a rotating tint per window,
/// tracks each window's screen frame, and clamps every move to that frame so a
/// ghost can never paint over another app (§7.2). Linux-testable with a fake (or
/// nil) overlay; the AppKit overlay is wired in Phase 6.
public final class GhostCursorController: GhostCursorDriving {
    private let palette: [GhostCursorStyle]
    public weak var overlay: GhostCursorOverlay?

    /// Lifecycle hooks for the AppKit window tracker (Kit `KitGhostWindowTracker`),
    /// which lives in a module Core cannot import. The executable wires these to
    /// `tracker.track` / `tracker.untrack` so a window starts/stops being followed
    /// (move/resize/occlusion) exactly when its session attaches/tears down.
    public var onStartTracking: ((Int) -> Void)?
    public var onStopTracking: ((Int) -> Void)?

    private var styles: [Int: GhostCursorStyle] = [:]
    private var frames: [Int: Rect] = [:]
    private var nextStyleIndex = 0

    public init(palette: [GhostCursorStyle] = GhostCursorPalette.styles,
                overlay: GhostCursorOverlay? = nil) {
        self.palette = palette.isEmpty ? GhostCursorPalette.styles : palette
        self.overlay = overlay
    }

    /// Clamp a point to a window's screen rect (inclusive of edges). Pure.
    public static func clampPointToWindow(_ point: Point, _ frame: Rect) -> Point {
        if frame.w <= 0 || frame.h <= 0 { return point }
        let x = min(max(point.x, frame.x), frame.x + frame.w)
        let y = min(max(point.y, frame.y), frame.y + frame.h)
        return Point(x: x, y: y)
    }

    /// The tint currently assigned to a window (nil if not tracked). For tests.
    public func style(forWindowId windowId: Int) -> GhostCursorStyle? {
        styles[windowId]
    }

    /// Number of windows currently assigned a tint (live cursors). For tests.
    public var trackedWindowCount: Int { styles.count }

    /// Pick the next tint for a fresh window. To guarantee N concurrent sessions
    /// render N *visually distinct* cursors (§7.3, K2), prefer the first palette
    /// tint not currently in use by any live window; only once every tint is in
    /// use (more live windows than palette entries) do we fall back to the
    /// rotating index so the palette wraps deterministically. This means a tint
    /// freed by `stopTracking` is immediately reusable, and two live windows can
    /// never share a color until the palette is exhausted.
    private func nextDistinctStyle() -> GhostCursorStyle {
        let inUse = Set(styles.values.map { $0.name })
        if let free = palette.first(where: { !inUse.contains($0.name) }) {
            return free
        }
        return palette[nextStyleIndex % palette.count]
    }

    /// Begin tracking a driven window: assign a tint (stable across calls) and
    /// announce it to the overlay. Idempotent — re-tracking keeps the same tint.
    @discardableResult
    public func startTracking(windowId: Int, windowFrame: Rect? = nil) -> GhostCursorStyle {
        let style: GhostCursorStyle
        if let existing = styles[windowId] {
            style = existing
        } else {
            style = nextDistinctStyle()
            nextStyleIndex += 1
            styles[windowId] = style
        }
        if let windowFrame { frames[windowId] = windowFrame }
        overlay?.show(windowId: windowId, style: style, windowFrame: frames[windowId])
        onStartTracking?(windowId)
        return style
    }

    /// Drive the ghost to a logical point (the `BackgroundCursor` chokepoint).
    /// Clamps to the known window frame so the sprite stays on its own window.
    public func move(windowId: Int, to point: Point, animated: Bool = false) {
        let clamped = frames[windowId].map { GhostCursorController.clampPointToWindow(point, $0) } ?? point
        overlay?.move(windowId: windowId, to: clamped, animated: animated)
    }

    /// Click ripple at the sprite's current position (the `clickAt` chokepoint).
    public func pulse(windowId: Int) {
        overlay?.pulse(windowId: windowId)
    }

    /// Briefly outline an element's CG-global bounds (clamped to the window frame
    /// so the highlight can never paint outside the driven window).
    public func highlight(windowId: Int, bounds: Rect) {
        let clamped = frames[windowId].map { GhostCursorController.clampRectToWindow(bounds, $0) } ?? bounds
        overlay?.highlight(windowId: windowId, bounds: clamped)
    }

    /// Toggle the idle thinking wiggle.
    public func setThinking(windowId: Int, active: Bool) {
        overlay?.setThinking(windowId: windowId, active: active)
    }

    /// Switch the rendered pointer shape (arrow / I-beam / hand) for a window.
    public func setKind(windowId: Int, _ kind: GhostCursorKind) {
        overlay?.setKind(windowId: windowId, kind)
    }

    /// Clamp a CG-global rect so it lies entirely within a window frame. Pure.
    public static func clampRectToWindow(_ rect: Rect, _ frame: Rect) -> Rect {
        if frame.w <= 0 || frame.h <= 0 { return rect }
        let x0 = min(max(rect.x, frame.x), frame.x + frame.w)
        let y0 = min(max(rect.y, frame.y), frame.y + frame.h)
        let x1 = min(max(rect.x + rect.w, frame.x), frame.x + frame.w)
        let y1 = min(max(rect.y + rect.h, frame.y), frame.y + frame.h)
        return Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// Apply an edge-triggered `GhostWindowTrackingState` action to the overlay
    /// (the Kit window-tracker chokepoint). `.follow` repositions, `.hide` orders
    /// the ghost out (keeping its tint), `.none` is a no-op.
    public func apply(_ action: GhostTrackAction, windowId: Int) {
        switch action {
        case .none:
            break
        case .follow(let frame):
            windowMoved(windowId: windowId, frame: frame)
        case .hide:
            // Keep the assigned tint + last frame; just hide the sprite.
            overlay?.hide(windowId: windowId)
        }
    }

    /// Apply an edge-triggered `GhostOcclusionState` action to the overlay (the
    /// Kit window-tracker chokepoint). `.clip` masks the ghost to the visible
    /// region, `.hide` orders it out (fully occluded), `.none` is a no-op.
    public func applyOcclusion(_ action: GhostOcclusionAction, windowId: Int) {
        switch action {
        case .none:
            break
        case .hide:
            overlay?.hide(windowId: windowId)
        case .clip(let region):
            overlay?.setClipRegion(windowId: windowId, region: region)
        }
    }

    /// Update a tracked window's screen frame (window moved/resized; nil = hide).
    public func windowMoved(windowId: Int, frame: Rect?) {
        if let frame { frames[windowId] = frame } else { frames.removeValue(forKey: windowId) }
        overlay?.setWindowFrame(windowId: windowId, frame)
    }

    /// Stop tracking a window (session teardown): forget its tint + frame and
    /// remove the overlay. The freed tint slot is reused by the next new window.
    public func stopTracking(windowId: Int) {
        styles.removeValue(forKey: windowId)
        frames.removeValue(forKey: windowId)
        overlay?.remove(windowId: windowId)
        onStopTracking?(windowId)
    }
}
