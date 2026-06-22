// Parse xdotool-style key combo strings into (keycode, modifier_mask) pairs.
//
// Pure module -- no macOS imports. Ported from `app/_lib/keys.py`.
//
// Keycode values and modifier bitmasks are exact mirrors of the Python source;
// the model relies on them. On macOS these masks correspond to CGEventFlags
// values and the keycodes correspond to CGKeyCode values, but this module does
// not import any framework -- callers map the integers onto Core Graphics.

// MARK: - Errors

/// Raised when a key combo string cannot be parsed. Mirrors Python `ValueError`
/// with the same message prefixes.
public enum KeyParseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Two or more non-modifier keys appeared in one combo.
    case multipleNonModifierKeys(first: String, second: String, combo: String)
    /// The combo contained only modifiers (no actual key).
    case noNonModifierKeys(combo: String)
    /// A part of the combo was not a known modifier or key name.
    case unknownKey(name: String, combo: String)

    public var description: String {
        switch self {
        case let .multipleNonModifierKeys(first, second, combo):
            return "multiple_non_modifier_keys: '\(first)' and '\(second)' in combo '\(combo)'"
        case let .noNonModifierKeys(combo):
            return "no_non_modifier_keys: combo '\(combo)' has only modifiers"
        case let .unknownKey(name, combo):
            return "unknown_key: '\(name)' in combo '\(combo)'"
        }
    }
}

// MARK: - KeyParser

public enum KeyParser {

    // MARK: Modifier flags (CGEventFlags values)

    public static let maskShift = 1 << 17
    public static let maskControl = 1 << 18
    public static let maskAlternate = 1 << 19
    public static let maskCommand = 1 << 20

    /// Modifier name (lowercase) -> flag mask.
    static let modifiers: [String: Int] = [
        "super": maskCommand,
        "cmd": maskCommand,
        "command": maskCommand,
        "alt": maskAlternate,
        "opt": maskAlternate,
        "option": maskAlternate,
        "ctrl": maskControl,
        "control": maskControl,
        "shift": maskShift,
    ]

    /// (flag, keycode) for each physical modifier key, in the canonical order
    /// used by `modifierKeycodes`. `decomposeModifierSequence` re-sorts by flag.
    static let modifierKeycodeTable: [(flag: Int, keycode: Int)] = [
        (maskCommand, 55),
        (maskShift, 56),
        (maskAlternate, 58),
        (maskControl, 59),
    ]

    // MARK: Key map: lowercase name -> (keycode, extra modifier flags)

    /// Entry in the key map: a keycode plus any modifier flags implied by the name.
    public struct KeyEntry: Equatable, Sendable {
        public let keycode: Int
        public let flags: Int
        public init(keycode: Int, flags: Int) {
            self.keycode = keycode
            self.flags = flags
        }
    }

    static let keyMap: [String: KeyEntry] = {
        var map: [String: KeyEntry] = [:]

        func reg(_ names: [String], _ keycode: Int, _ flags: Int = 0) {
            for n in names {
                map[n.lowercased()] = KeyEntry(keycode: keycode, flags: flags)
            }
        }
        func reg(_ name: String, _ keycode: Int, _ flags: Int = 0) {
            reg([name], keycode, flags)
        }

        // Letters a-z (keycodes in alphabetical order)
        let letterCodes = [
            0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
            45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
        ]
        let aScalar = Int(Character("a").asciiValue!)
        for (i, kc) in letterCodes.enumerated() {
            let ch = String(UnicodeScalar(UInt8(aScalar + i)))
            reg(ch, kc)
        }

        // Digits 0-9
        let digitCodes = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, kc) in digitCodes.enumerated() {
            reg(String(i), kc)
        }

        // Shifted digits (in original Python dict order)
        let shiftedDigits: [(String, Int)] = [
            (")", digitCodes[0]),
            ("!", digitCodes[1]),
            ("@", digitCodes[2]),
            ("#", digitCodes[3]),
            ("$", digitCodes[4]),
            ("%", digitCodes[5]),
            ("^", digitCodes[6]),
            ("&", digitCodes[7]),
            ("*", digitCodes[8]),
            ("(", digitCodes[9]),
        ]
        for (char, kc) in shiftedDigits {
            reg(char, kc, maskShift)
        }

