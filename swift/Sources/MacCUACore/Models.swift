import Foundation

// Port of app/response.py — the pure value types that flow through the whole
// pipeline. Geometry and response types are value `struct`s; `Node` is a
// `final class` to faithfully mirror Python's reference semantics (pruning,
// graph binding and reindexing all mutate live nodes in place).

public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Size: Equatable, Sendable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

/// Marker for an opaque platform accessibility-element handle (real
/// `AXUIElement` wrapper in MacCUAKit; a fake in tests). Kept off the
/// model-facing surface — `axRef` never serializes (Invariant 8).
public protocol AXElementRef: AnyObject {}

/// A single accessibility element in the flat pre-order tree.
///
/// Mirrors `app/response.py:Node`. Fields after `depth` are optional metadata;
/// the `graph*` and `axRef` fields are internal-only and must never reach the
/// model (Invariant 8).
public final class Node {
    public var index: Int
    public var role: String
    public var label: String?
    public var states: [String]
    public var description: String?
    public var value: String?
    public var axId: String?
    public var secondaryActions: [String]
    public var depth: Int
    public var placeholder: String?
    public var helpText: String?
    public var valueDescription: String?
    // Numeric value bounds (sliders/steppers) + current selection text (A3).
    public var minValue: String?
    public var maxValue: String?
    public var selectedText: String?
    public var positionInSet: Int?
    public var position: Point?
    public var size: Size?
    /// Opaque AX handle — never serialized (repr=False in Python).
    public var axRef: AXElementRef?
    // DisplayElement fields
    public var lmRole: String?
    public var lmDescription: String?
    // Web content flags
    public var isWebArea: Bool
    public var isOop: Bool
    // Original AX role for pruning decisions
    public var axRole: String?
    public var subrole: String?
    // PID of the element's process (for OOP detection)
    public var elementPid: Int?
    // Rich text / web content
    public var webContent: String?
    public var webAreaUrl: String?
    public var url: String?
    // Internal graph metadata for stale-node recovery. Never serialized into
    // model-facing tree text.
    public var graphId: String?
    public var graphGeneration: Int
    public var graphLocator: GraphLocator?

    public init(
        index: Int,
        role: String,
        label: String? = nil,
        states: [String] = [],
        description: String? = nil,
        value: String? = nil,
        axId: String? = nil,
        secondaryActions: [String] = [],
        depth: Int,
        placeholder: String? = nil,
        helpText: String? = nil,
        valueDescription: String? = nil,
        minValue: String? = nil,
        maxValue: String? = nil,
        selectedText: String? = nil,
        positionInSet: Int? = nil,
        position: Point? = nil,
        size: Size? = nil,
        axRef: AXElementRef? = nil,
        lmRole: String? = nil,
        lmDescription: String? = nil,
        isWebArea: Bool = false,
        isOop: Bool = false,
        axRole: String? = nil,
        subrole: String? = nil,
        elementPid: Int? = nil,
        webContent: String? = nil,
        webAreaUrl: String? = nil,
        url: String? = nil,
        graphId: String? = nil,
        graphGeneration: Int = 0,
        graphLocator: GraphLocator? = nil
    ) {
        self.index = index
        self.role = role
        self.label = label
        self.states = states
        self.description = description
        self.value = value
        self.axId = axId
        self.secondaryActions = secondaryActions
        self.depth = depth
        self.placeholder = placeholder
        self.helpText = helpText
        self.valueDescription = valueDescription
        self.minValue = minValue
        self.maxValue = maxValue
        self.selectedText = selectedText
        self.positionInSet = positionInSet
        self.position = position
        self.size = size
        self.axRef = axRef
        self.lmRole = lmRole
        self.lmDescription = lmDescription
        self.isWebArea = isWebArea
        self.isOop = isOop
        self.axRole = axRole
        self.subrole = subrole
        self.elementPid = elementPid
        self.webContent = webContent
        self.webAreaUrl = webAreaUrl
        self.url = url
        self.graphId = graphId
        self.graphGeneration = graphGeneration
        self.graphLocator = graphLocator
    }
}

// `GraphLocator` is defined in TreeGraph.swift (the real stale-node-recovery
// locator). The placeholder that previously lived here has been removed.

/// Geometry and state metadata for the target application.
public struct AppState: Equatable, Sendable {
    public var bundleId: String
    public var isActive: Bool
    public var isRunning: Bool
    public var windowTitle: String?
    public var visibleRect: Rect?
    public var scalingFactor: Double
    public var scaledScreenSize: Size?
    public var cursorPosition: Point?

    public init(
        bundleId: String,
        isActive: Bool,
        isRunning: Bool,
        windowTitle: String?,
        visibleRect: Rect? = nil,
        scalingFactor: Double = 2.0,
        scaledScreenSize: Size? = nil,
        cursorPosition: Point? = nil
    ) {
        self.bundleId = bundleId
        self.isActive = isActive
        self.isRunning = isRunning
        self.windowTitle = windowTitle
        self.visibleRect = visibleRect
        self.scalingFactor = scalingFactor
        self.scaledScreenSize = scaledScreenSize
        self.cursorPosition = cursorPosition
    }
}

