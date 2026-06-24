// TypeTextPlan — pure, Linux-testable decomposition of a string into the
// per-grapheme keystroke plan that the Mac input layer (US-033) delivers.
//
// Ports `input.py::type_text`'s loop body: for each unit of text, map a few
// whitespace characters to their named keys, try `parseKeyCombo` to get a
// keycode (the fast, fidelity-preserving path for plain keys), and fall back
// to a Unicode-string keystroke for everything else (emoji, accented letters,
// IME output). Swift iterates by `Character` (extended grapheme cluster), so a
// multi-scalar emoji (ZWJ family, flag, skin-tone) is delivered as ONE Unicode
// keystroke rather than split across scalars — emoji/IME-safe per the C7 spec.

/// One unit of a typed string.
public enum TypeStep: Equatable, Sendable {
    /// Deliver via a virtual keycode with modifier flags (plain keys: letters,
    /// digits, space/return/tab, named punctuation).
    case keycode(keycode: Int, modifiers: Int)
    /// Deliver via `CGEventKeyboardSetUnicodeString` (one grapheme cluster).
    case unicode(String)
}

public enum TypeTextPlan {

    /// Map the whitespace characters that have dedicated keys, matching
    /// `input.py::type_text` (space -> "space", \n/\r -> "return", \t -> "tab").
    public static func keyName(for grapheme: Character) -> String {
        switch grapheme {
        case " ": return "space"
        case "\n", "\r": return "return"
        case "\t": return "tab"
        default: return String(grapheme)
        }
    }

    /// Decompose `text` into an ordered per-grapheme plan. A grapheme whose
    /// key name parses to a keycode becomes `.keycode`; everything else
    /// (emoji, accents, anything `parseKeyCombo` rejects) becomes `.unicode`.
    public static func plan(for text: String) -> [TypeStep] {
        text.map { grapheme in
            let name = keyName(for: grapheme)
            if let parsed = try? KeyParser.parseKeyCombo(name) {
                return .keycode(keycode: parsed.keycode, modifiers: parsed.mask)
            }
            return .unicode(String(grapheme))
        }
    }
}
