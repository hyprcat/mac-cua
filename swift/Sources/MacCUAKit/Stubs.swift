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

/// Real Kit handle wrapping a captured `CGImage` (US-022). Stub for now.
public final class KitCapturedImage: CapturedImage {
    public var width: Int { unimplemented() }
    public var height: Int { unimplemented() }
    public func pngBase64() -> String { unimplemented() }
}

/// Real Kit `EditableTextObject` wrapper (US-033/US-040). Stub for now.
public final class KitEditableText: EditableText {
    public var text: String { unimplemented() }
    public func setText(_ text: String) throws { unimplemented() }
    public func insertText(_ text: String) throws { unimplemented() }
}

// MARK: - AppResolver (real impl lives in KitAppResolver.swift, US-016)

// MARK: - AccessibilityProvider (US-017/018/019/020/021)

public final class KitAccessibilityProvider: AccessibilityProvider {
    public init() {}
    public func walkTree(axElement: AXElementRef, targetPid: Int?, maxDepth: Int, maxNodes: Int, includeActions: Bool, includeStates: Bool) throws -> [Node] { unimplemented() }
    public func getKeyWindow(axApp: AXElementRef) -> AXElementRef? { nil }
    public func getWindows(axApp: AXElementRef) -> [AXElementRef] { [] }
    public func getMenuBar(axApp: AXElementRef) -> AXElementRef? { nil }
    public func getWindowTitle(axWindow: AXElementRef) -> String? { nil }
    public func getFocusedElement(axApp: AXElementRef, tree: [Node]) -> Int? { nil }
    public func getElementFrame(node: Node) -> Rect? { nil }
    public func elementAtPosition(axApp: AXElementRef, x: Double, y: Double) -> AXElementRef? { nil }
    public func getPid(axElement: AXElementRef) -> Int? { nil }
    public func refsEqual(_ a: AXElementRef?, _ b: AXElementRef?) -> Bool { a === b }
    public func nodeFromRef(_ element: AXElementRef, depth: Int, index: Int) throws -> Node { unimplemented() }
    public func getActionNamesForRef(_ element: AXElementRef) -> [String] { [] }
    public func getParentRef(_ element: AXElementRef) -> AXElementRef? { nil }
    public func getChildren(_ element: AXElementRef) -> [AXElementRef] { [] }
    public func hasScrollbarRef(_ element: AXElementRef) -> Bool { false }
    public func getAttributeValue(_ element: AXElementRef, _ attr: String) -> String? { nil }
    public func isAttributeSettable(node: Node, _ attr: String) -> Bool { false }
    public func performAction(node: Node, action: String) throws { unimplemented() }
    public func performActionOnRef(_ axRef: AXElementRef, action: String) throws { unimplemented() }
    public func setAttribute(node: Node, _ attr: String, _ value: String) throws { unimplemented() }
    public func makeEditableText(element: AXElementRef, pid: Int?) -> EditableText? { nil }
    public func extractWebAreaText(_ element: AXElementRef, targetPid: Int?) -> String? { nil }
    public func extractTextAreaContent(_ element: AXElementRef, targetPid: Int?) -> String? { nil }
    public func getWebURL(_ element: AXElementRef) -> String? { nil }
}

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
    public func listWindows(ownerPid: Int?) -> [WindowInfo] { [] }
    public func getWindowBounds(windowId: Int) -> Rect? { nil }
    public func getWindowPid(windowId: Int) -> Int? { nil }
    public func findWindowIdForAXWindow(pid: Int, axWindow: AXElementRef) -> Int? { nil }
    public func captureWindow(windowId: Int, includeCursor: Bool) throws -> CapturedImage? { unimplemented() }
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
