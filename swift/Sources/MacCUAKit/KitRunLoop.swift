// US-025 — Observers / run-loop (design §5.3, §5.2).
//
// Two pieces land here:
//
//   * KitRunLoopThread — a dedicated `Thread` running `CFRunLoopRun()`, the host
//     for the listen-only CGEventTaps we keep (delivery-confirmation US-037,
//     user-interruption US-044). C tap callbacks reach their owner via the
//     `refcon` pointer (`Unmanaged.passUnretained(self).toOpaque()`) — NO global
//     registry / lock. The run loop keeps a no-op timer source installed so
//     `CFRunLoopRun()` does not return immediately when no tap is attached yet.
//
//   * KitSettleMonitor — settle by OBSERVATION (polling the tree fingerprint via
//     the pure `SettlePoller`/`DebounceStateMachine`), NOT AXObserver. AXObserver
//     is deliberately not a correctness gate here; stale detection is the
//     liveness-check + GraphLocator re-walk path (US-038), not an invalidation
//     flag. Nothing here foregrounds, activates, raises, or warps (Prime Invariant).

#if os(macOS)
import Foundation
import CoreFoundation
import MacCUACore

// MARK: - KitRunLoopThread

/// Dedicated thread owning a `CFRunLoop` for the event taps we keep. Start it
/// once per process/session; attach `CFMachPort`-backed run-loop sources to
/// `runLoop` from the tap installers. The thread stays alive until `stop()`.
public final class KitRunLoopThread {
    private var thread: Thread?
    private let started = DispatchSemaphore(value: 0)
    /// The dedicated thread's run loop. Valid only after `start()` has returned.
    public private(set) var runLoop: CFRunLoop?

    public init() {}

    public var isRunning: Bool { runLoop != nil && (thread?.isExecuting ?? false) }

    /// Spin up the thread and block until its run loop is live and ready for
    /// sources to be added (so callers never race the loop's existence).
    public func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in
            guard let self else { return }
            let loop = CFRunLoopGetCurrent()
            self.runLoop = loop
            // Keep the loop alive with no real source attached yet: a far-future,
            // never-firing timer is the standard idiom so CFRunLoopRun() blocks
            // instead of returning immediately.
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 1.0e10,
                0, 0, 0
            ) { _ in }
            CFRunLoopAddTimer(loop, timer, CFRunLoopMode.commonModes)
            self.started.signal()
            CFRunLoopRun()
        }
        t.name = "mac-cua.runloop"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
        started.wait()
    }

    /// Stop the run loop and release the thread.
    public func stop() {
        guard let loop = runLoop else { return }
        CFRunLoopStop(loop)
        runLoop = nil
        thread = nil
    }
}

// MARK: - KitSettleMonitor

/// Polling settle monitor (real impl of the Core `SettleMonitor` seam). Drives
/// the pure `SettlePoller` with a real monotonic clock + `Thread.sleep` + a tree
/// re-walk, so the UI is declared settled only after it actually quiesces. Never
/// gates on AXObserver notifications.
public final class KitSettleMonitor: SettleMonitor {
    /// Re-walks the target's pruned tree for the current poll. Injected by the
    /// session so the monitor stays decoupled from the AX walker. Returns nil if
    /// the tree can't be read this poll (treated as an empty fingerprint feed).
    public typealias TreeSampler = () -> [Node]?

    private let sampler: TreeSampler
    private let pollInterval: Double
    private let lock = NSLock()
    private var _cancelled = false

    public init(pollInterval: Double = 0.08, sampler: @escaping TreeSampler = { nil }) {
        self.pollInterval = pollInterval
        self.sampler = sampler
    }

    public func waitForSettle(context: String, timeout: Double, quietPeriod: Double) -> SettleResult {
        reset()
        let poller = SettlePoller(quietPeriod: quietPeriod, maxWait: timeout, pollInterval: pollInterval)
        return poller.run(
            now: { DispatchTime.now().uptimeNanoseconds.toSeconds },
            sample: { [sampler] in
                let nodes = sampler() ?? []
                return (TreeFingerprint.compute(nodes), TreeFingerprint.keyFrameRects(nodes))
            },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            isCancelled: { [weak self] in self?.cancelledFlag ?? false }
        )
    }

    /// Liveness-driven, never an AXObserver flag (Inv 10 — stale recovery is the
    /// GraphLocator re-walk in US-038, not a notification gate). The poll itself
    /// surfaces structural change, so this stays false.
    public var isInvalidated: Bool { false }

    public func reset() {
        lock.lock(); _cancelled = false; lock.unlock()
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    private var cancelledFlag: Bool {
        lock.lock(); defer { lock.unlock() }; return _cancelled
    }
}

private extension UInt64 {
    var toSeconds: Double { Double(self) / 1_000_000_000.0 }
}

#endif
