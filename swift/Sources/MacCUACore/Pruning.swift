import Foundation

// Port of app/_lib/pruning.py — tree pruning & DisplayElement, pure logic with
// no macOS deps. Mirrors the Python module function-for-function.
//
// Representation invariant (Design §3.12, §5.6): nodes are a flat pre-order
// array with a monotonic `depth`; parent/child structure is reconstructed from
// `depth` on demand via `buildTreeIndex` / `buildTreeIndexExcluding`. `Node` is
// a `final class`, so passes mutate nodes in place exactly like Python.
//
// Python-truthiness note: Python treats `None` and the empty string as falsy.
// Optional<String> in Swift is only nil-or-some, so every `if node.label:` style
// check is ported through `isTruthy`, which is false for nil AND "".

// MARK: - Role tables

/// Map AX role to a token-efficient display role string.
private let lmRoleMap: [String: String] = [
    "AXStaticText": "text",
    "AXTextField": "text field",
    "AXTextArea": "text area",
    "AXButton": "button",
    "AXRadioButton": "radio",
    "AXCheckBox": "checkbox",
    "AXPopUpButton": "popup",
    "AXMenuButton": "menu button",
    "AXDisclosureTriangle": "disclosure",
    "AXSlider": "slider",
    "AXComboBox": "combo box",
    "AXIncrementor": "incrementor",
    "AXLink": "link",
    "AXMenuItem": "menu item",
    "AXMenu": "menu",
    "AXMenuBar": "menu bar",
    "AXMenuBarItem": "menu bar item",
    "AXTab": "tab",
    "AXTabGroup": "tab group",
    "AXToolbar": "toolbar",
    "AXWindow": "window",
    "AXSheet": "sheet",
    "AXDialog": "dialog",
    "AXScrollArea": "scroll area",
    "AXTable": "table",
    "AXOutline": "outline",
    "AXList": "list",
    "AXRow": "row",
    "AXColumn": "column",
    "AXCell": "cell",
    "AXImage": "image",
    "AXWebArea": "web area",
    "AXHeading": "heading",
    "AXProgressIndicator": "progress",
    "AXBusyIndicator": "busy",
    "AXLevelIndicator": "level indicator",
    "AXValueIndicator": "value indicator",
    "AXColorWell": "color well",
    "AXDateField": "date field",
    "AXHelpTag": "help",
    "AXMatte": "matte",
    "AXRuler": "ruler",
    "AXApplication": "application",
]

/// Roles that are pure noise and should be skipped entirely.
private let skipRoles: Set<String> = [
    "AXLayoutArea", "AXLayoutItem", "AXMatte", "AXGrowArea",
    "AXUnknown", "AXSplitter", "AXScrollBar",
]

/// Roles that are noise ONLY when they have no label and no actions.
private let skipWhenEmptyRoles: Set<String> = ["AXGroup", "AXSplitGroup"]

private let interactiveRoles: Set<String> = [
    "AXButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
    "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
    "AXComboBox", "AXIncrementor", "AXLink", "AXRow",
    "AXMenuItem", "AXTab", "AXDisclosureTriangle",
]

/// Roles considered selectable/clickable (interactive + cell/menu-bar-item).
private let selectableRoles: Set<String> = interactiveRoles.union(["AXCell", "AXMenuBarItem"])

/// Container roles eligible for single-item group merging.
private let containerRoles: Set<String> = ["AXGroup", "AXSplitGroup", "AXScrollArea"]

/// Text-only roles for merging adjacent siblings.
private let textOnlyRoles: Set<String> = ["AXStaticText", "AXHeading"]

private let codexSkipRoles: Set<String> = [
    "AXColumn", "AXLayoutArea", "AXLayoutItem", "AXMatte", "AXGrowArea",
]

private let codexEmptyWrapperRoles: Set<String> = ["AXGroup", "AXToolbar"]

/// Calendar app bundle IDs for pruneCalendarEventDetails.
private let calendarBundles: Set<String> = [
    "com.apple.iCal", "com.flexibits.fantastical2", "com.flexibits.fantastical",
]

/// Default thresholds.
public let defaultMaxDepth = 30
public let defaultMaxNodes = 5000
public let defaultCollapseThreshold = 200  // children per subtree before collapsing

/// Actions useful to the LLM (stripActions pass).
private let usefulActions: Set<String> = [
    "AXPress", "AXPick", "AXIncrement", "AXDecrement",
    "AXConfirm", "AXCancel", "AXShowMenu", "AXScrollToVisible",
    "AXScrollUpByPage", "AXScrollDownByPage",
    "AXScrollLeftByPage", "AXScrollRightByPage",
    "AXScrollToShowDescendant",
]

// MARK: - Python-truthiness helpers

/// Mirror Python truthiness of an Optional<String>: nil and "" are both falsy.
@inline(__always)
private func isTruthy(_ s: String?) -> Bool {
    if let s { return !s.isEmpty }
    return false
}

// MARK: - DisplayElement — role normalization

/// Map AX role to a token-efficient display role string.
public func computeDisplayRole(_ axRole: String?) -> String {
    guard let axRole else { return "unknown" }
    if let mapped = lmRoleMap[axRole] {
        return mapped
    }
    // Fallback: strip AX prefix and lowercase.
    if axRole.hasPrefix("AX") {
        return String(axRole.dropFirst(2)).lowercased()
    }
    return axRole.lowercased()
}

