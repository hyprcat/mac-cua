import Foundation
import MacCUACore
@testable import MacCUAServer

// Fake providers for the Linux-buildable Server tests. Each conforms fully to a
// Core provider seam with controllable, side-effect-free behavior. Tests build a
// `Providers` bundle from these (see `makeFakeProviders`) and assert on recorded
// calls. The handler/spine sub-agents extend these with the hooks their tests
// need; keep the conformances complete so the package always compiles.

// MARK: - Opaque seam fakes

final class FakeAXRef: AXElementRef {
    let id: String
    init(_ id: String) { self.id = id }
}

final class FakeEventSource: EventSource {}

final class FakeImage: CapturedImage {
    let width: Int
    let height: Int
    init(width: Int = 100, height: Int = 100) { self.width = width; self.height = height }
    func pngBase64() -> String { "ZmFrZS1wbmc=" } // "fake-png"
}

final class FakeEditableText: EditableText {
    var text: String
    init(_ text: String = "") { self.text = text }
    func setText(_ text: String) throws { self.text = text }
    func insertText(_ text: String) throws { self.text += text }
}

// MARK: - AppResolver

final class FakeAppResolver: AppResolver {
    var running: [AppInfo] = []
    var recent: [AppInfo] = []
    var frontmost: AppInfo?
    var axApp: AXElementRef = FakeAXRef("ax-app")
    var resolved: AppInfo?
    var launchPid = 4242
    private(set) var restoreCalls: [AppInfo?] = []
    var accessibilityGranted = true

    func listRunningApps() -> [AppInfo] { running }
    func listRecentApps() -> [AppInfo] { recent }
    func resolveApp(_ hint: String) throws -> AppInfo {
        if let resolved { return resolved }
        if let hit = running.first(where: { $0.bundleId == hint || $0.name == hint }) { return hit }
        throw AutomationError.automation("app not found: \(hint)")
    }
    func resolveRunningAppByPid(_ pid: Int) -> AppInfo? {
        running.first(where: { $0.pid == pid })
    }
    func launchApp(bundleId: String) throws -> Int { launchPid }
    func getAXApp(bundleId: String, knownPid: Int?) throws -> (axApp: AXElementRef, pid: Int) {
        (axApp, knownPid ?? launchPid)
    }
    func getAXAppForPid(_ pid: Int, bundleId: String?) throws -> (axApp: AXElementRef, pid: Int) {
        (axApp, pid)
    }
    func getFrontmostApp() -> AppInfo? { frontmost }
    func restoreFrontmostApp(_ app: AppInfo?) { restoreCalls.append(app) }
    func checkAccessibilityPermission(prompt: Bool) -> Bool { accessibilityGranted }
}

// MARK: - AccessibilityProvider

final class FakeAccessibility: AccessibilityProvider {
    var tree: [Node] = []
    var keyWindow: AXElementRef? = FakeAXRef("ax-window")
    var frames: [ObjectIdentifier: Rect] = [:]
    var focusedIndex: Int?
    private(set) var performed: [(action: String, index: Int)] = []
    private(set) var setAttributes: [(attr: String, value: String, index: Int)] = []

    func walkTree(axElement: AXElementRef, targetPid: Int?, maxDepth: Int, maxNodes: Int,
                  includeActions: Bool, includeStates: Bool) throws -> [Node] { tree }
    func getKeyWindow(axApp: AXElementRef) -> AXElementRef? { keyWindow }
    func getWindows(axApp: AXElementRef) -> [AXElementRef] { keyWindow.map { [$0] } ?? [] }
    func getMenuBar(axApp: AXElementRef) -> AXElementRef? { nil }
    func getWindowTitle(axWindow: AXElementRef) -> String? { "Untitled" }
    func getFocusedElement(axApp: AXElementRef, tree: [Node]) -> Int? { focusedIndex }
    func getElementFrame(node: Node) -> Rect? { node.position.flatMap { p in node.size.map { Rect(x: p.x, y: p.y, w: $0.w, h: $0.h) } } }
    func elementAtPosition(axApp: AXElementRef, x: Double, y: Double) -> AXElementRef? { nil }
    func getPid(axElement: AXElementRef) -> Int? { nil }
    func refsEqual(_ a: AXElementRef?, _ b: AXElementRef?) -> Bool { a === b }
    func nodeFromRef(_ element: AXElementRef, depth: Int, index: Int) throws -> Node {
        Node(index: index, role: "group", depth: depth, axRef: element)
    }
    func getActionNamesForRef(_ element: AXElementRef) -> [String] { [] }
    func getParentRef(_ element: AXElementRef) -> AXElementRef? { nil }
    func getChildren(_ element: AXElementRef) -> [AXElementRef] { [] }
    func hasScrollbarRef(_ element: AXElementRef) -> Bool { false }
    func getAttributeValue(_ element: AXElementRef, _ attr: String) -> String? { nil }
    func isAttributeSettable(node: Node, _ attr: String) -> Bool { true }
    func performAction(node: Node, action: String) throws { performed.append((action, node.index)) }
    func performActionOnRef(_ axRef: AXElementRef, action: String) throws { }
    func setAttribute(node: Node, _ attr: String, _ value: String) throws {
        setAttributes.append((attr, value, node.index))
    }
    func makeEditableText(element: AXElementRef, pid: Int?) -> EditableText? { FakeEditableText() }
    func extractWebAreaText(_ element: AXElementRef, targetPid: Int?) -> String? { nil }
    func extractTextAreaContent(_ element: AXElementRef, targetPid: Int?) -> String? { nil }
    func getWebURL(_ element: AXElementRef) -> String? { nil }
}

// MARK: - InputProvider

