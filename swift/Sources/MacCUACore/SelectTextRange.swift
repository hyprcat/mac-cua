import Foundation

// Pure content -> range resolution for the `select_text` tool (US-005, design D1
// "pure tier"). This is the Linux-testable half: it turns a (whole text, target
// substring, optional prefix/suffix, caret placement) request into an unambiguous
// `(location, length)` range or a typed ambiguity/not-found error. The Mac tier
// (US-040) feeds the element's whole text in, takes the resolved range out, and
// applies it via AXSelectedTextRange / AXTextMarkerRange.
//
// Offsets are computed in UTF-16 code units to match macOS `CFRange` semantics
// (AXSelectedTextRange is a CFRange), so a resolved range can be handed straight
// to AXValueCreate(.cfRange, ...) without re-indexing.

/// A resolved selection range, in UTF-16 code units (CFRange-compatible).
public struct TextRange: Equatable, Sendable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// Where to place a zero-length caret instead of selecting the matched span.
public enum CaretPlacement: Equatable, Sendable {
    /// Select the matched substring (default).
    case select
    /// Collapse to a zero-length range at the start of the match.
    case before
    /// Collapse to a zero-length range at the end of the match.
    case after
}

/// Outcome of a resolution attempt.
public enum SelectTextResolution: Equatable, Sendable {
    case resolved(TextRange)
    /// `target` (with the given prefix/suffix) was not found in the text at all.
    case notFound
    /// Multiple matches remain after applying prefix/suffix; `count` of them.
    case ambiguous(count: Int)
}

public enum SelectTextResolver {
    /// Resolve `target` within `text` to a single range.
    ///
    /// - prefix/suffix: optional disambiguators. A candidate match qualifies only
    ///   if the text immediately before it ends with `prefix` and the text
    ///   immediately after it begins with `suffix`.
    /// - caret: collapse the resulting range to a zero-length caret if requested.
    ///
    /// Returns `.notFound` when no candidate matches, `.ambiguous` when more than
    /// one survives disambiguation, and `.resolved` for exactly one.
    public static func resolve(
        text: String,
        target: String,
        prefix: String? = nil,
        suffix: String? = nil,
        caret: CaretPlacement = .select
    ) -> SelectTextResolution {
        let units = Array(text.utf16)
        let targetUnits = Array(target.utf16)

        // An empty target is a pure caret placement: treat as a zero-length match
        // at offset 0 (the Mac tier decides the real caret target separately).
        if targetUnits.isEmpty {
            return .resolved(TextRange(location: 0, length: 0))
        }
        if targetUnits.count > units.count {
            return .notFound
        }

        let prefixUnits = prefix.map { Array($0.utf16) }
        let suffixUnits = suffix.map { Array($0.utf16) }

        var matches: [Int] = []
        var start = 0
        let lastStart = units.count - targetUnits.count
        while start <= lastStart {
            if regionMatches(units, at: start, with: targetUnits) {
                let end = start + targetUnits.count
                if matchesPrefix(units, matchStart: start, prefix: prefixUnits),
                   matchesSuffix(units, matchEnd: end, suffix: suffixUnits) {
                    matches.append(start)
                }
            }
            start += 1
        }

        guard let only = matches.first else { return .notFound }
        if matches.count > 1 { return .ambiguous(count: matches.count) }

        let location = only
        let length = targetUnits.count
        switch caret {
        case .select:
            return .resolved(TextRange(location: location, length: length))
        case .before:
            return .resolved(TextRange(location: location, length: 0))
        case .after:
            return .resolved(TextRange(location: location + length, length: 0))
        }
    }

    // MARK: - helpers

    private static func regionMatches(_ haystack: [UInt16], at index: Int, with needle: [UInt16]) -> Bool {
        for i in 0..<needle.count where haystack[index + i] != needle[i] {
            return false
        }
        return true
    }

    /// The text immediately before the match must *end with* `prefix`.
    private static func matchesPrefix(_ units: [UInt16], matchStart: Int, prefix: [UInt16]?) -> Bool {
        guard let prefix, !prefix.isEmpty else { return true }
        let begin = matchStart - prefix.count
        guard begin >= 0 else { return false }
        return regionMatches(units, at: begin, with: prefix)
    }

    /// The text immediately after the match must *begin with* `suffix`.
    private static func matchesSuffix(_ units: [UInt16], matchEnd: Int, suffix: [UInt16]?) -> Bool {
        guard let suffix, !suffix.isEmpty else { return true }
        guard matchEnd + suffix.count <= units.count else { return false }
        return regionMatches(units, at: matchEnd, with: suffix)
    }
}
