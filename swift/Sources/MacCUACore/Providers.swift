import Foundation

// Protocol seams for every macOS-touching capability the orchestration spine
// needs. `MacCUAServer` depends ONLY on these protocols; `MacCUAKit` (Phase 3+)
// provides the real macOS implementations, and the test target provides fakes.
//
// This is the core de-risking move from SWIFT_PORT_DESIGN.md §4.2: roughly half
// the codebase — and the entire `SessionManager.execute()` spine — builds and
// unit-tests on Linux because the framework layer is hidden behind these seams.
//
// Hard contracts carried over from the Prime Invariant (§3):
//   - InputProvider delivers ONLY per-pid (Invariant 1), never warps the cursor
//     (Invariant 2), modifiers ride as flags (Invariant 3).
//   - Reads never activate (Invariant 7); capture never foregrounds (Invariant 13).
//   - AX refs never reach the model (Invariant 8) — they stay behind AXElementRef.
//   - SkyLight symbols are individually optional (Invariant 17); no micro-activation
//     anywhere (Invariant 18).

// MARK: - Opaque platform seams

/// Opaque per-session synthetic-event source (a real `CGEventSource` in Kit).
/// Carried through input calls so the confirmation tap can match our private
/// state id (Invariant 4) and never confuse user input with the agent's.
public protocol EventSource: AnyObject {}

/// Opaque captured window image (a real `CGImage`/bitmap in Kit). Kept abstract
/// so the spine can size, encode and attach it without a framework dependency.
public protocol CapturedImage: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// Base64-encoded PNG, ready to attach as an MCP `ImageContent` block.
    func pngBase64() -> String
    /// Frame provenance (produced dims, backing scale, crop origin, window/display
    /// identity). `nil` for fakes / paths that don't populate it (US-023, B4).
    var captureMetadata: CaptureMetadata? { get }
}

public extension CapturedImage {
    var captureMetadata: CaptureMetadata? { nil }
}

/// Precise editable-text manipulation over an AX text element (a wrapper around
/// `EditableTextObject` in Python). Methods throw `AutomationError(.staleReference)`
/// on AX `-25205`/`-25212` so callers can recover (Invariant 10).
public protocol EditableText: AnyObject {
    var text: String { get }
    func setText(_ text: String) throws
    func insertText(_ text: String) throws
}

// MARK: - Exchanged value types

/// One app entry for `list_apps` and for resolution. `running` entries carry a
/// `pid`; recent (last-14-days) entries carry usage metadata.
public struct AppInfo: Equatable, Sendable {
    public var name: String
    public var bundleId: String
    public var pid: Int?
    public var running: Bool
    public var lastUsed: Date?
    public var useCount: Int?

    public init(
        name: String,
        bundleId: String,
        pid: Int? = nil,
        running: Bool = false,
        lastUsed: Date? = nil,
        useCount: Int? = nil
    ) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.running = running
        self.lastUsed = lastUsed
        self.useCount = useCount
    }
}

/// A window as seen by the window server (CGWindowList). Geometry is in screen
/// points, top-left origin.
public struct WindowInfo: Equatable, Sendable {
    public var windowId: Int
    public var ownerPid: Int
    public var ownerName: String?
    public var title: String?
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var onscreen: Bool

    public init(
        windowId: Int,
        ownerPid: Int,
        ownerName: String? = nil,
        title: String? = nil,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        onscreen: Bool
    ) {
        self.windowId = windowId
        self.ownerPid = ownerPid
        self.ownerName = ownerName
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.onscreen = onscreen
    }
}

/// Result of an event-driven settle wait (see `SettleMonitor`).
public enum SettleResult: String, Sendable, Equatable {
    case settled      // quiet period elapsed after observed change
    case timeout      // hit the per-tool budget
    case cancelled    // explicitly cancelled (e.g. user interruption)
    case noChange     // nothing observed since the mark
}

/// What outcome we expect after delivering an action, used by `OutcomeMonitor`
/// to distinguish "delivered, no effect" from "not delivered" (Invariants 20-21).
public struct VerificationContract: Sendable {
    public var expectTransientOpen: Bool
    public var expectTransientClose: Bool
    public var allowInvalidation: Bool
    public var allowFocusChange: Bool
    public var allowValueChange: Bool
    /// Optional synchronous read-back check (e.g. value matches, element selected).
    public var directVerifier: (@Sendable () -> Bool)?

