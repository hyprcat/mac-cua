// US-045 — Window-ordering + frontmost observers (Kit impl).
//
// Two observe-only services, both ported from `focus.py`:
//
//   * KitWindowOrderingObserver — real impl of the Core `WindowOrderingTracking`
//     seam. A 0.5s CFRunLoopTimer on the dedicated `KitRunLoopThread` samples
//     `CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, …)` and feeds
//     the front-to-back window-number list to the pure `WindowOrderingState`. A
//     detected z-order change fires `onChange` once. NO AXObserver (polling is the
//     correctness gate, §5.3). Reading the window list NEVER reorders/raises/
//     foregrounds anything (Invariant 7/15).
//
//   * KitFrontmostTracker — real impl of `FrontmostTracking`. Observes
//     `NSWorkspace.didActivateApplicationNotification` (focus.py
//     `FrontmostAppTracker`). Observe-and-log only — it NEVER activates anything
//     (Invariant 15); the sole sanctioned activation is the restore path in
//     `KitAppResolver.restoreFrontmostApp`.
//
// Nothing here foregrounds, activates, raises, or warps the cursor (Prime
// Invariant). The change-detection logic is the pure, Linux-tested
// `MacCUACore.WindowOrderingState`; this file owns only the timer/notification
// lifecycle, the lock, and the OS sampling.

#if os(macOS)
import Foundation
import CoreFoundation
import CoreGraphics
import AppKit
import MacCUACore

// MARK: - KitWindowOrderingObserver

public final class KitWindowOrderingObserver: WindowOrderingTracking {
    private let lock = NSLock()
    private var state = WindowOrderingState()
    private let runLoop: KitRunLoopThread
    private let pollInterval: Double

    private var timer: CFRunLoopTimer?
    private var running = false

    public var onChange: (([Int]) -> Void)?

    public init(pollInterval: Double = 0.5, runLoop: KitRunLoopThread = KitRunLoopThread()) {
        self.pollInterval = pollInterval
        self.runLoop = runLoop
    }

    public var currentOrder: [Int] {
        lock.lock(); defer { lock.unlock() }
        return state.lastOrder
    }

    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        state.reset()
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
                Unmanaged<KitWindowOrderingObserver>.fromOpaque(info)
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
        state.reset()
        lock.unlock()
        if let t { CFRunLoopTimerInvalidate(t) }
    }

    /// Timer body: sample the on-screen window order and feed the pure state.
    private func poll() {
        let order = Self.sampleWindowOrder()
        lock.lock()
        let changed = state.sample(order)
        let snapshot = state.lastOrder
        lock.unlock()
        if changed { onChange?(snapshot) }
    }

    /// Front-to-back CGWindowNumbers of all on-screen windows. nil if the OS call
    /// returns nothing (focus.py treats None as "skip this poll").
    static func sampleWindowOrder() -> [Int]? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        let order = info.compactMap { ($0[kCGWindowNumber as String] as? Int) }
        return order.isEmpty ? nil : order
    }
}

// MARK: - KitFrontmostTracker

public final class KitFrontmostTracker: FrontmostTracking {
    private let lock = NSLock()
    private var observerToken: NSObjectProtocol?

    public init() {}

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard observerToken == nil else { return }
        // Observe-only (Invariant 15): note the new frontmost app; never activate.
        observerToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { _ in /* observe-and-log only; queried via currentFrontmost() */ }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if let token = observerToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            observerToken = nil
        }
    }

    public func currentFrontmost() -> AppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return nil }
        let name = app.localizedName ?? AppResolverParsing.nameFromBundleId(bundleId)
        return AppInfo(name: name, bundleId: bundleId, pid: Int(app.processIdentifier), running: true)
    }
}

#endif
