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
    // --- Additive hooks for session-resolution tests ---
    /// Per-pid AX app override so cross-app fallback tests can hand each running
    /// app a distinct AX root. nil → the shared `axApp`. [SPINE TEST HOOK]
    var axAppForPid: [Int: AXElementRef]?
    /// Pids whose `getAXAppForPid` should throw (simulate a dead/inaccessible app).
    var throwAXForPids: Set<Int> = []
    func getAXAppForPid(_ pid: Int, bundleId: String?) throws -> (axApp: AXElementRef, pid: Int) {
        if throwAXForPids.contains(pid) { throw AutomationError.ax("no ax app for pid \(pid)") }
        return (axAppForPid?[pid] ?? axApp, pid)
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

    // --- Additive hooks for handler tests ---
    /// Per-node frame override (keyed by the Node identity), used when the node has
    /// no position/size of its own. Falls back to position/size derivation.
    var frameForNode: ((Node) -> Rect?)?
    /// Hit-test result for `elementAtPosition`.
    var hitTestRef: AXElementRef?
    /// Action names for `getActionNamesForRef`.
    var actionNamesForRef: [String] = []
    /// EditableText returned by `makeEditableText` (nil disables the AX text path).
    var editableText: EditableText? = FakeEditableText()
    /// Whether `setAttribute` should throw (simulates an unsupported attribute).
    var setAttributeThrows = false
    /// Whether `performAction` should throw.
    var performActionThrows = false
    private(set) var performedOnRef: [String] = []

    /// Explicit AX window list (drives `getWindows`). nil → derive from keyWindow.
    /// Used by the AX-window signature-matching resolution tests. [SPINE TEST HOOK]
    var windowList: [AXElementRef]?
    /// Per-axApp window list (consulted before `windowList`). Lets cross-app
    /// fallback tests give each app a distinct window set. [SPINE TEST HOOK]
    var windowsForAXApp: ((AXElementRef) -> [AXElementRef]?)?
    /// Per-axApp children for `getChildren` (focused-collection expansion tests).
    var childrenForRef: ((AXElementRef) -> [AXElementRef])?
    /// Scrollbar predicate for `hasScrollbarRef`.
    var scrollbarRefs: Set<ObjectIdentifier> = []

    /// Count of `walkTree` invocations — lets batch tests assert the pre-action
    /// tree is reused (walked once) instead of re-walked per step. [SPINE TEST HOOK]
    private(set) var walkCount = 0
    func walkTree(axElement: AXElementRef, targetPid: Int?, maxDepth: Int, maxNodes: Int,
                  includeActions: Bool, includeStates: Bool) throws -> [Node] {
        walkCount += 1
        return tree
    }
    func getKeyWindow(axApp: AXElementRef) -> AXElementRef? { keyWindow }
    func getWindows(axApp: AXElementRef) -> [AXElementRef] {
        if let perApp = windowsForAXApp?(axApp) { return perApp }
        if let windowList { return windowList }
        return keyWindow.map { [$0] } ?? []
    }
    /// Records enableEnhancedUI(pid:) calls so spine tests assert A1 priming.
    private(set) var enhancedUIPids: [Int] = []
    func enableEnhancedUI(axApp: AXElementRef, pid: Int) throws -> Bool {
        enhancedUIPids.append(pid)
        return true
    }
    func getMenuBar(axApp: AXElementRef) -> AXElementRef? { nil }
    func getWindowTitle(axWindow: AXElementRef) -> String? { "Untitled" }
    func getFocusedElement(axApp: AXElementRef, tree: [Node]) -> Int? { focusedIndex }
    func getElementFrame(node: Node) -> Rect? {
        if let f = frameForNode?(node) { return f }
        return node.position.flatMap { p in node.size.map { Rect(x: p.x, y: p.y, w: $0.w, h: $0.h) } }
    }
    func elementAtPosition(axApp: AXElementRef, x: Double, y: Double) -> AXElementRef? { hitTestRef }
    func getPid(axElement: AXElementRef) -> Int? { nil }
    func refsEqual(_ a: AXElementRef?, _ b: AXElementRef?) -> Bool { a === b }
    /// Build a node from a ref (used by live-collection-child expansion). nil →
    /// default group node. [SPINE TEST HOOK]
    var nodeForRef: ((_ element: AXElementRef, _ depth: Int, _ index: Int) -> Node)?
    func nodeFromRef(_ element: AXElementRef, depth: Int, index: Int) throws -> Node {
        if let nodeForRef { return nodeForRef(element, depth, index) }
        return Node(index: index, role: "group", depth: depth, axRef: element)
    }
    func getActionNamesForRef(_ element: AXElementRef) -> [String] { actionNamesForRef }
    func getParentRef(_ element: AXElementRef) -> AXElementRef? { nil }
    func getChildren(_ element: AXElementRef) -> [AXElementRef] {
        childrenForRef?(element) ?? []
    }
    func hasScrollbarRef(_ element: AXElementRef) -> Bool {
        scrollbarRefs.contains(ObjectIdentifier(element))
    }
    func getAttributeValue(_ element: AXElementRef, _ attr: String) -> String? { nil }
    func isAttributeSettable(node: Node, _ attr: String) -> Bool { true }
    /// Liveness probe hook (US-038). Defaults to assume-alive; set to simulate a
    /// dead cached ref and force the spine's re-walk + locator rebind.
    var aliveForNode: ((Node) -> Bool)?
    func isElementAlive(node: Node) -> Bool { aliveForNode?(node) ?? true }
    func performAction(node: Node, action: String) throws {
        if performActionThrows { throw AutomationError.ax("perform failed") }
        performed.append((action, node.index))
    }
    func performActionOnRef(_ axRef: AXElementRef, action: String) throws { performedOnRef.append(action) }
    func setAttribute(node: Node, _ attr: String, _ value: String) throws {
        if setAttributeThrows { throw AutomationError.ax("set failed") }
        setAttributes.append((attr, value, node.index))
    }
    func makeEditableText(element: AXElementRef, pid: Int?) -> EditableText? { editableText }
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

    // --- Additive hooks for session-resolution tests ---
    /// Per-window-id pid override (consulted before the window list). Lets a test
    /// say "window N is owned by pid P" without a full WindowInfo. [SPINE TEST HOOK]
    var pidForWindowId: [Int: Int]?
    /// AX-window → window-id signature match. When set, drives the AX window
    /// matching path (`_find_ax_window_for_window_id`). Keyed by the opaque ref
    /// identity. nil → falls back to `windows.first?.windowId`. [SPINE TEST HOOK]
    var windowIdForAXWindow: ((AXElementRef) -> Int?)?
    private(set) var captureCalls: [Int] = []
    /// Make captureWindow throw / return nil to exercise the screenshot-retry arm.
    var captureReturnsNil = false

    func listWindows(ownerPid: Int?) -> [WindowInfo] {
        guard let ownerPid else { return windows }
        return windows.filter { $0.ownerPid == ownerPid }
    }
    func getWindowBounds(windowId: Int) -> Rect? { bounds }
    func getWindowPid(windowId: Int) -> Int? {
        if let map = pidForWindowId { return map[windowId] }
        return windows.first(where: { $0.windowId == windowId })?.ownerPid
    }
    func findWindowIdForAXWindow(pid: Int, axWindow: AXElementRef) -> Int? {
        if let hook = windowIdForAXWindow { return hook(axWindow) }
        return windows.first?.windowId
    }
    func captureWindow(windowId: Int, includeCursor: Bool) throws -> CapturedImage? {
        captureCalls.append(windowId)
        return captureReturnsNil ? nil : image
    }
    func checkScreenRecordingPermission() -> Bool { screenRecordingGranted }
    func promptScreenRecordingPermission() -> Bool { screenRecordingGranted }
}