    public init(
        expectTransientOpen: Bool = false,
        expectTransientClose: Bool = false,
        allowInvalidation: Bool = true,
        allowFocusChange: Bool = true,
        allowValueChange: Bool = true,
        directVerifier: (@Sendable () -> Bool)? = nil
    ) {
        self.expectTransientOpen = expectTransientOpen
        self.expectTransientClose = expectTransientClose
        self.allowInvalidation = allowInvalidation
        self.allowFocusChange = allowFocusChange
        self.allowValueChange = allowValueChange
        self.directVerifier = directVerifier
    }
}

/// Outcome of post-delivery verification. Mirrors `ActionVerificationResult`.
/// `noEffect` = transport confirmed but state unchanged (Invariant 20).
public enum ActionVerificationResult: String, Sendable, Equatable {
    case confirmed
    case noEffect
    case transientOpened
    case transientClosed
    case stale
    case timeout
}

// MARK: - AppResolver (apps.py)

/// Resolves and launches applications WITHOUT activation (Invariant 14). The
/// only re-activation it permits is restoring the user's previous frontmost app
/// (Invariant 15).
public protocol AppResolver: AnyObject {
    /// Currently running apps, with live pids.
    func listRunningApps() -> [AppInfo]
    /// Apps used in the last ~14 days, with usage metadata (may overlap running).
    func listRecentApps() -> [AppInfo]
    /// Resolve a name/bundle-id hint to a concrete app (running or installed).
    func resolveApp(_ hint: String) throws -> AppInfo
    /// AppInfo for a known live pid, or nil if it is gone.
    func resolveRunningAppByPid(_ pid: Int) -> AppInfo?
    /// Launch with `activates=false` (+ `open -g` fallback). Returns the pid.
    func launchApp(bundleId: String) throws -> Int
    /// Get (or create + cache) the AX application element for a bundle/pid.
    func getAXApp(bundleId: String, knownPid: Int?) throws -> (axApp: AXElementRef, pid: Int)
    /// Get the AX application element for a pid (XPC/helper windows).
    func getAXAppForPid(_ pid: Int, bundleId: String?) throws -> (axApp: AXElementRef, pid: Int)
    /// The user's current frontmost app (pure read — no activation).
    func getFrontmostApp() -> AppInfo?
    /// Restore a previously-captured frontmost app (the ONLY allowed activation).
    func restoreFrontmostApp(_ app: AppInfo?)
    /// Check (and optionally prompt for) Accessibility permission.
    func checkAccessibilityPermission(prompt: Bool) -> Bool
}

// MARK: - AccessibilityProvider (accessibility.py)

/// AX tree walking, element queries and actions. Reads never activate
/// (Invariant 7); writes are pid-scoped, ref-counted assertions (Invariant 11);
/// `-25205`/`-25212` surface as `AutomationError(.staleReference)` (Invariant 10).
public protocol AccessibilityProvider: AnyObject {
    // Tree (reads)
    func walkTree(
        axElement: AXElementRef,
        targetPid: Int?,
        maxDepth: Int,
        maxNodes: Int,
        includeActions: Bool,
        includeStates: Bool
    ) throws -> [Node]
    func getKeyWindow(axApp: AXElementRef) -> AXElementRef?
    func getWindows(axApp: AXElementRef) -> [AXElementRef]
    func getMenuBar(axApp: AXElementRef) -> AXElementRef?
    func getWindowTitle(axWindow: AXElementRef) -> String?

    /// Enable the Chromium/Electron AX tree (A1): set `AXEnhancedUserInterface` +
    /// `AXManualAccessibility` = true on the AXApplication element so it exposes a
    /// tree. Remembered per-app (set at most once), reversible, logged. This is a
    /// sanctioned app-config write — it does NOT focus/raise/activate (Inv 7). The
    /// first walk after enabling is expected empty; the caller re-walks per
    /// `EnhancedUIRewalkPolicy`. Returns true if it applied the write this call,
    /// false if already enabled / not applicable.
    @discardableResult
    func enableEnhancedUI(axApp: AXElementRef, pid: Int) throws -> Bool

