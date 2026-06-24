// Port of app/_lib/confirmed_verification.py — unified action verification:
// pre/post element snapshots + delivery confirmation.
//
// This module is the home of the "transport ≠ outcome" rule (SWIFT_PORT_DESIGN
// §3 invariants 20–21, §5): a *confirmed* transport that produces *no* state
// change is `DELIVERED_NO_EFFECT`, NOT a delivery failure. The verdict logic is
// pure and stateless — `ActionVerifier.computeVerdict` takes only the four input
// signals the Session wires in from the real AX/transport layers.

/// The outcome of a single action's delivery, distinguishing *transport* (did
/// the event reach the app?) from *effect* (did the UI change?).
public enum DeliveryVerdict: String, Sendable, Equatable {
    case confirmed = "confirmed"
    case confirmedViaFallback = "confirmed_via_fallback"
    case deliveredNoEffect = "delivered_no_effect"
    case transportFailed = "transport_failed"
}

/// What kind of UI change a tool expects after a successful action.
public enum ExpectedDiff: String, Sendable, Equatable {
    case focusOrLayout = "focus_or_layout"
    case selectionChanged = "selection_changed"
    case valueChanged = "value_changed"
    case layoutOrMenu = "layout_or_menu"
    case menuToggled = "menu_toggled"
    case actionDependent = "action_dependent"
    case transportOnly = "transport_only"
}

/// Diff between two `ElementSnapshot`s.
public struct StateDiff: Sendable, Equatable {
    public let valueChanged: Bool
    public let selectionChanged: Bool
    public let focusChanged: Bool
    public let menuToggled: Bool
    public let layoutChanged: Bool

    public init(
        valueChanged: Bool,
        selectionChanged: Bool,
        focusChanged: Bool,
        menuToggled: Bool,
        layoutChanged: Bool
    ) {
        self.valueChanged = valueChanged
        self.selectionChanged = selectionChanged
        self.focusChanged = focusChanged
        self.menuToggled = menuToggled
        self.layoutChanged = layoutChanged
    }

    public var anyChanged: Bool {
        valueChanged
            || selectionChanged
            || focusChanged
            || menuToggled
            || layoutChanged
    }
}

/// Lightweight capture of element state for pre/post comparison.
///
/// Python's `value` and `focused_element_id` are typed `Any`; the diff only ever
/// compares them for (in)equality. `AnyHashable?` faithfully mirrors that — any
/// value the Session captures (a string, an element id, `nil`, …) round-trips
/// through equality the same way Python's `!=` does.
public struct ElementSnapshot: Equatable {
    public let value: AnyHashable?
    public let selected: Bool
    public let focusedElementId: AnyHashable?
    public let menuOpen: Bool
    public let childCount: Int

    public init(
        value: AnyHashable?,
        selected: Bool,
        focusedElementId: AnyHashable?,
        menuOpen: Bool,
        childCount: Int
    ) {
        self.value = value
        self.selected = selected
        self.focusedElementId = focusedElementId
        self.menuOpen = menuOpen
        self.childCount = childCount
    }

    public func diff(_ after: ElementSnapshot) -> StateDiff {
        StateDiff(
            valueChanged: value != after.value,
            selectionChanged: selected != after.selected,
            focusChanged: focusedElementId != after.focusedElementId,
            menuToggled: menuOpen != after.menuOpen,
            layoutChanged: childCount != after.childCount
        )
    }
}

// MARK: - Tree-wide change summary (E3)

/// A structured diff between a pre-action and post-action node tree, keyed by a
/// *stable element key* (the graph locator identity, NOT `role|label|frame` —
/// see SWIFT_PORT_DESIGN §3 invariant on element keys / US-012). This is the E3
/// upgrade: it lets the verdict say "confirmed transport + zero tree change =
/// `DELIVERED_NO_EFFECT`" as a first-class outcome rather than inferring it from
/// a single element snapshot.
///
/// `added` / `removed` / `changed` carry the stable keys of the affected nodes
/// so callers can report exactly *what* moved without leaking any AX ref string
/// into the model packet.
public struct ChangeSummary: Sendable, Equatable {
    /// Stable keys present only in `post`.
    public let added: [String]
    /// Stable keys present only in `pre`.
    public let removed: [String]
    /// Stable keys present in both, but with a differing volatile attribute
    /// (value / states / label / description / valueDescription / placeholder).
    public let changed: [String]

    public init(added: [String], removed: [String], changed: [String]) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }

    /// True when nothing was added, removed, or changed (the 0/0/0 case that
    /// drives `DELIVERED_NO_EFFECT`).
    public var isEmpty: Bool {
        added.isEmpty && removed.isEmpty && changed.isEmpty
    }

    public var totalChanges: Int {
        added.count + removed.count + changed.count
    }
}