/// Combine label, description, and value intelligently into a single string.
public func computeDisplayDescription(_ node: Node) -> String? {
    var parts: [String] = []

    if let label = node.label, !label.isEmpty {
        parts.append(label)
    }

    if let desc = node.description, !desc.isEmpty, node.description != node.label {
        parts.append(desc)
    }

    // Value is shown separately for _VALUE_ROLES in serialize, so
    // lm_description doesn't duplicate it.
    if parts.isEmpty, let value = node.value {
        let val = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !val.isEmpty {
            parts.append(val)
        }
    }

    return parts.isEmpty ? nil : parts.joined(separator: " — ")
}

/// Apply DisplayElement protocol to all nodes in-place.
public func applyDisplayProtocol(_ nodes: [Node]) {
    for node in nodes {
        node.lmRole = computeDisplayRole(node.axRole)
        node.lmDescription = computeDisplayDescription(node)
    }
}

// MARK: - Tree structure helpers

/// Build children-of and parent-of maps from a flat depth-ordered list.
///
/// Returns (children, parent) keyed by list index (not node.index). `parent`
/// has an entry for every node (the root maps to nil).
public func buildTreeIndex(_ nodes: [Node]) -> (children: [Int: [Int]], parent: [Int: Int?]) {
    var children: [Int: [Int]] = [:]
    for i in 0..<nodes.count { children[i] = [] }
    var parent: [Int: Int?] = [:]
    if !nodes.isEmpty { parent[0] = .some(nil) }

    // Stack of (list_index, depth).
    var stack: [(Int, Int)] = []

    for (i, node) in nodes.enumerated() {
        while let top = stack.last, top.1 >= node.depth {
            stack.removeLast()
        }
        if let top = stack.last {
            let parentIdx = top.0
            children[parentIdx, default: []].append(i)
            parent[i] = .some(parentIdx)
        } else {
            parent[i] = .some(nil)
        }
        stack.append((i, node.depth))
    }

    return (children, parent)
}

/// Build tree index while reparenting around excluded wrapper nodes.
///
/// Builds the full parent chain first, then walks upward to the nearest
/// non-excluded ancestor for each kept node. This preserves sibling
/// relationships that a naive depth-rebuild would break (Design §5.6).
public func buildTreeIndexExcluding(
    _ nodes: [Node],
    _ exclude: Set<Int>
) -> (children: [Int: [Int]], parent: [Int: Int?]) {
    let (_, fullParent) = buildTreeIndex(nodes)

    var children: [Int: [Int]] = [:]
    for i in 0..<nodes.count where !exclude.contains(i) {
        children[i] = []
    }
    var parent: [Int: Int?] = [:]

    for i in 0..<nodes.count {
        if exclude.contains(i) { continue }
        // fullParent[i] is Int?? — outer optional from dict lookup, inner from value.
        var ancestor: Int? = fullParent[i] ?? nil
        while let a = ancestor, exclude.contains(a) {
            ancestor = fullParent[a] ?? nil
        }
        parent[i] = .some(ancestor)
        if let a = ancestor {
            children[a, default: []].append(i)
        }
    }

    return (children, parent)
}

// MARK: - Pass 1: stripActions

/// Remove non-useful AX actions from all nodes in-place.
public func stripActions(_ nodes: [Node]) {
    for node in nodes where !node.secondaryActions.isEmpty {
        node.secondaryActions = node.secondaryActions.filter { usefulActions.contains($0) }
    }
}

// MARK: - Pass 2: mergeLabelsWithControls

/// Associate title text elements with their adjacent interactive targets.
/// Returns set of indices to remove.
public func mergeLabelsWithControls(_ nodes: [Node]) -> Set<Int> {
    var remove: Set<Int> = []
    guard nodes.count >= 1 else { return remove }
    for i in 0..<(nodes.count - 1) {
        if remove.contains(i) { continue }
        let node = nodes[i]
        let nextNode = nodes[i + 1]
        if node.axRole == "AXStaticText",
           isTruthy(node.label),
           let nextRole = nextNode.axRole, interactiveRoles.contains(nextRole),
           !isTruthy(nextNode.label),
           node.depth == nextNode.depth {
            nextNode.label = node.label
            remove.insert(i)
        }
    }
    return remove
}

// MARK: - Pass 3: collapseIntoInteractiveParent

/// Flatten non-interactive children into their selectable parent.
/// Returns set of child indices to remove.
public func collapseIntoInteractiveParent(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        guard let role = node.axRole, selectableRoles.contains(role) else { continue }
        let kids = childrenMap[i] ?? []
        if kids.isEmpty { continue }
        // All children must be non-interactive leaves.
        let allNonInteractive = kids.allSatisfy { c in
            let cRole = nodes[c].axRole
            let notInteractive = !(cRole.map { interactiveRoles.contains($0) } ?? false)
            return notInteractive && (childrenMap[c] ?? []).isEmpty
        }
        if !allNonInteractive { continue }
        // Merge child labels into parent if parent has no label.
        let childLabels = kids.compactMap { c -> String? in
            isTruthy(nodes[c].label) ? nodes[c].label : nil
        }
        if !childLabels.isEmpty, !isTruthy(node.label) {
            node.label = childLabels.joined(separator: " ")
        }
        for c in kids { remove.insert(c) }
    }
    return remove
}