    // Element queries (reads)
    /// Direct AX-element → CGWindowID binding via the private
    /// `_AXUIElementGetWindow` SPI (A4). Returns nil when the symbol is absent
    /// (per-symbol-optional) or the element has no window; callers fall back to
    /// bounds/title matching (`WindowMatcher`). Read-only: never raises/focuses.
    func windowIdForElement(_ axRef: AXElementRef) -> Int?
    func getFocusedElement(axApp: AXElementRef, tree: [Node]) -> Int?
    func getElementFrame(node: Node) -> Rect?
    func elementAtPosition(axApp: AXElementRef, x: Double, y: Double) -> AXElementRef?
    func getPid(axElement: AXElementRef) -> Int?
    func refsEqual(_ a: AXElementRef?, _ b: AXElementRef?) -> Bool
    func nodeFromRef(_ element: AXElementRef, depth: Int, index: Int) throws -> Node
    func getActionNamesForRef(_ element: AXElementRef) -> [String]
    func getParentRef(_ element: AXElementRef) -> AXElementRef?
    func getChildren(_ element: AXElementRef) -> [AXElementRef]
    func hasScrollbarRef(_ element: AXElementRef) -> Bool
    func getAttributeValue(_ element: AXElementRef, _ attr: String) -> String?
    func isAttributeSettable(node: Node, _ attr: String) -> Bool

    // Text geometry (A5, US-021): parameterized attributes for "where is this
    // text on screen". On-screen bounds of a character range, the range at a
    // point, and the currently-visible range. Read-only: never focuses/raises.
    func boundsForTextRange(node: Node, range: TextRange) -> Rect?
    func rangeForTextPosition(node: Node, x: Double, y: Double) -> TextRange?
    func visibleTextRange(node: Node) -> TextRange?

    /// Liveness probe (US-038 / Inv 10): copy one cheap attribute (AXRole) on the
    /// node's cached ref and report whether the element is still live. Used to
    /// gate acting on a cached ref — a dead ref forces a re-walk + GraphLocator
    /// rebind rather than acting on (or returning) a stale element. Read-only:
    /// never focuses/raises/activates.
    func isElementAlive(node: Node) -> Bool

    // Writes (pid-scoped, ref-counted assertions)
    func performAction(node: Node, action: String) throws
    func performActionOnRef(_ axRef: AXElementRef, action: String) throws
    func setAttribute(node: Node, _ attr: String, _ value: String) throws

    // Editable text + content extraction
    func makeEditableText(element: AXElementRef, pid: Int?) -> EditableText?
    func extractWebAreaText(_ element: AXElementRef, targetPid: Int?) -> String?
    func extractTextAreaContent(_ element: AXElementRef, targetPid: Int?) -> String?
    func getWebURL(_ element: AXElementRef) -> String?
}

public extension AccessibilityProvider {
    /// Default no-op: providers without a real AX layer (fakes, Linux) simply do
    /// not enable enhanced UI. The real write lives in MacCUAKit.
    @discardableResult
    func enableEnhancedUI(axApp: AXElementRef, pid: Int) throws -> Bool { false }

    /// Default: no private SPI (fakes, Linux). Callers fall back to bounds/title
    /// matching via `WindowMatcher`.
    func windowIdForElement(_ axRef: AXElementRef) -> Int? { nil }

    /// Defaults: no parameterized text geometry (fakes, Linux). The real
    /// parameterized-attribute reads live in MacCUAKit (US-021).
    func boundsForTextRange(node: Node, range: TextRange) -> Rect? { nil }
    func rangeForTextPosition(node: Node, x: Double, y: Double) -> TextRange? { nil }
    func visibleTextRange(node: Node) -> TextRange? { nil }

    /// Default: assume-alive (fakes, Linux). Providers without a real AX layer
    /// cannot probe liveness, so they never force a refetch. The real AXRole
    /// probe lives in MacCUAKit.
    func isElementAlive(node: Node) -> Bool { true }
}

// MARK: - InputProvider (input.py)

/// Synthetic input via `CGEventPostToPid` ONLY (Invariant 1). Never warps the
/// cursor (Invariant 2); modifiers ride as flags on the key event (Invariant 3);
/// per-session private source (Invariant 4); dual scroll deltas (Invariant 6).
/// There is NO foregrounding fallback (Invariant 18) — on failure these throw.
public protocol InputProvider: AnyObject {
    func createEventSource() -> EventSource