/// Pure tree-diff helpers. Stateless — given the pre/post flat node lists, emit
/// the `ChangeSummary`.
public enum TreeDiff {
    /// The stable identity key for a node: derived from its `graphLocator`
    /// (structural identity, excluding the volatile `value`), falling back to
    /// `axId`, then to the preorder index. Deliberately NOT `role|label|frame`.
    public static func stableKey(_ node: Node) -> String {
        if let loc = node.graphLocator {
            let path = loc.parentPath
                .map { "\($0.axRole ?? "")~\($0.label ?? "")~\($0.identity ?? "")" }
                .joined(separator: "/")
            return [
                "loc",
                loc.axRole ?? "",
                loc.label ?? "",
                loc.description ?? "",
                loc.axId ?? "",
                String(loc.depth),
                String(loc.siblingOrdinal),
                path,
            ].joined(separator: "|")
        }
        if let axId = node.axId, !axId.isEmpty {
            return "ax|\(axId)"
        }
        return "idx|\(node.index)"
    }

    /// The volatile attributes that, if they differ between two same-key nodes,
    /// mark the node as `changed`.
    private static func volatileSignature(_ node: Node) -> [String?] {
        [
            node.value,
            node.states.sorted().joined(separator: ","),
            node.label,
            node.description,
            node.valueDescription,
            node.placeholder,
        ]
    }

    /// Compute the added / removed / changed summary between two node trees.
    /// Keys are emitted in `pre`-then-`post` first-seen order for determinism.
    public static func changeSummary(pre: [Node], post: [Node]) -> ChangeSummary {
        var preByKey: [String: Node] = [:]
        var preOrder: [String] = []
        for node in pre {
            let key = stableKey(node)
            if preByKey[key] == nil { preOrder.append(key) }
            preByKey[key] = node
        }

        var postByKey: [String: Node] = [:]
        var postOrder: [String] = []
        for node in post {
            let key = stableKey(node)
            if postByKey[key] == nil { postOrder.append(key) }
            postByKey[key] = node
        }

        var removed: [String] = []
        var changed: [String] = []
        for key in preOrder {
            guard let before = preByKey[key] else { continue }
            if let after = postByKey[key] {
                if volatileSignature(before) != volatileSignature(after) {
                    changed.append(key)
                }
            } else {
                removed.append(key)
            }
        }

        var added: [String] = []
        for key in postOrder where preByKey[key] == nil {
            added.append(key)
        }

        return ChangeSummary(added: added, removed: removed, changed: changed)
    }
}

/// Stateless verdict computation. Session wires in the actual AX/transport
/// signals.
public enum ActionVerifier {
    /// Compute the delivery verdict from the four input signals.
    ///
    /// The order of checks is load-bearing (mirrors Python exactly):
    /// 1. No transport ⇒ `transportFailed` (nothing reached the app).
    /// 2. `transportOnly` expectation ⇒ `confirmed` (e.g. scroll: transport *is*
    ///    the outcome, a UI diff is neither required nor checked).
    /// 3. A real UI diff ⇒ `confirmed` (or `confirmedViaFallback` if a fallback
    ///    input path was used).
    /// 4. Otherwise — confirmed transport, no diff — `deliveredNoEffect`. This is
    ///    NOT a failure: the event landed, the app simply did nothing
    ///    observable (already-checked checkbox, no-op keypress, …).
    public static func computeVerdict(
        transportConfirmed: Bool,
        diffAnyChanged: Bool,
        expected: ExpectedDiff,
        fallbackUsed: Bool
    ) -> DeliveryVerdict {
        if !transportConfirmed {
            return .transportFailed
        }

        if expected == .transportOnly {
            return .confirmed
        }

        if diffAnyChanged {
            if fallbackUsed {
                return .confirmedViaFallback
            }
            return .confirmed
        }

        return .deliveredNoEffect
    }

    /// E3 overload: compute the verdict from a tree-wide `ChangeSummary` instead
    /// of a single-element diff. Same load-bearing order as the scalar version:
    /// no transport ⇒ `transportFailed`; `transportOnly` ⇒ `confirmed`; any
    /// added/removed/changed ⇒ `confirmed`/`confirmedViaFallback`; otherwise —
    /// confirmed transport, 0/0/0 change — `deliveredNoEffect`.
    public static func computeVerdict(
        transportConfirmed: Bool,
        changeSummary: ChangeSummary,
        expected: ExpectedDiff,
        fallbackUsed: Bool
    ) -> DeliveryVerdict {
        computeVerdict(
            transportConfirmed: transportConfirmed,
            diffAnyChanged: !changeSummary.isEmpty,
            expected: expected,
            fallbackUsed: fallbackUsed
        )
    }
}
