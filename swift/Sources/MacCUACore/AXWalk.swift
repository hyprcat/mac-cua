// AXWalk.swift — pure, Linux-testable port of the accessibility tree walker.
//
// Mirrors `app/_lib/accessibility.py`. The preorder reverse-push DFS, depth /
// node / child caps, display-role mapping, label resolution, state ordering and
// action filtering all live here as pure logic over an injected `AXTreeReader`
// seam. The macOS AX framework calls (reading attributes, children, action
// names, settable flags, pid) live in MacCUAKit behind that seam, so this file
// stays Linux-green and the walk's decision logic is fully fake-tested.

import Foundation

// MARK: - Attribute value model

/// A scalar AX attribute value, normalized off the platform `AXValue`/NSNumber
/// soup by the Kit reader so the pure helpers only ever see plain Swift values.
public enum AXScalar: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// Python-truthiness for the state machine (`if val` / `if not val`).
    public var isTruthy: Bool {
        switch self {
        case .string(let s): return !s.isEmpty
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .bool(let b): return b
        }
    }
}

/// A bag of normalized AX attributes for one element (the batch read result).
public struct AXAttributes: Sendable {
    public var values: [String: AXScalar]
    public init(_ values: [String: AXScalar] = [:]) { self.values = values }
    public subscript(_ key: String) -> AXScalar? { values[key] }
}

// MARK: - AX attribute key constants (match Python _BATCH_ATTRS)

public enum AXAttr {
    public static let role = "AXRole"
    public static let title = "AXTitle"
    public static let description = "AXDescription"
    public static let value = "AXValue"
    public static let valueDescription = "AXValueDescription"
    public static let placeholder = "AXPlaceholderValue"
    public static let help = "AXHelp"
    public static let subrole = "AXSubrole"
    public static let identifier = "AXIdentifier"
    public static let roleDescription = "AXRoleDescription"
    public static let enabled = "AXEnabled"
    public static let selected = "AXSelected"
    public static let expanded = "AXExpanded"
    public static let focused = "AXFocused"
    // A3 rich attributes (US-018): numeric bounds, current selection, set position.
    public static let minValue = "AXMinValue"
    public static let maxValue = "AXMaxValue"
    public static let selectedText = "AXSelectedText"
    public static let positionInSet = "AXARIAPosInSet"
    public static let children = "AXChildren"

    /// The exact attribute batch list the Kit reader fetches per element.
    /// `children` stays last (read on the dedicated child path, skipped as scalar).
    public static let batch: [String] = [
        role, title, description, value, valueDescription, placeholder, help,
        subrole, identifier, roleDescription, enabled, selected, expanded,
        focused, minValue, maxValue, selectedText, positionInSet, children,
    ]
}

// MARK: - Role tables (ported verbatim from accessibility.py)