/// Lift leaf text/image content into sidebar-like rows only.
public func collapseRowChildrenIntoRow(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        if node.axRole != "AXRow" { continue }
        let kids = childrenMap[i] ?? []
        if kids.isEmpty { continue }

        var childTexts: [String] = []
        var childDescriptions: [String] = []
        var rowChildIndices: Set<Int> = []

        for childIdx in kids {
            let child = nodes[childIdx]
            if !(childrenMap[childIdx] ?? []).isEmpty { continue }
            if let cRole = child.axRole, textOnlyRoles.contains(cRole) {
                // text = child.label or child.value  (Python truthiness)
                let text = pyOr(child.label, child.value)
                if let text { childTexts.append(text) }
                rowChildIndices.insert(childIdx)
            } else if child.axRole == "AXImage" {
                let text = pyOr3(child.description, child.label, child.value)
                if let text { childDescriptions.append(text) }
                rowChildIndices.insert(childIdx)
            }
        }

        if rowChildIndices.isEmpty { continue }

        if !childDescriptions.isEmpty, node.description == nil, node.label == nil {
            if !childTexts.isEmpty {
                node.description = childDescriptions[0]
            } else {
                node.label = childDescriptions[0]
            }
        }

        if !childTexts.isEmpty {
            let joinedText = childTexts.joined(separator: " ")
            if node.label == nil, node.description == nil {
                node.label = joinedText
            } else if node.value == nil, joinedText != node.label {
                node.value = joinedText
            }
        }

        remove.formUnion(rowChildIndices)
    }
    return remove
}

/// Collapse outline-row support content into the row itself. Most fragile pass —
/// ported literally from Python (Design §5.6).
public func flattenOutlineRows(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []

    func leafDescendants(_ idx: Int) -> [Int] {
        var leaves: [Int] = []
        for childIdx in childrenMap[idx] ?? [] {
            let grandchildren = childrenMap[childIdx] ?? []
            if !grandchildren.isEmpty {
                leaves.append(contentsOf: leafDescendants(childIdx))
            } else {
                leaves.append(childIdx)
            }
        }
        return leaves
    }

    for (i, node) in nodes.enumerated() {
        if node.axRole != "AXRow" || node.subrole != "AXOutlineRow" { continue }

        let descendants = leafDescendants(i)
        if descendants.isEmpty { continue }

        var textValues: [String] = []
        var textDescriptions: [String] = []
        var imageDescriptions: [String] = []
        var buttonTexts: [String] = []
        var mergedActions = node.secondaryActions
        var mergedStates = node.states
        var flattenable = true

        func mergeState(_ state: String) {
            if !mergedStates.contains(state) { mergedStates.append(state) }
        }
        func mergeAction(_ action: String) {
            if !mergedActions.contains(action) { mergedActions.append(action) }
        }

        for descendantIdx in descendants {
            let descendant = nodes[descendantIdx]
            switch descendant.axRole {
            case "AXStaticText":
                let text = pyOr(descendant.label, descendant.value)
                if let text { textValues.append(text) }
                let description = descendant.description
                if let description, isTruthy(description), description != text {
                    textDescriptions.append(description)
                }
                remove.insert(descendantIdx)
            case "AXImage":
                let description = pyOr3(descendant.description, descendant.label, descendant.value)
                if let description { imageDescriptions.append(description) }
                remove.insert(descendantIdx)
            case "AXDisclosureTriangle":
                for state in descendant.states where ["expanded", "selected", "selectable"].contains(state) {
                    mergeState(state)
                }
                for action in descendant.secondaryActions { mergeAction(action) }
                remove.insert(descendantIdx)
            case "AXButton":
                let description = pyOr3(descendant.description, descendant.label, descendant.value)
                if let description { buttonTexts.append(description) }
                for action in descendant.secondaryActions { mergeAction(action) }
                remove.insert(descendantIdx)
            case "AXCell":
                remove.insert(descendantIdx)
            default:
                flattenable = false
            }
            if !flattenable { break }
        }

        if !flattenable { continue }

        let mainText: String? = {
            let joined = textValues.filter { !$0.isEmpty }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }()
        let iconDescription = imageDescriptions.first { !$0.isEmpty }
        let buttonText = buttonTexts.first { !$0.isEmpty }
        let textDescription = textDescriptions.first { !$0.isEmpty }
        let existingLabel = node.label
        let existingDescription = node.description

        if mainText == nil, iconDescription == nil { continue }

        node.secondaryActions = mergedActions
        node.states = mergedStates

        if let mainText, let iconDescription, iconDescription != mainText {
            if node.description == nil { node.description = iconDescription }
            if node.value == nil { node.value = mainText }
            if node.label == mainText { node.label = nil }
        } else if let mainText, let buttonText, buttonText != mainText {
            if node.label == nil {
                node.label = buttonText
            } else if node.label != buttonText, node.description == nil {
                node.description = buttonText
            }
            if node.value == nil { node.value = mainText }
        } else if let mainText {
            if let existingLabel, existingLabel != mainText, node.description == nil {
                node.description = existingLabel
                node.label = nil
            }
            if let existingDescription, existingDescription != mainText, node.description == nil {
                node.description = existingDescription
            }
            if node.label == nil, node.description == nil, node.value == nil,
               node.states.contains("expanded") || !node.secondaryActions.isEmpty {
                node.value = mainText
            } else if node.label == nil, node.description == nil, node.value == nil {
                node.label = mainText
            } else if node.value == nil, node.label != mainText {
                node.value = mainText
            }
        }

        if let textDescription, node.description == nil,
           textDescription != node.label, textDescription != node.value {
            node.description = textDescription
        }

        for childIdx in childrenMap[i] ?? [] {
            let child = nodes[childIdx]
            if let cRole = child.axRole,
               ["AXCell", "AXImage", "AXStaticText", "AXButton", "AXDisclosureTriangle"].contains(cRole) {
                remove.insert(childIdx)
            }
        }
    }

    return remove
}