final class FakeInput: InputProvider {
    private(set) var clicks: [(x: Double, y: Double, button: String, count: Int)] = []
    private(set) var drags: [(fromX: Double, fromY: Double, toX: Double, toY: Double)] = []
    private(set) var keys: [String] = []
    private(set) var typed: [String] = []
    private(set) var scrolls: [(direction: String, kind: String)] = []

    func createEventSource() -> EventSource { FakeEventSource() }
    func clickAt(pid: Int, windowId: Int, x: Double, y: Double, button: String, count: Int,
                 screenshotSize: (width: Int, height: Int)?, source: EventSource?) throws {
        clicks.append((x, y, button, count))
    }
    func clickAtScreenPoint(pid: Int, x: Double, y: Double, button: String, count: Int,
                            windowId: Int?, source: EventSource?) throws {
        clicks.append((x, y, button, count))
    }
    func drag(pid: Int, windowId: Int, fromX: Double, fromY: Double, toX: Double, toY: Double,
              screenshotSize: (width: Int, height: Int)?, source: EventSource?) throws {
        drags.append((fromX, fromY, toX, toY))
    }
    func pressKey(pid: Int, key: String, source: EventSource?) throws { keys.append(key) }
    func typeText(pid: Int, text: String, source: EventSource?) throws { typed.append(text) }
    func scrollPid(pid: Int, x: Double, y: Double, direction: String, clicks: Int,
                   windowId: Int?, source: EventSource?) throws {
        scrolls.append((direction, "line"))
    }
    func scrollPidPixel(pid: Int, x: Double, y: Double, direction: String, pixels: Int,
                        windowId: Int?, source: EventSource?) throws {
        scrolls.append((direction, "pixel"))
    }
    func windowToScreenCoords(windowId: Int, x: Double, y: Double,
                              screenshotSize: (width: Int, height: Int)?) -> (x: Double, y: Double)? {
        (x, y)
    }
}

// MARK: - CaptureProvider

final class FakeCapture: CaptureProvider {
    var windows: [WindowInfo] = []
    var bounds: Rect? = Rect(x: 0, y: 0, w: 800, h: 600)
    var image: CapturedImage? = FakeImage()
    var screenRecordingGranted = true

    func listWindows(ownerPid: Int?) -> [WindowInfo] {
        guard let ownerPid else { return windows }
        return windows.filter { $0.ownerPid == ownerPid }
    }
    func getWindowBounds(windowId: Int) -> Rect? { bounds }
    func getWindowPid(windowId: Int) -> Int? { windows.first(where: { $0.windowId == windowId })?.ownerPid }
    func findWindowIdForAXWindow(pid: Int, axWindow: AXElementRef) -> Int? { windows.first?.windowId }
    func captureWindow(windowId: Int, includeCursor: Bool) throws -> CapturedImage? { image }
    func checkScreenRecordingPermission() -> Bool { screenRecordingGranted }
    func promptScreenRecordingPermission() -> Bool { screenRecordingGranted }
}

// MARK: - Selection / settle / outcome / focus

final class FakeSelection: SelectionProvider {
    var selection: String?
    func startObserving(pid: Int) {}
    func stopObserving() {}
    func currentSelection() -> String? { selection }
}

final class FakeSettleMonitor: SettleMonitor {
    var invalidated = false
    private(set) var waits = 0
    func waitForSettle(context: String, timeout: Double, quietPeriod: Double) -> SettleResult {
        waits += 1; return .settled
    }
    var isInvalidated: Bool { invalidated }
    func reset() { invalidated = false }
    func cancel() {}
}

final class FakeOutcomeMonitor: OutcomeMonitor {
    var axResult: ActionVerificationResult = .confirmed
    var transportOK = true
    func mark() -> Int { 0 }
    func verifyAX(contract: VerificationContract, mark: Int?, timeout: Double) -> ActionVerificationResult { axResult }
    func verifyTransport(startSequence: Int, timeout: Double) -> Bool { transportOK }
}

final class FakeUserInteraction: UserInteractionMonitoring {
    var interruption: String?
    func startMonitoring(pid: Int) {}
    func stopMonitoring() {}
    func checkInterruption(bundleId: String) -> String? { interruption }
}

final class FakeMenuTracking: MenuTracking {
    var menusOpen: Bool = false
    func start(pid: Int) {}
    func stop() {}
}

final class FakeFrontmostTracking: FrontmostTracking {
    var frontmost: AppInfo?
    func start() {}
    func stop() {}
    func currentFrontmost() -> AppInfo? { frontmost }
}

// MARK: - Bundle helper

/// Build a `Providers` from fakes. Tests pass overrides as needed.
func makeFakeProviders(
    apps: FakeAppResolver = FakeAppResolver(),
    accessibility: FakeAccessibility = FakeAccessibility(),
    input: FakeInput = FakeInput(),
    capture: FakeCapture = FakeCapture(),
    frontmost: FakeFrontmostTracking = FakeFrontmostTracking(),
    userInteraction: FakeUserInteraction = FakeUserInteraction()
) -> Providers {
    Providers(
        apps: apps,
        accessibility: accessibility,
        input: input,
        capture: capture,
        frontmostTracker: frontmost,
        userInteractionMonitor: userInteraction,
        makeSettleMonitor: { _ in FakeSettleMonitor() },
        makeAXOutcomeMonitor: { _ in FakeOutcomeMonitor() },
        makeCGEventOutcomeMonitor: { _ in FakeOutcomeMonitor() },
        makeMenuTracker: { _ in FakeMenuTracking() },
        makeSelectionClient: { _ in FakeSelection() },
        makeEditableText: { _, _ in FakeEditableText() }
    )
}