public enum AXRoleTables {
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXTextField",
        "AXTextArea", "AXCheckBox", "AXRadioButton", "AXSlider",
        "AXComboBox", "AXIncrementor", "AXLink", "AXRow",
        "AXMenuItem", "AXTab", "AXDisclosureTriangle",
    ]

    public static let actionableRoles: Set<String> = interactiveRoles.union([
        "AXWindow", "AXScrollArea", "AXOutline", "AXTable", "AXList", "AXSplitter",
        "AXMenuBarItem", "AXToolbar",
    ])

    public static let childrenFallbackRoles: Set<String> = [
        "AXCollection", "AXGroup", "AXLayoutArea", "AXList",
        "AXOpaqueProviderGroup", "AXOutline", "AXScrollArea", "AXSplitGroup",
        "AXTable", "AXToolbar", "AXWindow",
    ]

    static let subroleDisplayOverrides: [String: String] = [
        "AXStandardWindow": "standard window",
        "AXCollectionList": "collection",
        "AXSectionList": "section",
        "AXSearchField": "search text field",
        "AXOutlineRow": "row",
        "AXCloseButton": "close button",
        "AXMinimizeButton": "minimise button",
        "AXFullScreenButton": "full screen button",
        "AXIncrementArrow": "increment arrow button",
        "AXDecrementArrow": "decrement arrow button",
        "AXIncrementPage": "increment page button",
        "AXDecrementPage": "decrement page button",
    ]

    static let roleDisplayOverrides: [String: String] = [
        "AXApplication": "application", "AXBusyIndicator": "busy indicator",
        "AXButton": "button", "AXCell": "cell", "AXCheckBox": "checkbox",
        "AXCollection": "collection", "AXDialog": "dialog",
        "AXDisclosureTriangle": "disclosure triangle", "AXGroup": "container",
        "AXHeading": "heading", "AXImage": "image", "AXIncrementor": "incrementor",
        "AXLayoutArea": "layout area", "AXLink": "link", "AXList": "list",
        "AXMenu": "menu", "AXMenuBar": "menu bar", "AXMenuBarItem": "menu bar item",
        "AXMenuButton": "menu button", "AXMenuItem": "menu item",
        "AXOutline": "outline", "AXPopUpButton": "popup button",
        "AXProgressIndicator": "progress indicator", "AXRadioButton": "radio button",
        "AXRow": "row", "AXScrollArea": "scroll area", "AXScrollBar": "scroll bar",
        "AXSlider": "slider", "AXSplitGroup": "split group", "AXSplitter": "splitter",
        "AXStaticText": "text", "AXTab": "tab", "AXTable": "table",
        "AXTextArea": "text area", "AXTextField": "text field", "AXToolbar": "toolbar",
        "AXUnknown": "unknown", "AXValueIndicator": "value indicator",
        "AXWebArea": "web area", "AXWindow": "standard window",
    ]

    static let customActionNameMap: [String: String] = [
        "Move previous": "AXMovePrevious",
        "Move next": "AXMoveNext",
        "Remove from toolbar": "AXRemoveFromToolbar",
    ]
}

// MARK: - Pure helpers