// MARK: - OCR (US-046)

final class FakeOCR: OCRProvider {
    /// Observations returned by `recognizeText`.
    var observations: [OCRObservation] = []
    /// Records every call so a test can assert OCR was (or was NOT) invoked.
    private(set) var recognizeCalls = 0

    init(observations: [OCRObservation] = []) {
        self.observations = observations
    }

    func recognizeText(in image: CapturedImage) -> [OCRObservation] {
        recognizeCalls += 1
        return observations
    }
}

// MARK: - Selection / settle / outcome / focus

final class FakeSelection: SelectionProvider {
    var selection: String?
    // --- select_text seam hooks (US-010) ---
    /// Text returned by `selectableText` (the field's whole contents).
    var text: String = ""
    /// Make `selectableText` throw (no target / no focused field).
    var selectableTextThrows = false
    /// Make `applySelection` throw (selection failed in the real impl).
    var applyThrows = false
    private(set) var appliedRanges: [MacCUACore.TextRange] = []
    private(set) var selectableTextCalls: [Bool] = []  // recorded: was an axRef supplied?

    func startObserving(pid: Int) {}
    func stopObserving() {}
    func currentSelection() -> String? { selection }
    func selectableText(axRef: AXElementRef?) throws -> String {
        selectableTextCalls.append(axRef != nil)
        if selectableTextThrows { throw AutomationError.ax("no selectable text target") }
        return text
    }
    func applySelection(axRef: AXElementRef?, range: MacCUACore.TextRange) throws {
        if applyThrows { throw AutomationError.ax("selection apply failed") }
        appliedRanges.append(range)
    }
}