    /// Click in screenshot-pixel space (window-relative, top-left origin).
    ///
    /// `prime` (US-057): when true, the impl fires an off-screen Chromium
    /// user-activation primer (a discard down/up pair) through the trusted path
    /// before the real click, so web-content gestures (video play/pause,
    /// `window.open`, fullscreen) are treated as a trusted continuation. Decided
    /// by `ClickPrimerPolicy` at the call site and scoped to web-content pixel
    /// clicks. Off-screen + pid-scoped — never foregrounds (Inv 18). A no-op when
    /// the trusted SkyLight path is unavailable.
    func clickAt(
        pid: Int, windowId: Int, x: Double, y: Double,
        button: String, count: Int,
        screenshotSize: (width: Int, height: Int)?,
        source: EventSource?,
        prime: Bool
    ) throws

    /// Click at an absolute screen point (from an AX frame center).
    func clickAtScreenPoint(
        pid: Int, x: Double, y: Double,
        button: String, count: Int,
        windowId: Int?, source: EventSource?
    ) throws

    func drag(
        pid: Int, windowId: Int,
        fromX: Double, fromY: Double, toX: Double, toY: Double,
        screenshotSize: (width: Int, height: Int)?,
        source: EventSource?
    ) throws

    func pressKey(pid: Int, key: String, source: EventSource?) throws
    func typeText(pid: Int, text: String, source: EventSource?) throws

    func scrollPid(
        pid: Int, x: Double, y: Double,
        direction: String, clicks: Int,
        windowId: Int?, source: EventSource?
    ) throws
    func scrollPidPixel(
        pid: Int, x: Double, y: Double,
        direction: String, pixels: Int,
        windowId: Int?, source: EventSource?
    ) throws

    /// Convert screenshot-pixel coords to absolute screen coords.
    func windowToScreenCoords(
        windowId: Int, x: Double, y: Double,
        screenshotSize: (width: Int, height: Int)?
    ) -> (x: Double, y: Double)?
}

// MARK: - CaptureProvider (screenshot.py + screen_capture.py)

/// Window capture + window-server metadata. Reads a window's backing store by id
/// WITHOUT foregrounding it, cursor excluded (Invariant 13).
public protocol CaptureProvider: AnyObject {
    func listWindows(ownerPid: Int?) -> [WindowInfo]
    func getWindowBounds(windowId: Int) -> Rect?
    func getWindowPid(windowId: Int) -> Int?
    func findWindowIdForAXWindow(pid: Int, axWindow: AXElementRef) -> Int?
    /// Capture a window by id; returns nil on permission/invalid-window failure.
    func captureWindow(windowId: Int, includeCursor: Bool) throws -> CapturedImage?
    func checkScreenRecordingPermission() -> Bool
    func promptScreenRecordingPermission() -> Bool
}

// MARK: - SelectionProvider (selection.py)

/// System text-selection tracking. `format_selection` is pure logic and lives in
/// Core; extraction wraps AX reads.
public protocol SelectionProvider: AnyObject {
    func startObserving(pid: Int)
    func stopObserving()
    /// Current system selection as model-facing formatted text, or nil.
    func currentSelection() -> String?

    // MARK: select_text seam (US-010 wiring; real impl is US-040)

    /// Full text of the selection target — the element's text when `axRef` is
    /// supplied, otherwise the focused field. Feeds the pure `SelectTextResolver`
    /// (US-005) so the spine can turn a content/prefix/suffix request into an
    /// unambiguous range. Throws when there is no selectable target/text.
    func selectableText(axRef: AXElementRef?) throws -> String
    /// Apply a resolved selection (or zero-length caret) range to the target.
    /// Background-only: never raises/focuses/activates the window (Invariant 7).
    func applySelection(axRef: AXElementRef?, range: TextRange) throws
}

// MARK: - ClipboardProvider (clipboard tool, design D2)

/// Background-safe pasteboard access (`NSPasteboard` in the Kit impl, US-041).
/// Read/write/clear without focus or activation — the pasteboard is system-wide,
/// so no app target is required and no window is ever foregrounded.
public protocol ClipboardProvider: AnyObject {
    /// Current plain-text clipboard contents, or nil when empty/non-text.
    func get() throws -> String?
    /// Replace the clipboard with `text`.
    func set(_ text: String) throws
    /// Clear the clipboard.
    func clear() throws
}

// MARK: - OCRProvider (Vision OCR fallback, A2 / US-046)