public enum AXWalkLogic {
    /// Port of `_clean_text`: trim, drop empties, integralize floats.
    public static func cleanText(_ scalar: AXScalar?) -> String? {
        guard let scalar else { return nil }
        let text: String
        switch scalar {
        case .double(let d):
            if d.rounded() == d && d.isFinite {
                text = String(Int(d))
            } else {
                var s = "\(d)"
                while s.hasSuffix("0") { s.removeLast() }
                if s.hasSuffix(".") { s.removeLast() }
                text = s
            }
        case .int(let i): text = String(i)
        case .bool(let b): text = b ? "True" : "False"
        case .string(let s): text = s
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extract an integer from a numeric AX scalar (e.g. position-in-set).
    /// Returns nil for non-numeric / absent values.
    public static func intValue(_ scalar: AXScalar?) -> Int? {
        switch scalar {
        case .int(let i): return i
        case .double(let d) where d.isFinite: return Int(d)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// Port of `_value_type_name`.
    static func valueTypeName(_ scalar: AXScalar?) -> String? {
        switch scalar {
        case .none: return nil
        case .bool: return "boolean"
        case .double: return "float"
        case .int: return "integer"
        case .string: return "string"
        }
    }

    /// Port of `_display_role`.
    public static func displayRole(attrs: AXAttributes, role: String) -> String {
        let subrole = cleanText(attrs[AXAttr.subrole])
        if let subrole, let mapped = AXRoleTables.subroleDisplayOverrides[subrole] {
            return mapped
        }
        if let mapped = AXRoleTables.roleDisplayOverrides[role] {
            return mapped
        }
        let roleDesc = cleanText(attrs[AXAttr.roleDescription])
        if let roleDesc, !["AXWindow", "AXRow", "AXUnknown"].contains(role) {
            return roleDesc
        }
        let stripped = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return stripped.lowercased()
    }

    /// Port of `_resolve_label`.
    public static func resolveLabel(attrs: AXAttributes, role: String) -> String? {
        if let title = cleanText(attrs[AXAttr.title]) { return title }
        let description = cleanText(attrs[AXAttr.description])
        let value = cleanText(attrs[AXAttr.value])
        let subrole = cleanText(attrs[AXAttr.subrole])
        if let description, role == "AXList",
           subrole == "AXCollectionList" || subrole == "AXSectionList" {
            return description
        }
        if role == "AXHeading", let value, value == description {
            return value
        }
        if let value, description == nil || ["AXStaticText", "AXMenuItem", "AXLink"].contains(role) {
            return value
        }
        return nil
    }

    /// Port of `_normalize_action_name`.
    static func normalizeActionName(_ action: String) -> String? {
        var raw = action.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return nil }
        if raw.hasPrefix("AX") { return raw }
        if raw.contains("\n") {
            let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if firstLine.hasPrefix("Name:") {
                raw = String(firstLine.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if let mapped = AXRoleTables.customActionNameMap[raw] { return mapped }
        if raw.hasPrefix("Name:") {
            let stripped = String(raw.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
            if let mapped = AXRoleTables.customActionNameMap[stripped] { return mapped }
        }
        return nil
    }

    /// Port of `_get_actions` — filter raw action names into model-facing
    /// secondary actions.
    public static func getActions(role: String, rawActionNames: [String]) -> [String] {
        guard AXRoleTables.actionableRoles.contains(role) else { return [] }
        let normalized = rawActionNames.compactMap { normalizeActionName($0) }
        let hasPrimaryActivation = normalized.contains { ["AXPress", "AXConfirm", "AXPick"].contains($0) }
        let suppressed: Set<String> = ["AXPress", "AXCancel", "AXConfirm", "AXPick", "AXShowDefaultUI", "AXShowAlternateUI"]
        var rawActions: [String] = []
        for action in normalized {
            if suppressed.contains(action) { continue }
            if action == "AXShowMenu" && hasPrimaryActivation { continue }
            rawActions.append(action)
        }
        if ["AXScrollArea", "AXCollection", "AXList", "AXOutline", "AXTable"].contains(role) {
            return rawActions.filter { $0 == "AXScrollUpByPage" || $0 == "AXScrollDownByPage" }
        }
        return rawActions
    }

    private static let stateOrder: [String: Int] = [
        "disabled": 0, "selected": 1, "selectable": 2, "expanded": 3,
        "focused": 4, "settable": 5, "string": 6, "float": 7,
        "integer": 8, "boolean": 9,
    ]

    /// Port of `_build_states`. The two macOS `AXUIElementIsAttributeSettable`
    /// probes are injected (`valueSettable`, `rowSelectable`) so this stays pure.
    public static func buildStates(
        attrs: AXAttributes,
        valueSettable: Bool,
        rowSelectable: Bool
    ) -> [String] {
        var states: [String] = []
        // _STATE_MAP order: enabled(invert), selected, expanded, focused.
        if let v = attrs[AXAttr.enabled], !v.isTruthy { states.append("disabled") }
        if let v = attrs[AXAttr.selected], v.isTruthy { states.append("selected") }
        if let v = attrs[AXAttr.expanded], v.isTruthy { states.append("expanded") }
        if let v = attrs[AXAttr.focused], v.isTruthy { states.append("focused") }

        if valueSettable {
            states.append("settable")
            if let vt = valueTypeName(attrs[AXAttr.value]) { states.append(vt) }
        }
        let role = attrs[AXAttr.role].flatMap { if case .string(let s) = $0 { return s } else { return nil } } ?? ""
        if role == "AXRow", rowSelectable, !states.contains("selected") {
            states.append("selectable")
        }
        states.sort { a, b in
            let oa = stateOrder[a] ?? 100, ob = stateOrder[b] ?? 100
            return oa == ob ? a < b : oa < ob
        }
        return states
    }
}

// MARK: - Tree reader seam

/// The per-element AX read surface the pure walker drives. MacCUAKit backs this
/// with real `AXUIElement*` calls; tests back it with an in-memory fake. Reads
/// only — no method here may focus, raise or activate (Invariant 7).
public protocol AXTreeReader: AnyObject {
    func readAttributes(_ element: AXElementRef) -> AXAttributes
    func rawActionNames(_ element: AXElementRef) -> [String]
    func isValueSettable(_ element: AXElementRef) -> Bool
    func isSelectedSettable(_ element: AXElementRef) -> Bool
    /// Children for the walk, including the `_CHILDREN_FALLBACK_ROLES` re-read.
    func childrenForWalk(_ element: AXElementRef, attrs: AXAttributes, role: String) -> [AXElementRef]
    func elementPid(_ element: AXElementRef) -> Int?
    func linkURL(_ element: AXElementRef) -> String?
}

// MARK: - The walker

public enum AXWalk {
    public static let maxChildrenPerElement = 100

    /// Pure preorder reverse-push DFS port of `walk_tree`. Monotonic depth,
    /// `maxDepth` recursion cap, `maxNodes` total cap, 100-children-per-element
    /// cap. The flat node list is in stable AX child order.
    public static func walk(
        root: AXElementRef,
        reader: AXTreeReader,
        targetPid: Int?,
        maxDepth: Int = 30,
        maxNodes: Int = 5000,
        includeActions: Bool = true,
        includeStates: Bool = true
    ) -> [Node] {
        var nodes: [Node] = []
        var stack: [(AXElementRef, Int)] = [(root, 0)]

        while let (element, depth) = stack.popLast(), nodes.count < maxNodes {
            if depth > maxDepth { continue }

            let attrs = reader.readAttributes(element)
            let role: String = {
                if case .string(let s)? = attrs[AXAttr.role] { return s }
                return "AXUnknown"
            }()
            let display = AXWalkLogic.displayRole(attrs: attrs, role: role)
            let label = AXWalkLogic.resolveLabel(attrs: attrs, role: role)
            let states = includeStates
                ? AXWalkLogic.buildStates(
                    attrs: attrs,
                    valueSettable: reader.isValueSettable(element),
                    rowSelectable: role == "AXRow" ? reader.isSelectedSettable(element) : false)
                : []
            let secondaryActions = includeActions
                ? AXWalkLogic.getActions(role: role, rawActionNames: reader.rawActionNames(element))
                : []

            let elementPid = reader.elementPid(element)
            let isOop = targetPid != nil && elementPid != nil && elementPid != targetPid
            let isWebArea = role == "AXWebArea"
            let linkURL = role == "AXLink" ? reader.linkURL(element) : nil

            nodes.append(Node(
                index: nodes.count,
                role: display,
                label: label,
                states: states,
                description: AXWalkLogic.cleanText(attrs[AXAttr.description]),
                value: AXWalkLogic.cleanText(attrs[AXAttr.value]),
                axId: AXWalkLogic.cleanText(attrs[AXAttr.identifier]),
                secondaryActions: secondaryActions,
                depth: depth,
                placeholder: AXWalkLogic.cleanText(attrs[AXAttr.placeholder]),
                helpText: AXWalkLogic.cleanText(attrs[AXAttr.help]),
                valueDescription: AXWalkLogic.cleanText(attrs[AXAttr.valueDescription]),
                minValue: AXWalkLogic.cleanText(attrs[AXAttr.minValue]),
                maxValue: AXWalkLogic.cleanText(attrs[AXAttr.maxValue]),
                selectedText: AXWalkLogic.cleanText(attrs[AXAttr.selectedText]),
                positionInSet: AXWalkLogic.intValue(attrs[AXAttr.positionInSet]),
                axRef: element,
                isWebArea: isWebArea,
                isOop: isOop,
                axRole: role,
                subrole: AXWalkLogic.cleanText(attrs[AXAttr.subrole]),
                elementPid: elementPid,
                url: linkURL
            ))

            let children = reader.childrenForWalk(element, attrs: attrs, role: role)
            if !children.isEmpty {
                // Reverse-push keeps AX child order stable in the flat preorder list.
                let capped = children.prefix(maxChildrenPerElement)
                for child in capped.reversed() {
                    stack.append((child, depth + 1))
                }
            }
        }
        return nodes
    }
}
