import Foundation

// Port of `app/_lib/tree.py` — AX tree → indexed text serialization.
//
// PURE logic, no macOS deps. Serializes a flat `[Node]` list into the
// model-facing tree text (indentation by depth, role/label/value/state
// formatting, index references).
//
// Invariant 8: AX refs and graph metadata never serialize. `Node.axRef`,
// `graphId`, `graphGeneration` and `graphLocator` are never read here, and any
// leaked `<AXUIElement 0x… {pid=…}>` pointer string is scrubbed from the output
// exactly as the Python does.

// MARK: - Constants

/// Matches raw AXUIElement pointer strings like `(<AXUIElement 0x600003abc123 {pid=29221}>)`.
/// These leak through from pyobjc `str()` on AX element references and are
/// useless to the LLM. Mirrors `_AX_ELEMENT_RE` in Python.
private let axElementPattern =
    #"\s*\(?<AXUIElement\s+0x[0-9a-fA-F]+\s*\{pid=\d+\}>\)?"#

private let axElementRegex: NSRegularExpression = {
    // The Python pattern is valid; force-unwrap is safe and mirrors module-load
    // compilation in Python.
    return try! NSRegularExpression(pattern: axElementPattern)
}()

private let valuelessRoles: Set<String> = [
    "collection",
    "group",
    "outline",
    "radiogroup",
    "scroll area",
    "section",
    "split group",
    "toolbar",
    "window",
    "standard window",
]

private let actionDisplayNames: [String: String] = [
    "AXRaise": "Raise",
    "AXCollapse": "Collapse",
    "AXMoveNext": "Move next",
    "AXMovePrevious": "Move previous",
    "AXRemoveFromToolbar": "Remove from toolbar",
    "AXScrollUpByPage": "Scroll Up",
    "AXScrollDownByPage": "Scroll Down",
    "AXScrollLeftByPage": "Scroll Left",
    "AXScrollRightByPage": "Scroll Right",
    "AXScrollToVisible": "Scroll To Visible",
    "AXScrollToShowDescendant": "Scroll To Show Descendant",
    "AXOpen": "Open",
    "AXPick": "Pick",
    "AXIncrement": "Increment",
    "AXDecrement": "Decrement",
    "AXZoomWindow": "zoom the window",
]

// NOTE: `_VALUE_ROLES` and `_RICH_TEXT_ROLES` exist in the Python module but are
// not referenced by any serialization code path there; they are intentionally
// omitted from this faithful port of the live behavior.

// MARK: - Pruning seam

// `PruneResult` is defined in Pruning.swift (the canonical pruning pipeline).
// This module consumes it via the `PruneFunction` seam below.

/// Dependency seam for the pruning pipeline. The integrator injects the real
/// `Pruning.prune` here. `maxDepth` / `collapseThreshold` are passed through
/// when non-nil (mirroring the Python kwargs-only-when-set behavior).
public typealias PruneFunction = (
    _ nodes: [Node],
    _ maxDepth: Int?,
    _ collapseThreshold: Int?
) -> PruneResult

// MARK: - Node formatting

private func displayRole(_ node: Node, codexStyle: Bool) -> String {
    if codexStyle && node.role == "web area" {
        return "HTML content"
    }
    if codexStyle && node.role == "checkbox" && node.subrole == "AXToggleButton" {
        return "toggle button"
    }
    if codexStyle && node.role == "radio button" && node.subrole == "AXTabButton" {
        return "tab"
    }
    if codexStyle && node.role == "popup button" {
        return "pop-up button"
    }
    if codexStyle,
       let axId = node.axId,
       ["group", "radiogroup", "unknown"].contains(node.role),
       axId.hasPrefix("UIA.") {
        return axId
    }
    return node.role
}

private func displayActions(_ actions: [String]) -> [String] {
    actions.map { action in
        if let mapped = actionDisplayNames[action] {
            return mapped
        }
        if action.hasPrefix("AX") {
            return String(action.dropFirst(2))
        }
        return action
    }
}