// MARK: - Action-feedback packet (F)

/// How a synthetic action was actually delivered to the target. After every
/// action the model is told the path so it can reason about why an action did
/// or did not land (e.g. an Electron control that only responds to a pointer
/// path). All paths are background-only; none foregrounds (Prime Invariant).
public enum DeliveryPath: String, Sendable, Equatable {
    /// AX action (`AXPress`/`AXConfirm`/…) on the element.
    case axPress = "AXPress"
    /// SkyLight per-PID targeted delivery (`SLEventPostToPid`).
    case skyLight = "SkyLight"
    /// `CGEvent.postToPid` background delivery.
    case cgEvent = "CGEvent"
    /// `CGEventPostToPSN` to the owning process serial number.
    case psn = "PSN"
    /// Scroll-wheel delivery (CGEvent scroll-wheel).
    case wheel = "wheel"

    /// Derive the delivery path from a handler's success message (F / US-039).
    /// The handlers encode the path they actually used in their result string
    /// (e.g. "(CGEventPostToPid)", "(AXPress)", "Scrolled …", "Dragged …"); this
    /// pure classifier maps that to a `DeliveryPath` for the feedback packet. AX
    /// markers map to `.axPress`; per-pid pointer/key delivery to `.cgEvent`;
    /// scrolls to `.wheel`. CGEvent markers are checked before AX so a
    /// "(CGEventPostToPid, refreshed window)" message is never misread as AX.
    public static func classify(message: String) -> DeliveryPath {
        if message.contains("CGEventPostToPid")
            || message.contains("background key")
            || message.contains("Dragged") {
            return .cgEvent
        }
        if message.contains("Scrolled") {
            return .wheel
        }
        if message.contains("AX") || message.contains("EditableTextObject") {
            return .axPress
        }
        return .cgEvent
    }
}

/// Per-action feedback returned to the model after every action (F). Carries the
/// delivery path, the target window identity, the *logical* cursor position
/// before/after (the BackgroundCursor's logical coordinate — the OS cursor never
/// moves), and the tree-wide change summary (E3 / US-003) so the model can
/// self-correct instead of flying blind. Real population is Phase 4 (US-039);
/// this is the pure shape + its renderer.
public struct ActionFeedback: Sendable, Equatable {
    public var deliveryPath: DeliveryPath
    public var windowId: Int?
    public var windowTitle: String?
    /// Logical cursor position before the action (logical, not OS cursor).
    public var cursorBefore: Point?
    /// Logical cursor position after the action.
    public var cursorAfter: Point?
    /// Tree-wide pre/post change summary (US-003); `nil` when not computed.
    public var changeSummary: ChangeSummary?

    public init(
        deliveryPath: DeliveryPath,
        windowId: Int? = nil,
        windowTitle: String? = nil,
        cursorBefore: Point? = nil,
        cursorAfter: Point? = nil,
        changeSummary: ChangeSummary? = nil
    ) {
        self.deliveryPath = deliveryPath
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.cursorBefore = cursorBefore
        self.cursorAfter = cursorAfter
        self.changeSummary = changeSummary
    }
}

/// The full result of a tool call, assembled into MCP content downstream.
public struct ToolResponse {
    public var app: String
    public var pid: Int
    public var snapshotId: Int
    public var windowTitle: String?
    public var treeText: String?
    public var treeNodes: [Node]
    public var focusedElement: Int?
    public var screenshot: String?
    public var result: String?
    public var error: String?
    public var guidance: String?
    public var appState: AppState?
    public var systemSelection: String?
    /// Per-action feedback (F / US-011). Present on action responses; `nil` for
    /// read-only tools (`list_apps`, `get_app_state`, `wait`).
    public var actionFeedback: ActionFeedback?

    public init(
        app: String,
        pid: Int,
        snapshotId: Int,
        windowTitle: String? = nil,
        treeText: String? = nil,
        treeNodes: [Node] = [],
        focusedElement: Int? = nil,
        screenshot: String? = nil,
        result: String? = nil,
        error: String? = nil,
        guidance: String? = nil,
        appState: AppState? = nil,
        systemSelection: String? = nil,
        actionFeedback: ActionFeedback? = nil
    ) {
        self.app = app
        self.pid = pid
        self.snapshotId = snapshotId
        self.windowTitle = windowTitle
        self.treeText = treeText
        self.treeNodes = treeNodes
        self.focusedElement = focusedElement
        self.screenshot = screenshot
        self.result = result
        self.error = error
        self.guidance = guidance
        self.appState = appState
        self.systemSelection = systemSelection
        self.actionFeedback = actionFeedback
    }
}

public enum Version {
    nonisolated(unsafe) private static var cached: String?

    /// Short version hash for the server. Mirrors `compute_version_hash`.
    public static func computeVersionHash(packageVersion: String = "0.1.0") -> String {
        if let cached { return cached }
        let hash = SHA256Lite.hexDigest(packageVersion)
        let short = String(hash.prefix(8))
        cached = short
        return short
    }

    /// Prepended to every tool response. Mirrors `format_response_header`.
    public static func formatResponseHeader() -> String {
        "Desktop Automation state (version: \(computeVersionHash()))"
    }
}
