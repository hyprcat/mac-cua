// MacCUAKit — the macOS adapter layer that provides the real implementations of
// the MacCUACore provider protocols (AppKit / ApplicationServices / CoreGraphics
// / ScreenCaptureKit / Vision behind #if os(macOS)).
//
// US-014 establishes the target: empty-but-compiling stubs that conform to every
// Core provider seam so the build graph (Core <- Kit <- executable) is wired and
// compiles on macOS, while the Linux build of Core/Server is unaffected (Kit is
// excluded from the package manifest on non-macOS hosts).
//
// Bodies here intentionally throw / fatalError("unimplemented") — the real
// macOS logic lands per-provider in Phases 3-6 (US-016 onward). Nothing here may
// foreground, activate, warp the cursor, or post globally (the Prime Invariant);
// the stubs simply do not act yet.

#if os(macOS)
import Foundation
import MacCUACore
import CSkyLightShim
import ApplicationServices
import CoreGraphics

private func unimplemented(_ fn: String = #function) -> Never {
    fatalError("MacCUAKit.\(fn) is not implemented yet (US-014 stub)")
}

// MARK: - Opaque platform seams

/// Real Kit handle wrapping an `AXUIElement`. US-016 populates the application
/// element (via `AXUIElementCreateApplication`); US-017 fleshes out the rest of
/// the walker around the same wrapper.
public final class KitAXElementRef: AXElementRef {
    public let element: AXUIElement?
    public init(_ element: AXUIElement? = nil) { self.element = element }
}

/// Real Kit handle wrapping a `CGEventSource` (US-028). Stub for now.
public final class KitEventSource: EventSource {
    public init() {}
}

// KitCapturedImage: real impl in KitCaptureProvider.swift (US-022).

/// Real Kit `EditableTextObject` wrapper (US-033/US-040). Stub for now.
public final class KitEditableText: EditableText {
    public var text: String { unimplemented() }
    public func setText(_ text: String) throws { unimplemented() }
    public func insertText(_ text: String) throws { unimplemented() }
}

// MARK: - AppResolver (real impl lives in KitAppResolver.swift, US-016)

// MARK: - AccessibilityProvider — real impl in KitAccessibilityProvider.swift (US-017)

// MARK: - InputProvider (US-028 onward)

public final class KitInputProvider: InputProvider {
    public init() {}
    public func createEventSource() -> EventSource { KitEventSource() }
    public func clickAt(pid: Int, windowId: Int, x: Double, y: Double, button: String, count: Int, screenshotSize: (width: Int, height: Int)?, source: EventSource?) throws { unimplemented() }
    public func clickAtScreenPoint(pid: Int, x: Double, y: Double, button: String, count: Int, windowId: Int?, source: EventSource?) throws { unimplemented() }
    public func drag(pid: Int, windowId: Int, fromX: Double, fromY: Double, toX: Double, toY: Double, screenshotSize: (width: Int, height: Int)?, source: EventSource?) throws { unimplemented() }
    public func pressKey(pid: Int, key: String, source: EventSource?) throws { unimplemented() }
    public func typeText(pid: Int, text: String, source: EventSource?) throws { unimplemented() }
    public func scrollPid(pid: Int, x: Double, y: Double, direction: String, clicks: Int, windowId: Int?, source: EventSource?) throws { unimplemented() }
    public func scrollPidPixel(pid: Int, x: Double, y: Double, direction: String, pixels: Int, windowId: Int?, source: EventSource?) throws { unimplemented() }
    public func windowToScreenCoords(windowId: Int, x: Double, y: Double, screenshotSize: (width: Int, height: Int)?) -> (x: Double, y: Double)? { nil }
}

// MARK: - CaptureProvider (US-022/023/024)

public final class KitCaptureProvider: CaptureProvider {
    public init() {}
    // listWindows/getWindowBounds/getWindowPid: real impl in KitCaptureProvider.swift (US-022).
    // findWindowIdForAXWindow: real impl in KitWindowBinding.swift (US-020, A4).
    // captureWindow: real SCK impl in KitCaptureProvider.swift (US-022).
    /// Real Screen-Recording preflight (US-015): query without prompting.
    public func checkScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Real Screen-Recording request (US-015): surfaces the system dialog on
    /// first use and returns whether access is granted. Non-foregrounding.
    public func promptScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

// MARK: - SelectionProvider (US-040)

public final class KitSelectionProvider: SelectionProvider {
    public init() {}
    public func startObserving(pid: Int) {}
    public func stopObserving() {}
    public func currentSelection() -> String? { nil }
    public func selectableText(axRef: AXElementRef?) throws -> String { unimplemented() }
    public func applySelection(axRef: AXElementRef?, range: MacCUACore.TextRange) throws { unimplemented() }
}

// MARK: - ClipboardProvider (US-041)

public final class KitClipboardProvider: ClipboardProvider {
    public init() {}
    public func get() throws -> String? { unimplemented() }
    public func set(_ text: String) throws { unimplemented() }
    public func clear() throws { unimplemented() }
}

// MARK: - SettleMonitor (US-025)

public final class KitSettleMonitor: SettleMonitor {
    public init() {}
    public func waitForSettle(context: String, timeout: Double, quietPeriod: Double) -> SettleResult { .noChange }
    public var isInvalidated: Bool { false }
    public func reset() {}
    public func cancel() {}
}

// MARK: - OutcomeMonitor (US-037)

public final class KitOutcomeMonitor: OutcomeMonitor {
    public init() {}
    public func mark() -> Int { 0 }
    public func verifyAX(contract: VerificationContract, mark: Int?, timeout: Double) -> ActionVerificationResult { .timeout }
    public func verifyTransport(startSequence: Int, timeout: Double) -> Bool { false }
}

// MARK: - Focus / interruption services (US-044/045)

public final class KitUserInteractionMonitor: UserInteractionMonitoring {
    public init() {}
    public func startMonitoring(pid: Int) {}
    public func stopMonitoring() {}
    public func checkInterruption(bundleId: String) -> String? { nil }
}

public final class KitMenuTracker: MenuTracking {
    public init() {}
    public var menusOpen: Bool { false }
    public func start(pid: Int) {}
    public func stop() {}
}

public final class KitFrontmostTracker: FrontmostTracking {
    public init() {}
    public func start() {}
    public func stop() {}
    public func currentFrontmost() -> AppInfo? { nil }
}

#endif