private func shouldInlineValue(_ node: Node) -> Bool {
    guard node.value != nil else { return false }
    if node.label != nil && node.value == node.label { return false }
    if valuelessRoles.contains(node.role) { return false }
    return true
}

/// Repeat a string `count` times (Python's `s * n`, with `n <= 0` → "").
private func repeated(_ unit: String, _ count: Int) -> String {
    guard count > 0 else { return "" }
    return String(repeating: unit, count: count)
}

/// Round-half-away-from-zero to mirror Python's `round()` on the frame values
/// used here. (Python's banker's rounding only differs at exact .5; AX
/// geometry rarely lands there, and the Python wraps each value in `int(round())`.)
private func pyRoundToInt(_ value: Double) -> Int {
    Int(value.rounded(.toNearestOrAwayFromZero))
}

/// Format a single node into its text representation. Mirrors `_format_node`.
private func formatNode(_ node: Node, indent: Bool = true, codexStyle: Bool = false) -> String {
    var parts: [String] = []
    var displayLabel = node.label
    var description = node.description
    let value = node.value

    if codexStyle && node.role == "row"
        && displayLabel == nil && description != nil && value == nil {
        displayLabel = description
        description = nil
    }

    if indent {
        parts.append(repeated(codexStyle ? "\t" : "  ", node.depth))
    }

    if codexStyle && node.role == "menu bar item", let label = node.label, !label.isEmpty {
        parts.append(String(node.index))
        parts.append(" ")
        parts.append(label)
        return parts.joined()
    }

    if codexStyle {
        parts.append(String(node.index))
        parts.append(" ")
        parts.append(displayRole(node, codexStyle: true))
    } else {
        parts.append("[\(node.index)] ")
        parts.append((node.lmRole?.isEmpty == false) ? node.lmRole! : node.role)
    }

    if !node.states.isEmpty {
        parts.append(" (\(node.states.joined(separator: ", ")))")
    }

    if let displayLabel {
        parts.append(" \(displayLabel)")
    }

    var extras: [String] = []
    if let description, description != displayLabel {
        extras.append("Description: \(description)")
    }

    if let value, shouldInlineValue(node) {
        // When the label was synthesized from the value, skip the redundant
        // "Value:" extra (mirrors the `pass` branch in Python).
        if node.label == nil, let displayLabel, value == displayLabel {
            // skip
        } else {
            extras.append("Value: \(value)")
        }
    }

    if let placeholder = node.placeholder, !placeholder.isEmpty {
        extras.append("Placeholder: \(placeholder)")
    }

    if let helpText = node.helpText, !helpText.isEmpty {
        extras.append("Help: \(helpText)")
    }

    if let valueDescription = node.valueDescription, !valueDescription.isEmpty {
        extras.append("Details: \(valueDescription)")
    }

    if let axId = node.axId {
        let dispRole = displayRole(node, codexStyle: codexStyle)
        let suppress = codexStyle
            && (node.role == "menu bar"
                || (axId.hasPrefix("UIA.") && dispRole == axId))
        if !suppress {
            extras.append("ID: \(axId)")
        }
    }

    if !codexStyle, let position = node.position, let size = node.size {
        let x = pyRoundToInt(position.x)
        let y = pyRoundToInt(position.y)
        let w = max(1, pyRoundToInt(size.w))
        let h = max(1, pyRoundToInt(size.h))
        extras.append(" Frame: (\(x),\(y) \(w)x\(h))")
    }

    if !node.secondaryActions.isEmpty {
        let actions = displayActions(node.secondaryActions)
        if codexStyle {
            extras.append("Secondary Actions: \(actions.joined(separator: ", "))")
        } else {
            extras.append("Actions: [\(actions.joined(separator: ", "))]")
        }
    }

    if let webAreaUrl = node.webAreaUrl, !webAreaUrl.isEmpty {
        extras.append("URL: \(webAreaUrl)")
    }

    if !extras.isEmpty {
        parts.append(displayLabel != nil ? ", " : " ")
        parts.append(lstripped(extras[0]))
        for extra in extras.dropFirst() {
            parts.append(", \(extra)")
        }
    }

    let result = parts.joined()
    // Strip leaked AXUIElement pointer strings — useless to the LLM (Invariant 8).
    return scrubAXElementStrings(result)
}