/// Collapse wrapper buttons that only host a title button and icon.
public func collapseButtonTitleChildren(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        if node.axRole != "AXButton" { continue }
        let kids = (childrenMap[i] ?? []).filter { !remove.contains($0) }
        if kids.isEmpty { continue }
        let titleChildren = kids.filter { nodes[$0].axRole == "AXButton" }
        if titleChildren.count != 1 { continue }
        let titleIdx = titleChildren[0]
        let titleNode = nodes[titleIdx]
        if !(childrenMap[titleIdx] ?? []).isEmpty { continue }
        if kids.contains(where: { !(["AXButton", "AXImage"].contains(nodes[$0].axRole ?? "")) }) {
            continue
        }
        // title_text = title.label or title.value or title.description
        let titleText = pyOr3(titleNode.label, titleNode.value, titleNode.description)
        guard let titleText else { continue }
        if node.label == nil {
            node.label = titleText
        } else if node.description == nil, node.label != titleText {
            node.description = titleText
        }
        // node.value is None and node.label != title.value and title.value not in {None, node.label}
        if node.value == nil, node.label != titleNode.value,
           let tv = titleNode.value, tv != node.label {
            node.value = titleNode.value
        }
        if node.description == nil, let td = titleNode.description, isTruthy(td), td != node.label {
            node.description = titleNode.description
        }
        for childIdx in kids { remove.insert(childIdx) }
    }
    return remove
}

/// Remove outline rows that contain no human-usable content.
public func dropEmptyOutlineRows(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []

    func subtreeIndices(_ idx: Int) -> [Int] {
        var result = [idx]
        for childIdx in childrenMap[idx] ?? [] {
            result.append(contentsOf: subtreeIndices(childIdx))
        }
        return result
    }

    for (i, node) in nodes.enumerated() {
        if node.axRole != "AXRow" || node.subrole != "AXOutlineRow" { continue }
        if isTruthy(node.label) || isTruthy(node.description) || isTruthy(node.value)
            || !node.secondaryActions.isEmpty { continue }
        let descendants = Array(subtreeIndices(i).dropFirst())
        if descendants.isEmpty {
            remove.insert(i)
            continue
        }
        var meaningful = false
        for descendantIdx in descendants {
            let descendant = nodes[descendantIdx]
            if isTruthy(descendant.label) || isTruthy(descendant.description)
                || isTruthy(descendant.value) || !descendant.secondaryActions.isEmpty {
                meaningful = true
                break
            }
            if !(["AXCell", "AXGroup"].contains(descendant.axRole ?? "")) {
                meaningful = true
                break
            }
        }
        if !meaningful {
            remove.insert(i)
            remove.formUnion(descendants)
        }
    }

    return remove
}

// MARK: - Pass 4: removeEmptySubtrees

/// A node is descriptive if it has label, value, actions, or meaningful state.
private func isDescriptive(_ node: Node) -> Bool {
    if isTruthy(node.label) { return true }
    if let value = node.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return true
    }
    if !node.secondaryActions.isEmpty { return true }
    if let role = node.axRole, interactiveRoles.contains(role) { return true }
    for s in node.states where ["selected", "focused", "expanded"].contains(s) {
        return true
    }
    return false
}

private func subtreeIsDescriptive(
    _ idx: Int,
    _ children: [Int: [Int]],
    _ nodes: [Node]
) -> Bool {
    if isDescriptive(nodes[idx]) { return true }
    return (children[idx] ?? []).contains { subtreeIsDescriptive($0, children, nodes) }
}

/// Return set of list indices to remove (entire non-descriptive subtrees).
public func removeEmptySubtrees(
    _ nodes: [Node],
    _ children: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []

    func collectSubtree(_ idx: Int) {
        remove.insert(idx)
        for c in children[idx] ?? [] { collectSubtree(c) }
    }

    for i in 0..<nodes.count {
        if remove.contains(i) { continue }
        if !subtreeIsDescriptive(i, children, nodes) {
            collectSubtree(i)
        }
    }

    return remove
}

// MARK: - Pass 5: removeDisabledBlanks

/// Return set of list indices for disabled elements with no label/value.
public func removeDisabledBlanks(_ nodes: [Node]) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        if node.states.contains("disabled"), !isTruthy(node.label), !isTruthy(node.value) {
            remove.insert(i)
        }
    }
    return remove
}

