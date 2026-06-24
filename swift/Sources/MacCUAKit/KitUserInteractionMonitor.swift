// US-044 — User-interruption monitor (Kit impl).
//
// Real implementation of the Core `UserInteractionMonitoring` seam. A LISTEN-ONLY
// session CGEventTap (`kCGEventTapOptionListenOnly` — Invariant 5, never
// suppresses or modifies user events) for left/right mouse-down + key-down,
// installed on the dedicated `KitRunLoopThread`. For each event it reads the
// target pid (field 39, `kCGEventTargetUnixProcessID`); only events targeting the
// monitored app are forwarded to the pure `UserInteractionState` debounce. When
// the model next calls `checkInterruption` and the debounce has fired, it yields a
// one-shot warning so the agent stops and re-queries (Invariant 16).
//
// Nothing here foregrounds, activates, raises, or warps the cursor (Prime
// Invariant) — a listen-only tap is purely observational. The debounce/warning
// logic is the pure, Linux-tested `MacCUACore.UserInteractionState`; this file
// owns only the tap lifecycle, the lock, the clock, and bundle-id resolution.

#if os(macOS)
import Foundation
import CoreGraphics
import AppKit
import MacCUACore

public final class KitUserInteractionMonitor: UserInteractionMonitoring {
    private let lock = NSLock()
    private var state: UserInteractionState
    private let runLoop: KitRunLoopThread

    /// The app whose user-interaction we currently watch for. nil ⇒ not monitoring.
    private var monitoredPid: Int?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installed = false

    public init(debounceDuration: Double = 0.5, runLoop: KitRunLoopThread = KitRunLoopThread()) {
        self.state = UserInteractionState(debounceDuration: debounceDuration)
        self.runLoop = runLoop
    }

    // MARK: UserInteractionMonitoring

    public func startMonitoring(pid: Int) {
        lock.lock()
        monitoredPid = pid
        state.reset()
        lock.unlock()
        ensureInstalled()
    }

    public func stopMonitoring() {
        lock.lock()
        monitoredPid = nil
        state.reset()
        lock.unlock()
    }

    public func checkInterruption(bundleId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return state.consumeInterruption(bundleId: bundleId, now: ProcessInfo.processInfo.systemUptime)
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
        for type in [CGEventTypeNumber.leftMouseDown,
                     CGEventTypeNumber.rightMouseDown,
                     CGEventTypeNumber.keyDown] {
            mask |= (1 << CGEventMask(type))
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,                 // Invariant 5: never modify/suppress
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                if let refcon {
                    let monitor = Unmanaged<KitUserInteractionMonitor>.fromOpaque(refcon).takeUnretainedValue()
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

    /// Tap callback body — record only events targeting the monitored app.
    private func handle(event: CGEvent) {
        lock.lock()
        guard let pid = monitoredPid else { lock.unlock(); return }
        lock.unlock()

        // Field 39 = kCGEventTargetUnixProcessID: which process this event is for.
        let targetPid = Int(event.getIntegerValueField(.eventTargetUnixProcessID))
        guard targetPid == pid else { return }

        guard let bundleId = Self.resolveBundleId(pid: targetPid), !bundleId.isEmpty else { return }

        lock.lock()
        state.recordInteraction(bundleId: bundleId, now: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    private static func resolveBundleId(pid: Int) -> String? {
        NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
    }

    public func teardown() {
        lock.lock()
        let port = tap
        let src = runLoopSource
        tap = nil
        runLoopSource = nil
        installed = false
        monitoredPid = nil
        state.reset()
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
        if let src, let loop = runLoop.runLoop {
            CFRunLoopRemoveSource(loop, src, .commonModes)
        }
    }
}
#endif