/// Mirror Python `str.lstrip()` (strip leading whitespace).
private func lstripped(_ s: String) -> String {
    var idx = s.startIndex
    while idx < s.endIndex, s[idx].isWhitespace {
        idx = s.index(after: idx)
    }
    return String(s[idx...])
}

/// Remove any leaked `<AXUIElement 0x… {pid=…}>` pointer strings (Invariant 8).
private func scrubAXElementStrings(_ s: String) -> String {
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return axElementRegex.stringByReplacingMatches(
        in: s, range: range, withTemplate: "")
}

/// Mirror `_format_focus_summary`.
private func formatFocusSummary(_ node: Node, codexStyle: Bool = false) -> String {
    if !codexStyle {
        return formatNode(node, indent: false, codexStyle: false)
    }

    if node.role == "menu bar item", let label = node.label, !label.isEmpty {
        return "\(node.index) \(label)"
    }

    var parts: [String] = [String(node.index), " ", displayRole(node, codexStyle: true)]
    if !node.states.isEmpty {
        parts.append(" (\(node.states.joined(separator: ", ")))")
    }
    if let label = node.label, !["standard window", "window"].contains(node.role) {
        parts.append(" \(label)")
    }
    return parts.joined()
}

// MARK: - Web content inlining

/// Mirror `_has_visible_children`: true when the node at `position` has
/// serialized descendants in the flat list.
private func hasVisibleChildren(_ nodes: [Node], _ position: Int) -> Bool {
    let node = nodes[position]
    for candidate in nodes[(position + 1)...] {
        if candidate.depth <= node.depth {
            return false
        }
        return true
    }
    return false
}

/// Mirror `_should_inline_web_content`.
private func shouldInlineWebContent(
    _ node: Node,
    _ nodes: [Node],
    _ position: Int,
    codexStyle: Bool
) -> Bool {
    guard let webContent = node.webContent, !webContent.isEmpty else { return false }
    if !codexStyle { return true }
    if ["HTML content", "web area", "text area", "text field"].contains(node.role) {
        return !hasVisibleChildren(nodes, position)
    }
    return true
}

// MARK: - Public API

/// Serialize a list of `Node` objects into indented indexed text.
///
/// Mirrors `app/_lib/tree.py:serialize`.
///
/// - Parameters:
///   - nodes: Flat list of nodes with depth information for indentation.
///   - focusedIndex: Index of the currently focused UI element, or nil.
///   - enablePruning: Run the full pruning pipeline. Requires `prune` to be
///     supplied; if nil while pruning is requested, nodes pass through unpruned.
///   - maxDepth: Override the default max depth for pruning.
///   - collapseThreshold: Override the default SubtreeCollapse threshold.
///   - codexStyle: Use the tab-indented, plain-index codex tree format.
///   - prune: The pruning pipeline (dependency seam — the Pruning module
///     supplies the real implementation).
/// - Returns: The full text block ready to send to the model.
public func serialize(
    _ nodes: [Node],
    focusedIndex: Int? = nil,
    enablePruning: Bool = true,
    maxDepth: Int? = nil,
    collapseThreshold: Int? = nil,
    codexStyle: Bool = false,
    prune: PruneFunction? = nil
) -> String {
    var nodes = nodes
    var collapseInfo: [Int: Int] = [:]
    var depthCollapsedParents: Set<Int> = []

    if enablePruning, !nodes.isEmpty, let prune {
        let result = prune(nodes, maxDepth, collapseThreshold)
        nodes = result.nodes
        collapseInfo = result.collapseInfo
        depthCollapsedParents = result.depthCollapsedParents
    }

    var lines: [String] = []
    for position in nodes.indices {
        let node = nodes[position]
        lines.append(formatNode(node, codexStyle: codexStyle))

        // Web/rich text content inline.
        if shouldInlineWebContent(node, nodes, position, codexStyle: codexStyle),
           let webContent = node.webContent {
            let contentIndent = repeated(codexStyle ? "\t" : "  ", node.depth + 1)
            for contentLine in webContent.components(separatedBy: "\n") {
                lines.append("\(contentIndent)\(contentLine)")
            }
        }

        // SubtreeCollapse: if this node has collapsed children, add summary.
        if let total = collapseInfo[node.index] {
            // The first 5 children are already in the list; total is original count.
            let hidden = max(0, total - 5)
            if hidden > 0 {
                let indent = repeated(codexStyle ? "\t" : "  ", node.depth + 1)
                lines.append("\(indent)... (\(hidden) more items hidden)")
            }
        }

        // Depth collapse: children exceeded max depth threshold.
        if depthCollapsedParents.contains(node.index) {
            let indent = repeated(codexStyle ? "\t" : "  ", node.depth + 1)
            lines.append("\(indent)<summary>(collapsed content is hidden)</summary>")
        }
    }

    if let focusedIndex, focusedIndex >= 0, focusedIndex < nodes.count {
        let focused = nodes[focusedIndex]
        let summary = formatFocusSummary(focused, codexStyle: codexStyle)
        lines.append("")
        lines.append("The focused UI element is \(summary).")
    }

    return lines.joined(separator: "\n")
}

