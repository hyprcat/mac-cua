// US-052 — Ghost cursor window tracking (§7.2, Kit impl).
//
// Follows each driven window's screen frame so its decorative ghost tracks
// move/resize/display-change, and hides the ghost when the window is minimized,
// closed, or sent to another Space. A 0.5s CFRunLoopTimer on the dedicated
// `KitRunLoopThread` samples `CGWindowListCopyWindowInfo(.optionAll, …)` once per
// tick, extracts the bounds + on-screen flag for each tracked windowId, and feeds
// the pure, Linux-tested `GhostWindowTrackingState`. The resulting edge-triggered
// `GhostTrackAction` is applied to the `GhostCursorController`, which drives the
// overlay on the main thread.
//
// Like every observer in this layer, sampling the window list NEVER reorders,
// raises, foregrounds, or warps anything (Invariant 7/15) — it is a read-only
// CGWindowList poll. The decision logic is pure Core; this file owns only the
// timer lifecycle, the lock, and the OS sampling/parse.

#if os(macOS)
import Foundation
import CoreFoundation
import CoreGraphics
import MacCUACore

public final class KitGhostWindowTracker {
    private let lock = NSLock()
    private let controller: GhostCursorController
    private let runLoop: KitRunLoopThread
    private let pollInterval: Double

    private var states: [Int: GhostWindowTrackingState] = [:]
    private var occlusionStates: [Int: GhostOcclusionState] = [:]
    private var timer: CFRunLoopTimer?
    private var running = false

    public init(controller: GhostCursorController,
                pollInterval: Double = 0.5,
                runLoop: KitRunLoopThread = KitRunLoopThread()) {
        self.controller = controller
        self.pollInterval = pollInterval
        self.runLoop = runLoop
    }

    /// Begin following a window (idempotent). The first poll emits a `.follow`.
    public func track(windowId: Int) {
        lock.lock()
        if states[windowId] == nil { states[windowId] = GhostWindowTrackingState() }
        if occlusionStates[windowId] == nil { occlusionStates[windowId] = GhostOcclusionState() }
        lock.unlock()
    }

    /// Stop following a window (session teardown removes the ghost separately).
    public func untrack(windowId: Int) {
        lock.lock()
        states.removeValue(forKey: windowId)
        occlusionStates.removeValue(forKey: windowId)
        lock.unlock()
    }

    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()

        runLoop.start()
        guard let loop = runLoop.runLoop else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var ctx = CFRunLoopTimerContext(version: 0, info: refcon,
                                        retain: nil, release: nil, copyDescription: nil)
        let t = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + pollInterval,
            pollInterval, 0, 0,
            { _, info in
                guard let info else { return }
                Unmanaged<KitGhostWindowTracker>.fromOpaque(info)
                    .takeUnretainedValue().poll()
            },
            &ctx
        )
        CFRunLoopAddTimer(loop, t, .commonModes)
        lock.lock(); timer = t; lock.unlock()
    }

    public func stop() {
        lock.lock()
        running = false
        let t = timer
        timer = nil
        for id in states.keys { states[id]?.reset() }
        for id in occlusionStates.keys { occlusionStates[id]?.reset() }
        lock.unlock()
        if let t { CFRunLoopTimerInvalidate(t) }
    }

    /// Timer body: sample all windows once, then drive each tracked window's
    /// pure state machine and apply the resulting action to the controller.
    private func poll() {
        lock.lock()
        let ids = Array(states.keys)
        lock.unlock()
        guard !ids.isEmpty else { return }

        // One ordered read of the full window list feeds both the follow/hide
        // tracking AND the per-window occlusion clip (windows above the target).
        let ordered = Self.sampleOrdered()
        let idSet = Set(ids)
        var samples: [Int: GhostWindowSample] = [:]
        for w in ordered where idSet.contains(w.number) {
            samples[w.number] = GhostWindowSample(bounds: w.bounds, isOnscreen: w.onscreen)
        }

        for id in ids {
            lock.lock()
            var st = states[id] ?? GhostWindowTrackingState()
            let action = st.update(samples[id])
            states[id] = st
            lock.unlock()
            controller.apply(action, windowId: id)

            // Occlusion only matters for an on-screen, visible window.
            let occAction: GhostOcclusionAction
            if let sample = samples[id], sample.isOnscreen {
                let occluders = Self.occluders(for: id, in: ordered)
                let region = GhostOcclusion.visibleRegion(target: sample.bounds,
                                                          occluders: occluders)
                lock.lock()
                var os = occlusionStates[id] ?? GhostOcclusionState()
                occAction = os.update(region: region)
                occlusionStates[id] = os
                lock.unlock()
            } else {
                // Off-screen: the follow path already hid it; reset occlusion so a
                // later re-show recomputes the clip from scratch.
                lock.lock()
                occlusionStates[id]?.reset()
                lock.unlock()
                occAction = .none
            }
            controller.applyOcclusion(occAction, windowId: id)
        }
    }

    /// An on-screen window from the front-to-back ordered list.
    struct OrderedWindow { let number: Int; let bounds: Rect; let onscreen: Bool }

    /// The occluders of `id`: every on-screen window stacked ABOVE it (earlier in
    /// the front-to-back list) whose bounds overlap. Windows at or below the
    /// target do not occlude it.
    static func occluders(for id: Int, in ordered: [OrderedWindow]) -> [Rect] {
        guard let idx = ordered.firstIndex(where: { $0.number == id }) else { return [] }
        var out: [Rect] = []
        for i in 0..<idx where ordered[i].onscreen {
            out.append(ordered[i].bounds)
        }
        return out
    }

    /// Read the full front-to-back window list once (number + bounds + on-screen).
    static func sampleOrdered() -> [OrderedWindow] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var out: [OrderedWindow] = []
        for entry in info {
            guard let num = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            let onscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            out.append(OrderedWindow(
                number: num,
                bounds: Rect(x: Double(rect.origin.x), y: Double(rect.origin.y),
                             w: Double(rect.size.width), h: Double(rect.size.height)),
                onscreen: onscreen))
        }
        return out
    }
}
#endif
