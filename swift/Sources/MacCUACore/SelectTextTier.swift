import Foundation

// Pure tier-selection logic for the `select_text` Mac impl (US-040, design D1).
//
// `select_text` resolves a content/prefix/suffix request to a UTF-16 range with
// the pure `SelectTextResolver` (US-005), then applies it through one of two
// macOS mechanisms:
//
//   * Tier 1 (CFRange) — simple fields (`NSTextField`/`NSTextView`): set
//     `AXSelectedTextRange` via `AXValueCreate(.cfRange, …)`.
//   * Tier 2 (text markers) — web/rich content (Safari/Chrome/Mail/Pages): CFRange
//     selection does NOT work there; build an `AXTextMarkerRange` from the
//     resolved offsets and set `AXSelectedTextMarkerRange`.
//
// The decision of *which* tier to use given an element's capabilities is pure
// branch logic, so it lives here and is unit-tested on Linux. The Kit side feeds
// it the AX facts (is the selected-text-range settable, does the element expose
// text markers, is it a web area) and acts on the verdict.

/// Which selection mechanism to drive for an element.
public enum SelectTextTier: Equatable, Sendable {
    /// Tier 1 — `AXSelectedTextRange` (CFRange) on a simple field.
    case cfRange
    /// Tier 2 — `AXSelectedTextMarkerRange` on web/rich content.
    case textMarker
}

/// The AX capabilities the Kit side observes on the target element.
public struct SelectTextElementFacts: Equatable, Sendable {
    /// `AXSelectedTextRange` is reported settable on the element.
    public var selectedTextRangeSettable: Bool
    /// The element exposes the text-marker family (e.g. `AXStartTextMarker`).
    public var supportsTextMarkers: Bool
    /// The element's role is a web area / rich-content container where CFRange
    /// selection is unreliable even if it claims the range is settable.
    public var isWebArea: Bool

    public init(
        selectedTextRangeSettable: Bool,
        supportsTextMarkers: Bool,
        isWebArea: Bool
    ) {
        self.selectedTextRangeSettable = selectedTextRangeSettable
        self.supportsTextMarkers = supportsTextMarkers
        self.isWebArea = isWebArea
    }
}

public enum SelectTextTierDecider {
    /// AX roles that denote web/rich content where Tier 2 markers are required.
    public static let webAreaRoles: Set<String> = ["AXWebArea"]

    /// Decide the selection tier from observed element facts.
    ///
    /// Preference order:
    ///  1. A genuine simple field (settable CFRange, not a web area) → Tier 1.
    ///     CFRange is the most reliable mechanism for `NSTextField`/`NSTextView`.
    ///  2. Web/rich content, or any element that exposes text markers → Tier 2.
    ///     CFRange does not select web content even when it claims to be settable.
    ///  3. Otherwise default to Tier 1 (best-effort) — the Kit side fails honestly
    ///     if the apply does not land (never foregrounds).
    public static func decide(_ facts: SelectTextElementFacts) -> SelectTextTier {
        if facts.isWebArea { return .textMarker }
        if facts.selectedTextRangeSettable { return .cfRange }
        if facts.supportsTextMarkers { return .textMarker }
        return .cfRange
    }

    /// Convenience: is `role` a web/rich content role requiring Tier 2?
    public static func isWebAreaRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return webAreaRoles.contains(role)
    }

    /// The marker endpoints (start, end) — in UTF-16 code units — for a resolved
    /// range. A zero-length range (caret) yields `start == end`.
    public static func markerEndpoints(for range: TextRange) -> (start: Int, end: Int) {
        (range.location, range.location + range.length)
    }
}