// MARK: - Pass 6: unwrapSingleChildGroups

/// Remove groups that contain exactly one child, promoting the child.
public func unwrapSingleChildGroups(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        if remove.contains(i) { continue }
        guard let role = node.axRole, containerRoles.contains(role) else { continue }
        let kids = childrenMap[i] ?? []
        if kids.count != 1 { continue }
        let childIdx = kids[0]
        let child = nodes[childIdx]
        if isTruthy(node.label), !isTruthy(child.label) {
            child.label = node.label
        }
        let depthDelta = child.depth - node.depth
        adjustSubtreeDepth(childIdx, nodes, childrenMap, -depthDelta)
        remove.insert(i)
    }
    return remove
}

private func adjustSubtreeDepth(
    _ idx: Int,
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]],
    _ delta: Int
) {
    nodes[idx].depth += delta
    for c in childrenMap[idx] ?? [] {
        adjustSubtreeDepth(c, nodes, childrenMap, delta)
    }
}

// MARK: - Pass 7: collapseRedundantWrappers

/// Remove intermediate containers that add no semantic information.
public func collapseRedundantWrappers(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        if remove.contains(i) { continue }
        let kids = childrenMap[i] ?? []
        if kids.count != 1 { continue }
        let child = nodes[kids[0]]
        if node.axRole == child.axRole, !isTruthy(node.label), node.secondaryActions.isEmpty {
            let depthDelta = child.depth - node.depth
            adjustSubtreeDepth(kids[0], nodes, childrenMap, -depthDelta)
            remove.insert(i)
        }
    }
    return remove
}

// MARK: - Pass 8: mergeAdjacentText

/// Merge consecutive AXStaticText siblings into one node.
public func mergeAdjacentText(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for parentIdx in childrenMap.keys.sorted() {
        let kids = childrenMap[parentIdx] ?? []
        var runStart: Int? = nil
        for childIdx in kids {
            if remove.contains(childIdx) { continue }
            let child = nodes[childIdx]
            if child.axRole == "AXStaticText" {
                if runStart == nil {
                    runStart = childIdx
                } else {
                    let first = nodes[runStart!]
                    if isTruthy(child.label) {
                        first.label = (first.label ?? "") + " " + (child.label ?? "")
                    }
                    remove.insert(childIdx)
                }
            } else {
                runStart = nil
            }
        }
    }
    return remove
}

// MARK: - Pass 9: inlineLinksAsMarkdown

/// Convert link + text children into markdown [text](url).
public func inlineLinksAsMarkdown(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for (i, node) in nodes.enumerated() {
        if node.axRole != "AXLink" { continue }
        let kids = childrenMap[i] ?? []
        if kids.isEmpty { continue }
        var texts: [String] = []
        var allText = true
        for c in kids {
            if remove.contains(c) { continue }
            let child = nodes[c]
            if let cRole = child.axRole, ["AXStaticText", "AXHeading"].contains(cRole), isTruthy(child.label) {
                texts.append(child.label!)
            } else if child.axRole == "AXImage" {
                // Skip images in links.
            } else {
                allText = false
                break
            }
        }
        if allText, !texts.isEmpty {
            let linkText = texts.joined(separator: " ")
            // url = node.url or node.web_area_url or node.description or ""
            let url = pyOr3(node.url, node.webAreaUrl, node.description) ?? ""
            if !url.isEmpty {
                node.label = "[\(linkText)](\(url))"
            } else {
                node.label = linkText
            }
            for c in kids { remove.insert(c) }
        }
    }
    return remove
}

// MARK: - Pass 10: combineTextSiblings

/// Merge adjacent text-only siblings (text, heading) into one node.
public func combineTextSiblings(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]]
) -> Set<Int> {
    var remove: Set<Int> = []
    for parentIdx in childrenMap.keys.sorted() {
        let kids = childrenMap[parentIdx] ?? []
        var runStart: Int? = nil
        for childIdx in kids {
            if remove.contains(childIdx) { continue }
            let child = nodes[childIdx]
            if let cRole = child.axRole, textOnlyRoles.contains(cRole), child.secondaryActions.isEmpty {
                if runStart == nil {
                    runStart = childIdx
                } else {
                    let first = nodes[runStart!]
                    if isTruthy(child.label) {
                        let sep = child.axRole == "AXHeading" ? "\n" : " "
                        first.label = (first.label ?? "") + sep + (child.label ?? "")
                        if let fRole = first.axRole, textOnlyRoles.contains(fRole) {
                            first.value = nil
                        }
                    }
                    remove.insert(childIdx)
                }
            } else {
                runStart = nil
            }
        }
    }
    return remove
}

// MARK: - Pass 11: pruneCalendarEventDetails

/// Remove verbose subtrees under calendar event containers.
public func pruneCalendarEventDetails(
    _ nodes: [Node],
    _ childrenMap: [Int: [Int]],
    _ bundleId: String? = nil
) -> Set<Int> {
    if let bundleId, !calendarBundles.contains(bundleId) {
        return []
    }

    var remove: Set<Int> = []

    func collectSubtree(_ idx: Int) {
        for c in childrenMap[idx] ?? [] {
            remove.insert(c)
            collectSubtree(c)
        }
    }

    for (i, node) in nodes.enumerated() {
        if node.axRole == "AXGroup",
           isTruthy(node.label),
           node.depth >= 3,
           (childrenMap[i] ?? []).count >= 3 {
            collectSubtree(i)
        }
    }
    return remove
}

