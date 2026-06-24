// AXWriteValue — pure attribute-value coercion for AX writes (US-036).
//
// `setAttribute(node:attr:value:)` receives the value as a Swift `String` (the
// tool surface is text). For most attributes the AX framework accepts a CFString
// (Python's `set_attribute` passes the Python `str` straight through, which
// PyObjC bridges to NSString). But a few attributes are typed and a CFString is
// rejected:
//
//   • Boolean toggles (AXFocused, AXSelected, AXMain, AXMinimized, AXEnabled,
//     AXExpanded, AXHidden) want a CFBoolean.
//   • Range attributes (AXSelectedTextRange, AXVisibleCharacterRange) want an
//     AXValue of kind `.cfRange` — the "AXValue-typed ranges" of the story.
//
// Classifying this is pure string logic (no AX framework), so it lives in Core
// and is fake-tested on Linux. Kit maps the result onto the right CFTypeRef.
//
// The default is `.string` — a faithful match for Python's pass-through, so any
// attribute we don't recognise behaves exactly as before.

import Foundation

public enum AXWriteValue: Equatable, Sendable {
    case string(String)
    case boolean(Bool)
    /// An AXValue `.cfRange` — (location, length).
    case range(location: Int, length: Int)
}

public enum AXAttributeWrite {
    /// Attributes whose settable value is a CFBoolean.
    public static let booleanAttributes: Set<String> = [
        "AXFocused", "AXSelected", "AXMain", "AXMinimized",
        "AXEnabled", "AXExpanded", "AXHidden",
    ]

    /// Attributes whose settable value is an AXValue `.cfRange`.
    public static let rangeAttributes: Set<String> = [
        "AXSelectedTextRange", "AXVisibleCharacterRange",
    ]

    /// Coerce a string value for `attr` into the AX-typed form Kit should create.
    ///
    /// - Boolean attrs: "true"/"1"/"yes" (case-insensitive) → true, else false.
    /// - Range attrs: "loc,len" / "loc:len" / "loc len" → `.range`; an unparseable
    ///   range string falls back to `.string` (the framework will reject it
    ///   honestly rather than us guessing a wrong range).
    /// - Everything else → `.string`.
    public static func classify(attr: String, value: String) -> AXWriteValue {
        if booleanAttributes.contains(attr) {
            return .boolean(parseBool(value))
        }
        if rangeAttributes.contains(attr) {
            if let r = parseRange(value) {
                return .range(location: r.0, length: r.1)
            }
            return .string(value)
        }
        return .string(value)
    }

    static func parseBool(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes", "y", "on": return true
        default: return false
        }
    }

    /// Parse "loc,len" / "loc:len" / "loc len" into a (location, length) pair.
    /// Returns nil if it does not split into exactly two non-negative integers.
    static func parseRange(_ value: String) -> (Int, Int)? {
        let separators = CharacterSet(charactersIn: ",: ")
        let parts = value
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              let loc = Int(parts[0]), let len = Int(parts[1]),
              loc >= 0, len >= 0 else {
            return nil
        }
        return (loc, len)
    }
}