/// Produce the header block identifying the app and window.
///
/// Mirrors `app/_lib/tree.py:make_header`.
public func makeHeader(
    app: String,
    pid: Int,
    windowTitle: String?,
    windowId: Int? = nil,
    windowPid: Int? = nil,
    screenshotSize: (width: Int, height: Int)? = nil,
    appState: AppState? = nil,
    codexStyle: Bool = false
) -> String {
    let displayName = app.components(separatedBy: ".").last ?? app
    var lines: [String] = ["App=\(app) (pid \(pid))"]

    if let windowTitle {
        lines.append("Window: \"\(windowTitle)\", App: \(displayName).")
    }
    if codexStyle {
        return lines.joined(separator: "\n")
    }
    if let windowId {
        if let windowPid {
            lines.append("Target window_id=\(windowId), window_pid=\(windowPid).")
        } else {
            lines.append("Target window_id=\(windowId).")
        }
    }
    if let screenshotSize {
        lines.append(
            "Screenshot: \(screenshotSize.width)x\(screenshotSize.height). "
            + "Coordinates use the screenshot's pixel space with origin at the top-left of the image.")
        lines.append("Any Frame hints in the tree use this same screenshot pixel space.")
    }
    if let appState {
        lines.append(
            "isRunning: \(boolStr(appState.isRunning)), isActive: \(boolStr(appState.isActive))")
        if let r = appState.visibleRect {
            lines.append("visibleRect: (\(numStr(r.x)), \(numStr(r.y)), \(numStr(r.w))x\(numStr(r.h)))")
        }
        lines.append("scalingFactor: \(numStr(appState.scalingFactor))")
        if let s = appState.scaledScreenSize {
            lines.append("scaledScreenSize: (\(numStr(s.w))x\(numStr(s.h)))")
        }
        if let c = appState.cursorPosition {
            lines.append("cursorPositionInScaledCoordinates: (\(numStr(c.x)), \(numStr(c.y)))")
        }
    }

    return lines.joined(separator: "\n")
}

/// Mirror Python `str(bool).lower()`.
private func boolStr(_ b: Bool) -> String { b ? "true" : "false" }

/// Mirror Python `str(float)` for the geometry values in the header: integral
/// values still render without a trailing `.0` would not match Python (Python
/// prints `100.0`), so we keep the float repr. AppState geometry is Double;
/// Python's values are floats and print with a decimal. Integral doubles print
/// as `N.0` to match.
private func numStr(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(format: "%.1f", value)
    }
    return String(value)
}