final class FakeClipboard: ClipboardProvider {
    var contents: String?
    var getThrows = false
    var setThrows = false
    var clearThrows = false
    private(set) var sets: [String] = []
    private(set) var clears = 0

    func get() throws -> String? {
        if getThrows { throw AutomationError.automation("clipboard get failed") }
        return contents
    }
    func set(_ text: String) throws {
        if setThrows { throw AutomationError.automation("clipboard set failed") }
        contents = text
        sets.append(text)
    }
    func clear() throws {
        if clearThrows { throw AutomationError.automation("clipboard clear failed") }
        contents = nil
        clears += 1
    }
}

final class FakeSettleMonitor: SettleMonitor {
    var invalidated = false
    private(set) var waits = 0
    // --- Additive recorders for spine/pipeline tests ---
    /// Per-call record of (context, timeout, quietPeriod) so tests can assert the
    /// settle step ran (or was skipped) and with what budget (short-settle cap).
    private(set) var calls: [(context: String, timeout: Double, quietPeriod: Double)] = []
    private(set) var cancelled = false
    /// What `waitForSettle` returns; tests flip this to `.timeout` to exercise
    /// the "hit the cap" path.
    var result: SettleResult = .settled
    func waitForSettle(context: String, timeout: Double, quietPeriod: Double) -> SettleResult {
        waits += 1
        calls.append((context, timeout, quietPeriod))
        return result
    }
    var isInvalidated: Bool { invalidated }
    func reset() { invalidated = false }
    func cancel() { cancelled = true }
}

/// A capturing factory for `SettleMonitor`s. Hands each created monitor back to
/// the test so it can assert on the per-session settle budget (the
/// `makeFakeProviders` default discards them). [SPINE TEST HOOK]
final class RecordingSettleFactory {
    private(set) var created: [FakeSettleMonitor] = []
    var preset: FakeSettleMonitor?
    func make(_ session: AppSession) -> SettleMonitor {
        let monitor = preset ?? FakeSettleMonitor()
        created.append(monitor)
        return monitor
    }
    /// The most recently created monitor (the one bound to the active session).
    var last: FakeSettleMonitor? { created.last }
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
    // Track whether monitoring is active so checkInterruption only yields while
    // monitoring — mirrors the real monitor, which returns nil when idle. The
    // spine starts monitoring only for non-state tools. [SPINE TEST HOOK]
    private(set) var monitoring = false
    func startMonitoring(pid: Int) { monitoring = true }
    func stopMonitoring() { monitoring = false }
    func checkInterruption(bundleId: String) -> String? { monitoring ? interruption : nil }
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

final class FakeScreenLock: ScreenLockProvider {
    var locked: Bool
    init(locked: Bool = false) { self.locked = locked }
    func isScreenLocked() -> Bool { locked }
}

// MARK: - Bundle helper

/// Build a `Providers` from fakes. Tests pass overrides as needed. The factory
/// closures default to fresh per-session fakes; tests that need to observe a
/// per-session monitor pass an explicit factory (e.g. `RecordingSettleFactory`
/// or a captured `FakeMenuTracking`). [SPINE TEST HOOK — additive params]
func makeFakeProviders(
    apps: FakeAppResolver = FakeAppResolver(),
    accessibility: FakeAccessibility = FakeAccessibility(),
    input: FakeInput = FakeInput(),
    capture: FakeCapture = FakeCapture(),
    clipboard: FakeClipboard = FakeClipboard(),
    ocr: OCRProvider? = nil,
    auditSink: AuditSink? = nil,
    frontmost: FakeFrontmostTracking = FakeFrontmostTracking(),
    userInteraction: FakeUserInteraction = FakeUserInteraction(),
    screenLock: ScreenLockProvider? = nil,
    makeSettleMonitor: @escaping (AppSession) -> SettleMonitor = { _ in FakeSettleMonitor() },
    makeMenuTracker: @escaping (AppSession) -> MenuTracking = { _ in FakeMenuTracking() },
    makeSelectionClient: @escaping (AppSession) -> SelectionProvider = { _ in FakeSelection() }
) -> Providers {
    Providers(
        apps: apps,
        accessibility: accessibility,
        input: input,
        capture: capture,
        auditSink: auditSink,
        clipboard: clipboard,
        ocr: ocr,
        frontmostTracker: frontmost,
        userInteractionMonitor: userInteraction,
        screenLock: screenLock,
        makeSettleMonitor: makeSettleMonitor,
        makeAXOutcomeMonitor: { _ in FakeOutcomeMonitor() },
        makeCGEventOutcomeMonitor: { _ in FakeOutcomeMonitor() },
        makeMenuTracker: makeMenuTracker,
        makeSelectionClient: makeSelectionClient,
        makeEditableText: { _, _ in FakeEditableText() }
    )
}
