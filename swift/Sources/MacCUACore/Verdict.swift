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
}
