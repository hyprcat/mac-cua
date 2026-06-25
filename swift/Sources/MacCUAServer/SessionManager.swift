import Foundation
import MacCUACore

// Port of `SessionManager` from `app/session.py` — the integration spine. The
// orchestration is pure; every effect goes through a `Providers` seam, so this
// whole type builds and unit-tests on Linux (Phase 2).
//
// Concurrency: Python got serialization for free (sequential tool calls + GIL).
// Here `SessionManager` is a `final class` and the MCP server layer owns the
// single-threaded dispatch / timeout boundary (it can wrap this in an actor or a
// serial executor — SWIFT_PORT_DESIGN.md §5.4). Confining all `_sessions`
// mutation to that boundary preserves the invariant without threading `async`
// through the entire 3.8k-LOC spine.

// MARK: - Tunables (mirror the module constants in session.py)

enum SpineConst {
    static let windowRetryDelayS = 0.15
    static let screenshotRetryDelayS = 0.1
    static let scrollClicksPerPage = 6
    static let scrollPixelsPerPageRatio = 0.6
    static let scrollPixelsMin = 160
    static let geometryHintLimit = 160
    /// Below this many actionable elements the tree is "AX-poor" → coordinate mode.
    static let axPoorThreshold = 5
}

let axPoorGuidance = """
This app has limited accessibility support — the element tree is sparse or empty. \
Prefer coordinate-based interactions (click with x/y from the screenshot) over element indices. \
press_key and type_text still work normally.
"""

/// Per-tool settle budgets (mirror `observer.SETTLE_TIMEOUTS`). Defaulted to 1.0s.
let settleTimeouts: [String: Double] = [
    "click": 1.0,
    "type_text": 1.0,
    "set_value": 0.6,
    "press_key": 1.0,
    "drag": 1.0,
    "scroll": 0.3,
    "perform_secondary_action": 1.0,
    "get_app_state": 0.0,
]
let settleQuietPeriod = 0.15

// Key → AX action map for element-targeted key presses (background-safe).
let keyToAXAction: [String: String] = [
    "return": "AXConfirm",
    "enter": "AXConfirm",
    "escape": "AXCancel",
]

let webContainerRoles: Set<String> = ["web area"]
let pointerPreferredRoles: Set<String> = [
    "button", "check box", "combo box", "link", "menu item", "pop up button",
    "radio button", "row", "slider", "tab", "text area", "text field",
]
let scrollableDisplayRoles: Set<String> = ["list", "outline", "scroll area", "table", "web area"]
let directionalScrollActions: Set<String> = [
    "AXScrollUpByPage", "AXScrollDownByPage", "AXScrollLeftByPage", "AXScrollRightByPage",
]
let axActivationActions: Set<String> = ["AXConfirm", "AXPick", "AXPress"]
let strictSecondaryActions: Set<String> = [
    "AXScrollToVisible", "AXShowAlternateUI", "AXShowDefaultUI", "AXShowMenu",
]
let buttonishAXRoles: Set<String> = [
    "AXButton", "AXCheckBox", "AXMenuButton", "AXPopUpButton", "AXRadioButton", "AXTab",
]
let selectionContainerRoles: Set<String> = ["collection", "list", "outline", "table"]
let geometryHintRoles: Set<String> = pointerPreferredRoles.union(scrollableDisplayRoles)
let textGroundingRoles: Set<String> = ["text", "heading", "image", "menu item"]

// MARK: - SessionManager

public final class SessionManager {
    // Dependency seams.
    let providers: Providers
    let flags: FeatureFlags
    let workarounds: WorkaroundFlags
    let safety: SafetyBlocklist
    let approvalStore: AppApprovalStore
    let lifecycle: SessionLifecycle

    // Owned mutable state (confined to the MCP dispatch boundary).
    var sessions: [Int: AppSession] = [:]          // window_id → session
    var bundleToWindow: [String: Int] = [:]        // bundle_id → window_id
    var guidanceCache: [String: String?] = [:]
    var trackersStarted = false

    // Decorative ghost-cursor registry (§7, multi-cursor identity). One per
    // SessionManager, keyed by windowId: assigns a distinct tint per driven
    // window and is the sink for `BackgroundCursor` logical-move chokepoints.
    // The macOS executable wires the AppKit overlay + window tracker into this
    // controller (`ghostController.overlay` / `onStartTracking`); on Linux it
    // stays a pure no-render registry (Linux-green).
    public let ghostController = GhostCursorController()

    public init(
        providers: Providers,
        flags: FeatureFlags = FeatureFlags.load(),
        workarounds: WorkaroundFlags = WorkaroundFlags.load()
    ) {
        self.providers = providers
        self.flags = flags
        self.workarounds = workarounds
        self.safety = SafetyBlocklist(
            allowForbidden: flags.allowForbiddenTargets,
            ownBundleId: Bundle.main.bundleIdentifier)
        self.approvalStore = AppApprovalStore()
        self.lifecycle = SessionLifecycle()
    }
}