// MARK: - firstNonemptyIndex

/// Find the first node that has a label, value, action, or interactive role.
public func firstNonemptyIndex(_ nodes: [Node]) -> Int {
    for (i, node) in nodes.enumerated() {
        if isDescriptive(node) { return i }
    }
    return 0
}

// MARK: - Skip roles

/// True if this node should be skipped entirely during serialization.
public func shouldSkipRole(_ node: Node) -> Bool {
    guard let axRole = node.axRole else { return false }
    if skipRoles.contains(axRole) { return true }
    if skipWhenEmptyRoles.contains(axRole) {
        if !isTruthy(node.label), node.secondaryActions.isEmpty {
            return true
        }
    }
    return false
}

// MARK: - maxDepth / SubtreeCollapse marking

/// Return indices of nodes exceeding maxDepth (will be collapsed in output).
public func markCollapsedDepth(_ nodes: [Node], _ maxDepth: Int = defaultMaxDepth) -> Set<Int> {
    var result: Set<Int> = []
    for (i, node) in nodes.enumerated() where node.depth > maxDepth {
        result.insert(i)
    }
    return result
}

/// For subtrees exceeding threshold, return {parent_idx: total_children}.
public func markCollapsedChildren(
    _ nodes: [Node],
    _ children: [Int: [Int]],
    _ threshold: Int = defaultCollapseThreshold
) -> [Int: Int] {
    var collapsed: [Int: Int] = [:]
    for (i, childList) in children where childList.count > threshold {
        collapsed[i] = childList.count
    }
    return collapsed
}

// MARK: - URL shortener

/// Configuration for URL shortening in tree output.
public struct URLShortenerConfig {
    public var individualLimit: Int
    public var totalLimit: Int
    public var includeQuery: Bool
    public var includeFragment: Bool

    public init(
        individualLimit: Int = 80,
        totalLimit: Int = 2000,
        includeQuery: Bool = false,
        includeFragment: Bool = false
    ) {
        self.individualLimit = individualLimit
        self.totalLimit = totalLimit
        self.includeQuery = includeQuery
        self.includeFragment = includeFragment
    }
}

/// Shorten a single URL according to config. Mirrors urlparse/urlunparse:
/// strip query & fragment unless configured, then enforce the individual limit.
private func shortenSingleURL(_ url: String, _ config: URLShortenerConfig) -> String {
    guard let parsed = ParsedURL(url) else {
        return url.count > config.individualLimit ? String(url.prefix(config.individualLimit)) : url
    }

    let query = config.includeQuery ? parsed.query : ""
    let fragment = config.includeFragment ? parsed.fragment : ""

    var shortened = parsed.unparse(query: query, fragment: fragment)

    if shortened.count > config.individualLimit {
        shortened = String(shortened.prefix(config.individualLimit - 3)) + "..."
    }

    return shortened
}

/// Regex matching URLs in text (markdown links or bare URLs). Mirrors
/// `r'https?://[^\s\)>]+'`.
private let urlRegex = try! NSRegularExpression(pattern: "https?://[^\\s\\)>]+")

/// Shorten URLs across all nodes in-place.
public func shortenURLs(_ nodes: [Node], _ config: URLShortenerConfig = URLShortenerConfig()) {
    var accumulated = 0

    for node in nodes {
        if let waUrl = node.webAreaUrl, !waUrl.isEmpty, accumulated < config.totalLimit {
            let shortened = shortenSingleURL(waUrl, config)
            node.webAreaUrl = shortened
            accumulated += shortened.count
        }

        if let url = node.url, !url.isEmpty, accumulated < config.totalLimit {
            let shortened = shortenSingleURL(url, config)
            node.url = shortened
            accumulated += shortened.count
        }

        if let label = node.label, label.contains("http"), accumulated < config.totalLimit {
            let ns = label as NSString
            let matches = urlRegex.matches(in: label, range: NSRange(location: 0, length: ns.length))
            // Rebuild the string, replacing matches left-to-right (mirrors re.sub).
            var resultParts: [String] = []
            var lastEnd = 0
            for match in matches {
                let r = match.range
                resultParts.append(ns.substring(with: NSRange(location: lastEnd, length: r.location - lastEnd)))
                let urlText = ns.substring(with: r)
                if accumulated >= config.totalLimit {
                    resultParts.append(urlText)
                } else {
                    let shortened = shortenSingleURL(urlText, config)
                    accumulated += shortened.count
                    resultParts.append(shortened)
                }
                lastEnd = r.location + r.length
            }
            resultParts.append(ns.substring(from: lastEnd))
            node.label = resultParts.joined()
        }
    }
}

// MARK: - Web area node cap

/// Maximum nodes kept inside any single web area subtree. Keeps the *last*
/// (newest) N descendants (Design §5.6).
public let webAreaNodeCap = 300

