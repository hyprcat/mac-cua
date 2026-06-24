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
        lock.unlock()
    }

    /// Stop following a window (session teardown removes the ghost separately).
    public func untrack(windowId: Int) {
        lock.lock(); states.removeValue(forKey: windowId); lock.unlock()
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

        let samples = Self.sampleWindows(ids: Set(ids))
        for id in ids {
            lock.lock()
            var st = states[id] ?? GhostWindowTrackingState()
            let action = st.update(samples[id])
            states[id] = st
            lock.unlock()
            controller.apply(action, windowId: id)
        }
    }

    /// Read the bounds + on-screen flag for the requested windowIds from the
    /// full window list. Windows absent from the list (closed / off the list when
    /// minimized) map to `nil` (no entry) — the state machine treats that as hide.
    static func sampleWindows(ids: Set<Int>) -> [Int: GhostWindowSample] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var out: [Int: GhostWindowSample] = [:]
        for entry in info {
            guard let num = entry[kCGWindowNumber as String] as? Int,
                  ids.contains(num),
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // kCGWindowIsOnscreen absent ⇒ not on screen (minimized / off-Space).
            let onscreen = (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
            out[num] = GhostWindowSample(
                bounds: Rect(x: Double(rect.origin.x), y: Double(rect.origin.y),
                             w: Double(rect.size.width), h: Double(rect.size.height)),
                isOnscreen: onscreen
            )
        }
        return out
    }
}
#endif
