import Foundation
import MacCUACore

// Port of the `AppTarget` / `AppSession` dataclasses from `app/session.py`, plus
// the `Providers` dependency container that injects every macOS seam. In Python
// these were free-floating module globals (`apps`, `accessibility`, `input`, …);
// here they are gathered into one injectable bundle so the spine builds on Linux
// against fakes (SWIFT_PORT_DESIGN.md §4.2).

/// The resolved target of a session: an app, a concrete window, and the live AX
/// handles. `axApp`/`axWindow` are read handles only — never raised or focused
/// (Invariant 7). Dual pids (`pid` vs `windowPid`) survive XPC/helper-rendered
/// windows (§10 risk: `_background_pid_for_node`).
public final class AppTarget {
    public var bundleId: String
    public var pid: Int
    public var windowId: Int
    public var windowPid: Int
    public var axApp: AXElementRef
    public var axWindow: AXElementRef

    public init(
        bundleId: String,
        pid: Int,
        windowId: Int,
        windowPid: Int,
        axApp: AXElementRef,
        axWindow: AXElementRef
    ) {
        self.bundleId = bundleId
        self.pid = pid
        self.windowId = windowId
        self.windowPid = windowPid
        self.axApp = axApp
        self.axWindow = axWindow
    }
}

/// Per-session state carried across tool calls. Mirrors `AppSession` in
/// `app/session.py:220`. Held as a `final class` (mutated in place) and confined
/// to the `SessionManager` actor.
public final class AppSession {
    public var target: AppTarget
    public var snapshotId: Int = 0
    public var treeNodes: [Node] = []
    public var graphs: SessionGraphs
    public var guidance: String?
    public var screenshotSize: (width: Int, height: Int)?

    // Settle / invalidation (polling-based — §5.3).
    public var settleMonitor: SettleMonitor?
    public var refetchableTree: RefetchableTree?
    public var guidanceDelivered: Bool = false
    /// Whether Chromium/Electron enhanced UI was primed for this session (A1).
    public var enhancedUIPrimed: Bool = false

    // Input strategy + delivery.
    public var inputStrategy: InputStrategy?
    public var appType: AppType = .nativeCocoa
    public var cursor: BackgroundCursor?
    public var eventSource: EventSource?

    // Verification.
    public var axOutcomeMonitor: OutcomeMonitor?
    public var cgeventOutcomeMonitor: OutcomeMonitor?
    public var lastActionVerification: ActionVerificationResult?
    public var lastDeliveryVerdict: DeliveryVerdict?

    // Transient surfaces (menus / popovers / sheets).
    public var menuTracker: MenuTracking?
    public var pendingTransientSource: TransientSource?

    // Selection.
    public var selectionClient: SelectionProvider?

    // Scroll: cached working method per session ("ax", "pid", "pixel", "system").
    public var scrollMethod: String?

    // Yield state after user interaction (Invariant 16).
    public var userStateInvalidated: Bool = false
    public var userStateInvalidatedMessage: String?

    // Graph registry for this session's tree-graph bookkeeping. In Python this
    // is a single SessionManager-global registry, but it only carries a counter
    // + ref-equality seam while the graph *records* are already per-session
    // (`graphs`); confining it to the session is faithful and keeps the spine an
    // extension (Swift extensions cannot add stored properties to the manager).
    // [SPINE ADDITION]
    public var graphRegistry: GraphRegistry = GraphRegistry()

    // Window availability. The foundation's `AppTarget.axWindow` is non-optional,
    // but the Python spine modeled "window gone" as `ax_window is None`. We carry
    // that signal here instead: `refreshWindow` sets it false when the window's
    // pid is gone or no AX window can be re-bound (then sets axWindow = axApp as a
    // best-effort read root, never raising — Invariant 7). [SPINE ADDITION]
    public var windowAvailable: Bool = true

    public init(target: AppTarget, graphs: SessionGraphs = SessionGraphs()) {
        self.target = target
        self.graphs = graphs
    }
}

/// Everything `SessionManager` needs from the outside world. Real builds inject
/// the `MacCUAKit` implementations; tests inject fakes. Per-session monitors are
/// created through the factory closures so the spine never names a concrete type.
public final class Providers {
    public let apps: AppResolver
    public let accessibility: AccessibilityProvider
    public let input: InputProvider
    public let capture: CaptureProvider
    public let analytics: Analytics
    /// System pasteboard (clipboard tool, US-010 wiring / US-041 real impl).
    public let clipboard: ClipboardProvider
    /// Vision OCR fallback for tree-less surfaces (A2, US-046). Optional: nil
    /// providers (fakes/Linux without an OCR fake) simply never run OCR.
    public let ocr: OCRProvider?

    // Global trackers (shared across sessions).
    public let frontmostTracker: FrontmostTracking
    public let userInteractionMonitor: UserInteractionMonitoring
    /// Lock-screen probe for the input safety guard (US-047). Optional: nil
    /// providers (fakes/Linux) are treated as "never locked".
    public let screenLock: ScreenLockProvider?

    // Per-session factories.
    public let makeSettleMonitor: (AppSession) -> SettleMonitor
    public let makeAXOutcomeMonitor: (AppSession) -> OutcomeMonitor
    public let makeCGEventOutcomeMonitor: (AppSession) -> OutcomeMonitor
    public let makeMenuTracker: (AppSession) -> MenuTracking
    public let makeSelectionClient: (AppSession) -> SelectionProvider
    public let makeEditableText: (AXElementRef, Int?) -> EditableText?

    public init(
        apps: AppResolver,
        accessibility: AccessibilityProvider,
        input: InputProvider,
        capture: CaptureProvider,
        analytics: Analytics = NoopAnalytics(),
        clipboard: ClipboardProvider,
        ocr: OCRProvider? = nil,
        frontmostTracker: FrontmostTracking,
        userInteractionMonitor: UserInteractionMonitoring,
        screenLock: ScreenLockProvider? = nil,
        makeSettleMonitor: @escaping (AppSession) -> SettleMonitor,
        makeAXOutcomeMonitor: @escaping (AppSession) -> OutcomeMonitor,
        makeCGEventOutcomeMonitor: @escaping (AppSession) -> OutcomeMonitor,
        makeMenuTracker: @escaping (AppSession) -> MenuTracking,
        makeSelectionClient: @escaping (AppSession) -> SelectionProvider,
        makeEditableText: @escaping (AXElementRef, Int?) -> EditableText?
    ) {
        self.apps = apps
        self.accessibility = accessibility
        self.input = input
        self.capture = capture
        self.analytics = analytics
        self.clipboard = clipboard
        self.ocr = ocr
        self.frontmostTracker = frontmostTracker
        self.userInteractionMonitor = userInteractionMonitor
        self.screenLock = screenLock
        self.makeSettleMonitor = makeSettleMonitor
        self.makeAXOutcomeMonitor = makeAXOutcomeMonitor
        self.makeCGEventOutcomeMonitor = makeCGEventOutcomeMonitor
        self.makeMenuTracker = makeMenuTracker
        self.makeSelectionClient = makeSelectionClient
        self.makeEditableText = makeEditableText
    }
}
