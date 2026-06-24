import Foundation

// Pure tier for "where is this text on screen" text-geometry queries (US-021,
// design A5 / CODEX_PARITY §A5). The Mac tier (MacCUAKit) backs this with the
// parameterized AX attributes `kAXBoundsForRange`, `kAXRangeForPosition`, and
// `kAXVisibleCharacterRange`; this file is the Linux-testable decision logic
// around those calls — clamping a requested range to what's actually visible,
// validating a range against the text length, and unioning per-line rects into
// a single bounding box.
//
// Ranges are in UTF-16 code units (CFRange semantics), matching `TextRange`
// (US-005) so a resolved selection range can be fed straight into a bounds query.

/// The reader seam the Mac tier implements via parameterized AX attributes.
/// Pure code (and tests) drives this through fakes.
public protocol TextGeometryReader: AnyObject {
    /// `kAXBoundsForRangeParameterizedAttribute`: on-screen bounds of a range.
    func boundsForRange(_ element: AXElementRef, range: TextRange) -> Rect?
    /// `kAXRangeForPositionParameterizedAttribute`: the character range at a point.
    func rangeForPosition(_ element: AXElementRef, x: Double, y: Double) -> TextRange?
    /// `kAXVisibleCharacterRangeAttribute`: the currently-visible character range.
    func visibleCharacterRange(_ element: AXElementRef) -> TextRange?
    /// Full text length in UTF-16 code units (from `kAXValue` / number-of-chars),
    /// used to validate a requested range. `nil` when unknown.
    func textLength(_ element: AXElementRef) -> Int?
}

/// Outcome of resolving on-screen bounds for a requested range.
public enum TextBoundsResolution: Equatable, Sendable {
    /// Bounds resolved (possibly clamped to the visible range — see `clamped`).
    case resolved(Rect, clamped: Bool)
    /// The requested range lies entirely outside the visible range (scrolled off).
    case offscreen
    /// The requested range is invalid against the element's text length.
    case invalidRange
    /// The element exposes no bounds for the range (not a text element / no SPI).
    case unavailable
}

/// Pure helpers around the parameterized text-geometry attributes.
public enum TextGeometryLogic {
    /// Whether `range` is a valid sub-range of text of `textLength` code units.
    /// A zero-length caret at `textLength` (end of text) is valid.
    public static func isValid(range: TextRange, textLength: Int) -> Bool {
        guard range.location >= 0, range.length >= 0, textLength >= 0 else { return false }
        return range.location + range.length <= textLength
    }

    /// Intersect a requested range with the visible character range.
    /// Returns the overlapping portion, or `nil` when there is no overlap
    /// (the requested text is scrolled entirely out of view).
    public static func clampToVisible(_ range: TextRange, visible: TextRange) -> TextRange? {
        let reqStart = range.location
        let reqEnd = range.location + range.length
        let visStart = visible.location
        let visEnd = visible.location + visible.length
        let start = max(reqStart, visStart)
        let end = min(reqEnd, visEnd)
        if end < start { return nil }
        // A zero-length caret exactly at the visible boundary is still "visible".
        if end == start && range.length > 0 { return nil }
        return TextRange(location: start, length: end - start)
    }

    /// Union a set of per-line bounds rects into a single bounding box.
    /// Some text engines return one rect per visual line for a multi-line range;
    /// callers that only need the overall box union them here. `nil` if empty.
    public static func unionBounds(_ rects: [Rect]) -> Rect? {
        guard let first = rects.first else { return nil }
        var minX = first.x, minY = first.y
        var maxX = first.x + first.w, maxY = first.y + first.h
        for r in rects.dropFirst() {
            minX = min(minX, r.x)
            minY = min(minY, r.y)
            maxX = max(maxX, r.x + r.w)
            maxY = max(maxY, r.y + r.h)
        }
        return Rect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    /// Full resolution: validate the requested range against the text length
    /// (when known), clamp it to the visible range (when known), then ask the
    /// reader for bounds. This is the "where is this text" decision logic with
    /// the AX calls behind the `reader` seam so it is Linux-testable.
    public static func resolveBounds(
        element: AXElementRef,
        range: TextRange,
        reader: TextGeometryReader
    ) -> TextBoundsResolution {
        if let len = reader.textLength(element), !isValid(range: range, textLength: len) {
            return .invalidRange
        }
        var query = range
        var clamped = false
        if let visible = reader.visibleCharacterRange(element) {
            guard let c = clampToVisible(range, visible: visible) else { return .offscreen }
            if c != range { clamped = true }
            query = c
        }
        guard let rect = reader.boundsForRange(element, range: query) else { return .unavailable }
        return .resolved(rect, clamped: clamped)
    }
}
