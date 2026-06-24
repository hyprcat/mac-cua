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

// KitEventSource: real impl in KitInputProvider.swift (US-028).

// KitCapturedImage: real impl in KitCaptureProvider.swift (US-022).

/// Real Kit `EditableTextObject` wrapper (US-033/US-040). Stub for now.
public final class KitEditableText: EditableText {
    public var text: String { unimplemented() }
    public func setText(_ text: String) throws { unimplemented() }
    public func insertText(_ text: String) throws { unimplemented() }
}

// MARK: - AppResolver (real impl lives in KitAppResolver.swift, US-016)

// MARK: - AccessibilityProvider — real impl in KitAccessibilityProvider.swift (US-017)

// MARK: - InputProvider — real impl in KitInputProvider.swift (US-028)

// MARK: - CaptureProvider (US-022/023/024)

public final class KitCaptureProvider: CaptureProvider {
    /// B2 (US-024): per-window cache of the resolved SCContentFilter, stored as
    /// `AnyObject` to avoid an availability annotation on a stored property (cast
    /// to SCContentFilter at the use sites, which are already availability-gated).
    /// Invalidated on display-config (callback) and window-replace (signature).
    let filterCache = CaptureFilterCache<AnyObject>()

    /// US-043: SCK circuit breaker. After 2 consecutive SCK failures (e.g. macOS
    /// screen recording holding ScreenCaptureKit) SCK is bypassed for 30 s and the
    /// private CG fallback runs immediately — no crash, no foregrounding (Inv 13).
    let sckBreaker = CircuitBreaker()

    public init() {
        registerDisplayReconfigurationObserver()
    }
    // listWindows/getWindowBounds/getWindowPid: real impl in KitCaptureProvider.swift (US-022).
    // findWindowIdForAXWindow: real impl in KitWindowBinding.swift (US-020, A4).
    // captureWindow: real SCK impl in KitCaptureProvider.swift (US-022).
    /// Real Screen-Recording preflight (US-015/US-026): query without
    /// prompting. Primary is `CGPreflightScreenCaptureAccess`; if it reports no
    /// access we fall back to the window-name heuristic (ported from
    /// `screenshot.check_screen_recording_permission`) — without the grant the
    /// window list returns windows with stripped names, so a single non-empty
    /// name proves access. Read-only, never foregrounds.
    public func checkScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let names = raw.map { $0[kCGWindowName as String] as? String }
        return PermissionsLogic.screenRecordingGrantedFromWindowNames(names)
    }

    /// Real Screen-Recording request (US-015): surfaces the system dialog on
    /// first use and returns whether access is granted. Non-foregrounding.
    public func promptScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

// MARK: - SelectionProvider — real impl in KitSelectionProvider.swift (US-040)

// MARK: - ClipboardProvider — real impl in KitClipboardProvider.swift (US-041)

// MARK: - SettleMonitor — real impl in KitRunLoop.swift (US-025)

// MARK: - OutcomeMonitor — real impl in KitOutcomeMonitor.swift (US-037)

// MARK: - UserInteractionMonitor — real impl in KitUserInteractionMonitor.swift (US-044)

// MARK: - Focus / interruption services (US-045)

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