        // F-keys 1-12
        let fCodes = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, kc) in fCodes.enumerated() {
            reg("f\(i + 1)", kc)
        }

        // F-keys 13-20
        let fCodesExt = [105, 107, 113, 106, 64, 79, 80, 90]
        for (i, kc) in fCodesExt.enumerated() {
            reg("f\(i + 13)", kc)
        }

        // Navigation / editing
        reg(["return", "enter"], 36)
        reg("tab", 48)
        reg("space", 49)
        reg(["backspace", "delete", "back_space"], 51)
        reg(["escape", "esc"], 53)
        reg("left", 123)
        reg("right", 124)
        reg("down", 125)
        reg("up", 126)
        reg("home", 115)
        reg("end", 119)
        reg(["page_up", "pageup", "prior"], 116)
        reg(["page_down", "pagedown", "next"], 121)
        reg(["forwarddelete", "forward_delete"], 117)

        // Punctuation / symbols
        reg("minus", 27)
        reg("-", 27)
        reg("_", 27, maskShift)
        reg("equal", 24)
        reg("=", 24)
        reg("+", 24, maskShift)
        reg(["bracketleft", "bracket_left"], 33)
        reg("[", 33)
        reg("{", 33, maskShift)
        reg(["bracketright", "bracket_right"], 30)
        reg("]", 30)
        reg("}", 30, maskShift)
        reg("semicolon", 41)
        reg(";", 41)
        reg(":", 41, maskShift)
        reg(["apostrophe", "quote"], 39)
        reg("'", 39)
        reg("\"", 39, maskShift)
        reg("comma", 43)
        reg(",", 43)
        reg("<", 43, maskShift)
        reg("period", 47)
        reg(".", 47)
        reg(">", 47, maskShift)
        reg("slash", 44)
        reg("/", 44)
        reg("?", 44, maskShift)
        reg("backslash", 42)
        reg("\\", 42)
        reg("|", 42, maskShift)
        reg(["grave", "asciitilde"], 50)
        reg("`", 50)
        reg("~", 50, maskShift)

        // Media
        reg(["volumeup", "volume_up"], 72)
        reg(["volumedown", "volume_down"], 73)
        reg("mute", 74)

        // Keypad
        let kpDigitCodes = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (i, kc) in kpDigitCodes.enumerated() {
            reg("kp_\(i)", kc)
        }
        reg(["kp_decimal", "kp_period"], 65)
        reg("kp_multiply", 67)
        reg("kp_add", 69)
        reg("kp_subtract", 78)
        reg("kp_divide", 75)
        reg("kp_enter", 76)

        return map
    }()

    // MARK: - Parser

    /// Parse an xdotool-style key combo into `(keycode, modifierMask)`.
    ///
    /// Examples:
    ///   parseKeyCombo("super+shift+c")  // -> (8, maskCommand | maskShift)
    ///   parseKeyCombo("Return")          // -> (36, 0)
    ///   parseKeyCombo("C")               // -> (8, maskShift)  (uppercase)
    ///
    /// Throws `KeyParseError` for unknown / malformed combos.
    public static func parseKeyCombo(_ combo: String) throws -> (keycode: Int, mask: Int) {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var mask = 0
        var keyName: String? = nil

        for part in parts {
            let partStripped = part.trimmingCharacters(in: .whitespaces)
            if partStripped.isEmpty {
                continue
            }
            let lower = partStripped.lowercased()
            if let modMask = modifiers[lower] {
                mask |= modMask
            } else {
                if let existing = keyName {
                    throw KeyParseError.multipleNonModifierKeys(
                        first: existing, second: partStripped, combo: combo)
                }
                keyName = partStripped
            }
        }

        guard let name = keyName else {
            throw KeyParseError.noNonModifierKeys(combo: combo)
        }

        let lowerKey = name.lowercased()

        guard let entry = keyMap[lowerKey] else {
            throw KeyParseError.unknownKey(name: name, combo: combo)
        }

        mask |= entry.flags

        // Auto-shift for uppercase single letters: "C" -> shift+c
        if name.count == 1, isUppercaseAlpha(name) {
            mask |= maskShift
        }

        return (entry.keycode, mask)
    }

    /// Single ASCII uppercase letter check, mirroring Python's
    /// `str.isupper() and str.isalpha()` for a one-character string.
    private static func isUppercaseAlpha(_ s: String) -> Bool {
        guard let scalar = s.unicodeScalars.first, s.unicodeScalars.count == 1 else {
            return false
        }
        return scalar >= "A" && scalar <= "Z"
    }

    /// Return `(keycode, flag)` pairs for each modifier present in `mask`, in the
    /// canonical table order (command, shift, alternate, control).
    public static func modifierKeycodes(_ mask: Int) -> [(keycode: Int, flag: Int)] {
        modifierKeycodeTable
            .filter { mask & $0.flag != 0 }
            .map { (keycode: $0.keycode, flag: $0.flag) }
    }

    /// Decompose a modifier mask into an ordered sequence for discrete key events.
    ///
    /// Returns `(keycode, cumulativeFlags)` pairs in the order modifiers should be
    /// pressed (sorted by flag bit position ascending). Each entry's
    /// `cumulativeFlags` is the bitwise OR of all flags up to and including that
    /// modifier -- matching what a real keyboard produces in its `flagsChanged`
    /// event stream.
    public static func decomposeModifierSequence(_ mask: Int) -> [(keycode: Int, cumulativeFlags: Int)] {
        let present = modifierKeycodeTable
            .filter { mask & $0.flag != 0 }
            .sorted { $0.flag < $1.flag } // ascending by flag bit value

        var result: [(keycode: Int, cumulativeFlags: Int)] = []
        var cumulative = 0
        for (flag, keycode) in present {
            cumulative |= flag
            result.append((keycode: keycode, cumulativeFlags: cumulative))
        }
        return result
    }
}
