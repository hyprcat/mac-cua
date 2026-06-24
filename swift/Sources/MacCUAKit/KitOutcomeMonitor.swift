// US-037 — Transport confirmation (Kit impl).
//
// Real implementation of the Core `OutcomeMonitor` seam's transport half: a
// LISTEN-ONLY session CGEventTap (`kCGEventTapOptionListenOnly` — Invariant 5,
// never suppresses or modifies user events) installed on the dedicated
// `KitRunLoopThread`. For each input event it reads field 45
// (`eventSourceStateID`); if it matches this session's private event source it
// is an echo of OUR synthetic event, so transport is confirmed (Invariant 4).
//
// The pure ring buffer + sequence/expectation logic lives in
// `MacCUACore.CGEventHistory` / `CGEventSequenceExpectation`; this file owns only
// the tap lifecycle, the lock, and the poll loop. Nothing here foregrounds,
// activates, raises, or warps the cursor (Prime Invariant) — a listen-only tap is
// purely observational.
//
// The AX outcome half (`verifyAX`) stays inert: post-delivery AX verification is
// deliberately disabled on the primary paths (Invariant 21); the fresh snapshot
// is ground truth. The spine only consults `verifyTransport`/`computeVerdict`.

#if os(macOS)
import Foundation
import CoreGraphics
import MacCUACore

public final class KitOutcomeMonitor: OutcomeMonitor {
    private let history = CGEventHistory()
    private let lock = NSLock()
    /// The session's private `CGEventSource` state ID. Only events whose field-45
    /// source-state-id equals this are our echoes. `nil` ⇒ unfiltered (records any
    /// input event — a weaker confirmation; wired filter is preferred).
    private let expectedSourceStateID: Int?
    private let runLoop: KitRunLoopThread

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installed = false

    /// - Parameters:
    ///   - expectedSourceStateID: this session's `CGEventSourceGetSourceStateID`.
    ///   - runLoop: the shared dedicated run-loop thread hosting listen-only taps.
    public init(expectedSourceStateID: Int? = nil, runLoop: KitRunLoopThread = KitRunLoopThread()) {
        self.expectedSourceStateID = expectedSourceStateID
        self.runLoop = runLoop
    }

    // MARK: OutcomeMonitor

    public func mark() -> Int {
        ensureInstalled()
        lock.lock(); defer { lock.unlock() }
        return history.mark()
    }

    /// AX-action outcome verification is disabled on the primary paths (Inv 21):
    /// snapshot is ground truth. Always reports `.timeout` (no AXObserver gate).
    public func verifyAX(contract: VerificationContract, mark: Int?, timeout: Double) -> ActionVerificationResult {
        .timeout
    }

    /// Poll the source-filtered history until an echo appears or the deadline
    /// passes. A matched echo (any of our input events since `startSequence`)
    /// means the synthetic event reached the session tap = transport confirmed.
    public func verifyTransport(startSequence: Int, timeout: Double) -> Bool {
        ensureInstalled()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            lock.lock()
            let confirmed = history.hasEventsSince(startSequence)
            lock.unlock()
            if confirmed { return true }
            Thread.sleep(forTimeInterval: 0.005)
        } while Date() < deadline
        lock.lock(); defer { lock.unlock() }
        return history.hasEventsSince(startSequence)
    }

    // MARK: Tap lifecycle

    private func ensureInstalled() {
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        lock.unlock()

        runLoop.start()
        guard let loop = runLoop.runLoop else { return }

        var mask: CGEventMask = 0
        for type in CGEventTypeNumber.allInputEvents { mask |= (1 << CGEventMask(type)) }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,                 // Invariant 5: never modify/suppress
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<KitOutcomeMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    monitor.handle(event: event)
                }
                return Unmanaged.passUnretained(event)  // pass through untouched
            },
            userInfo: refcon
        ) else { return }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(loop, src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        lock.lock()
        tap = port
        runLoopSource = src
        lock.unlock()
    }

    /// Tap callback body — record only our session's echoes (or all, if unfiltered).
    private func handle(event: CGEvent) {
        let type = Int(event.type.rawValue)
        if let expected = expectedSourceStateID {
            let sourceID = Int(event.getIntegerValueField(
                CGEventField(rawValue: CGEventFieldNumber.eventSourceStateID)!))
            if sourceID != expected { return }
        }
        lock.lock()
        history.record(eventType: type)
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let port = tap
        let src = runLoopSource
        tap = nil
        runLoopSource = nil
        installed = false
        history.clear()
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let src, let loop = runLoop.runLoop {
            CFRunLoopRemoveSource(loop, src, .commonModes)
        }
    }
}
#endif