/// Vision OCR over an already-captured window image. Used ONLY for genuinely
/// tree-less surfaces (canvas/PDF/image windows) — the spine gates this strictly
/// via `OCRFallback.shouldRunOCR`, so a normal AX app never triggers OCR. The Kit
/// impl runs `VNRecognizeTextRequest(.accurate)`. Read-only over an image already
/// in hand — never foregrounds/activates/captures fresh (Invariant 13).
public protocol OCRProvider: AnyObject {
    /// Recognized text runs in captured-image PIXEL space (top-left origin), or
    /// `[]` when nothing is recognized / OCR is unavailable.
    func recognizeText(in image: CapturedImage) -> [OCRObservation]
}

// MARK: - SettleMonitor (observer.py, §5.3 polling design)

/// Event-driven settle by OBSERVATION, not AX notifications (§5.3): poll a cheap
/// tree fingerprint until two consecutive polls match, bounded by the per-tool
/// budget. Replaces the unreliable `AXObserver` correctness path. The Kit impl
/// drives a `DebounceStateMachine` (Observer.swift) in its poll loop — feeding it
/// (now, fingerprint, key-frame rects) ticks so animations keep it waiting.
public protocol SettleMonitor: AnyObject {
    /// Wait until the UI quiesces or the budget elapses.
    func waitForSettle(context: String, timeout: Double, quietPeriod: Double) -> SettleResult
    /// Whether the cached tree should be considered invalidated (liveness-driven).
    var isInvalidated: Bool { get }
    func reset()
    func cancel()
}

// MARK: - OutcomeMonitor (action_verification.py)

/// Post-delivery verification. Distinguishes transport from outcome
/// (Invariant 20); the fresh snapshot remains ground truth (Invariant 21), so
/// these are advisory signals layered on top, never the gate.
public protocol OutcomeMonitor: AnyObject {
    /// Mark the pre-action state; returns an opaque sequence marker.
    func mark() -> Int
    /// Verify an AX-action outcome against a contract.
    func verifyAX(contract: VerificationContract, mark: Int?, timeout: Double) -> ActionVerificationResult
    /// Verify CGEvent transport (tap echo match, Invariant 4).
    func verifyTransport(startSequence: Int, timeout: Double) -> Bool
}

// MARK: - Focus / interruption services (focus.py)

/// User-interruption monitor (CGEventTap, listen-only — Invariant 5). When the
/// user touches the driven app, the agent yields (Invariant 16).
public protocol UserInteractionMonitoring: AnyObject {
    func startMonitoring(pid: Int)
    func stopMonitoring()
    /// Returns a one-shot warning message if the user interacted, else nil.
    func checkInterruption(bundleId: String) -> String?
}

/// Menu-open state (used to shorten settle while a menu/popover is open).
public protocol MenuTracking: AnyObject {
    var menusOpen: Bool { get }
    func start(pid: Int)
    func stop()
}

/// Frontmost-app tracking (NSWorkspace notifications). Observe-and-log only
/// (Invariant 15).
public protocol FrontmostTracking: AnyObject {
    func start()
    func stop()
    func currentFrontmost() -> AppInfo?
}

/// Window z-order tracking (US-045). Polls `CGWindowListCopyWindowInfo` (no
/// AXObserver — polling is the correctness gate, §5.3). Observe-and-report only —
/// detecting a z-order change NEVER reorders/raises/foregrounds any window
/// (Invariant 7/15). The Kit impl drives the pure `WindowOrderingState`
/// (WindowOrdering.swift) in its poll loop.
public protocol WindowOrderingTracking: AnyObject {
    func start()
    func stop()
    /// Current best-known on-screen window order (CGWindowNumbers, front-to-back).
    var currentOrder: [Int] { get }
    /// Invoked once per detected z-order change with the new order. Set before
    /// `start()`.
    var onChange: (([Int]) -> Void)? { get set }
}

/// Lock-screen state probe (US-047 safety guard). The Kit impl reads
/// `CGSessionCopyCurrentDictionary()` -> `CGSSessionScreenIsLocked == 1`.
/// Read-only — never foregrounds/activates. Returns false when the state can't
/// be determined (fail-open on the *probe*, the input blocklist still applies).
public protocol ScreenLockProvider: AnyObject {
    func isScreenLocked() -> Bool
}