/// Mark excess web area children for removal, keeping the last `cap` nodes.
/// Returns a set of additional indices to skip.
public func capWebAreaNodes(
    _ nodes: [Node],
    _ skipIndices: Set<Int>,
    cap: Int = webAreaNodeCap
) -> Set<Int> {
    var extraSkips: Set<Int> = []

    var webAreaIndices: [Int] = []
    for (i, node) in nodes.enumerated() {
        if skipIndices.contains(i) { continue }
        if node.isWebArea { webAreaIndices.append(i) }
    }

    for waIdx in webAreaIndices {
        let waDepth = nodes[waIdx].depth
        var descendants: [Int] = []
        var j = waIdx + 1
        while j < nodes.count {
            if nodes[j].depth <= waDepth { break }
            if !skipIndices.contains(j) { descendants.append(j) }
            j += 1
        }

        if descendants.count <= cap { continue }

        let toRemove = Array(descendants[0..<(descendants.count - cap)])
        extraSkips.formUnion(toRemove)

        let removedCount = toRemove.count
        let truncNote = " (\(removedCount) earlier elements truncated)"
        if let label = nodes[waIdx].label, !label.isEmpty {
            nodes[waIdx].label = label + truncNote
        } else {
            nodes[waIdx].label = truncNote.trimmingCharacters(in: .whitespaces)
        }
    }

    return extraSkips
}

// MARK: - Full pruning pipeline

/// Result of the full pruning pipeline:
/// (pruned nodes, subtree-collapsed parents → total child count, depth-collapsed parents).
public struct PruneResult {
    public var nodes: [Node]
    public var collapseInfo: [Int: Int]
    public var depthCollapsedParents: Set<Int>

    public init(nodes: [Node], collapseInfo: [Int: Int], depthCollapsedParents: Set<Int>) {
        self.nodes = nodes
        self.collapseInfo = collapseInfo
        self.depthCollapsedParents = depthCollapsedParents
    }
}

/// Run the full pruning pipeline. See pruning.py:prune for the 17-step order.
public func prune(
    _ nodes: [Node],
    maxDepth: Int = defaultMaxDepth,
    collapseThreshold: Int = defaultCollapseThreshold,
    advanced: Bool = true,
    bundleId: String? = nil
) -> PruneResult {
    if nodes.isEmpty {
        return PruneResult(nodes: [], collapseInfo: [:], depthCollapsedParents: [])
    }

    // Step 1: Apply DisplayElement.
    applyDisplayProtocol(nodes)

    var skipIndices: Set<Int> = []

    if advanced {
        // Step 2: Strip actions.
        stripActions(nodes)
        // Step 3: Merge labels with controls.
        skipIndices.formUnion(mergeLabelsWithControls(nodes))
        // Step 4: Collapse into interactive parents.
        let (childrenMap, _) = buildTreeIndex(nodes)
        skipIndices.formUnion(collapseIntoInteractiveParent(nodes, childrenMap))
    }

    // Step 5: Remove always-skip roles.
    for (i, node) in nodes.enumerated() where shouldSkipRole(node) {
        skipIndices.insert(i)
    }

    // Step 6: Remove empty subtrees.
    var (childrenMap, _) = buildTreeIndex(nodes)
    skipIndices.formUnion(removeEmptySubtrees(nodes, childrenMap))

    // Step 7: Remove disabled blanks.
    skipIndices.formUnion(removeDisabledBlanks(nodes))

    if advanced {
        // Step 8: Unwrap single-child groups.
        (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
        skipIndices.formUnion(unwrapSingleChildGroups(nodes, childrenMap))

        // Step 9: Collapse redundant wrappers.
        (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
        skipIndices.formUnion(collapseRedundantWrappers(nodes, childrenMap))

        // Step 10: Merge adjacent text.
        (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
        skipIndices.formUnion(mergeAdjacentText(nodes, childrenMap))

        // Step 11: Inline links as markdown (reuse step 10 children_map).
        skipIndices.formUnion(inlineLinksAsMarkdown(nodes, childrenMap))

        // Step 12: Combine text siblings.
        (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
        skipIndices.formUnion(combineTextSiblings(nodes, childrenMap))

        // Step 13: Prune calendar event details.
        if bundleId != nil {
            (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
            skipIndices.formUnion(pruneCalendarEventDetails(nodes, childrenMap, bundleId))
        }

        // Step 13b: Cap web area subtrees.
        skipIndices.formUnion(capWebAreaNodes(nodes, skipIndices))
    }

    // Rebuild tree index for depth/collapse passes (excluding all removed nodes).
    let (finalChildren, parentMap) = buildTreeIndexExcluding(nodes, skipIndices)

    // Step 14: Mark depth-exceeded for collapse.
    let depthCollapsed = markCollapsedDepth(nodes, maxDepth)

    // Track which kept nodes have children hidden by depth collapse.
    var depthCollapsedParentsOrig: Set<Int> = []
    for idx in depthCollapsed {
        var p: Int? = parentMap[idx] ?? nil
        while let pp = p, depthCollapsed.contains(pp) {
            p = parentMap[pp] ?? nil
        }
        if let pp = p, !skipIndices.contains(pp) {
            depthCollapsedParentsOrig.insert(pp)
        }
    }

    // Step 15: Mark large subtrees for SubtreeCollapse.
    let collapsedParentsOrig = markCollapsedChildren(nodes, finalChildren, collapseThreshold)

    // Step 16: Filter and reindex.
    var keptNodes: [Node] = []
    var collapseInfo: [Int: Int] = [:]
    var oldToNew: [Int: Int] = [:]

    for (i, node) in nodes.enumerated() {
        if skipIndices.contains(i) { continue }
        if depthCollapsed.contains(i) { continue }

        // SubtreeCollapse: if parent is collapsed, only keep first 5 children.
        let p: Int? = parentMap[i] ?? nil
        if let pp = p, collapsedParentsOrig[pp] != nil {
            let siblingList = finalChildren[pp] ?? []
            if let pos = siblingList.firstIndex(of: i), pos >= 5 {
                continue  // Hidden by SubtreeCollapse.
            }
        }

        let newIdx = keptNodes.count
        oldToNew[i] = newIdx
        node.index = newIdx
        keptNodes.append(node)
    }

    // Build collapse info for new indices.
    for (oldParent, total) in collapsedParentsOrig {
        if let newParent = oldToNew[oldParent] {
            collapseInfo[newParent] = total
        }
    }

    // Build depth-collapsed parents for new indices.
    var depthCollapsedParentsNew: Set<Int> = []
    for oldParent in depthCollapsedParentsOrig {
        if let newParent = oldToNew[oldParent] {
            depthCollapsedParentsNew.insert(newParent)
        }
    }

    // Adjust depths: find the first non-empty element and use it as base.
    if !keptNodes.isEmpty {
        let firstMeaningful = firstNonemptyIndex(keptNodes)
        if firstMeaningful > 0 {
            let baseDepth = keptNodes[firstMeaningful].depth
            for node in keptNodes {
                node.depth = max(0, node.depth - baseDepth)
            }
        }
    }

    // Step 17: Shorten URLs.
    if advanced {
        shortenURLs(keptNodes)
    }

    return PruneResult(nodes: keptNodes, collapseInfo: collapseInfo, depthCollapsedParents: depthCollapsedParentsNew)
}

/// Light pruning that preserves the raw AX hierarchy more faithfully (Codex
/// pipeline). Uses parent-chain depth recomputation rather than delta-adjust.
public func pruneForCodexTree(_ nodes: [Node], bundleId: String? = nil) -> [Node] {
    if nodes.isEmpty { return [] }

    applyDisplayProtocol(nodes)

    var skipIndices: Set<Int> = []
    skipIndices.formUnion(mergeLabelsWithControls(nodes))

    var (childrenMap, _) = buildTreeIndex(nodes)
    skipIndices.formUnion(collapseRowChildrenIntoRow(nodes, childrenMap))
    skipIndices.formUnion(flattenOutlineRows(nodes, childrenMap))
    (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
    skipIndices.formUnion(dropEmptyOutlineRows(nodes, childrenMap))
    (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
    skipIndices.formUnion(collapseButtonTitleChildren(nodes, childrenMap))
    (childrenMap, _) = buildTreeIndexExcluding(nodes, skipIndices)
    skipIndices.formUnion(combineTextSiblings(nodes, childrenMap))

    for (i, node) in nodes.enumerated() {
        if node.axRole == "AXList", node.subrole == "AXCollectionList" {
            node.states = node.states.filter { $0 != "focused" }
        }
        if let role = node.axRole, textOnlyRoles.contains(role), isTruthy(node.label) {
            node.value = nil
        }
        if let role = node.axRole, codexSkipRoles.contains(role) {
            skipIndices.insert(i)
            continue
        }
        if let role = node.axRole, codexEmptyWrapperRoles.contains(role),
           !isTruthy(node.label), !isTruthy(node.description), !isTruthy(node.value),
           node.secondaryActions.isEmpty,
           (!isTruthy(node.axId) || (childrenMap[i] ?? []).count == 1) {
            skipIndices.insert(i)
            continue
        }
        if let role = node.axRole, ["AXImage", "AXStaticText"].contains(role),
           !isTruthy(node.label), !isTruthy(node.description), !isTruthy(node.value) {
            skipIndices.insert(i)
        }
    }

    let (_, parentMap) = buildTreeIndexExcluding(nodes, skipIndices)
    var newDepths: [Int: Int] = [:]
    var keptNodes: [Node] = []
    for (i, node) in nodes.enumerated() {
        if skipIndices.contains(i) { continue }
        let parentIdx: Int? = parentMap[i] ?? nil
        if let pi = parentIdx {
            node.depth = newDepths[pi]! + 1
        } else {
            node.depth = 0
        }
        newDepths[i] = node.depth
        node.index = keptNodes.count
        keptNodes.append(node)
    }

    shortenURLs(keptNodes)
    return keptNodes
}

// MARK: - Python-`or` helpers for String?

/// Mirror `a or b` for optional strings under Python truthiness: returns the
/// first non-empty value (treating nil and "" as falsy), else the last operand.
@inline(__always)
private func pyOr(_ a: String?, _ b: String?) -> String? {
    if let a, !a.isEmpty { return a }
    return b
}

@inline(__always)
private func pyOr3(_ a: String?, _ b: String?, _ c: String?) -> String? {
    if let a, !a.isEmpty { return a }
    if let b, !b.isEmpty { return b }
    return c
}
