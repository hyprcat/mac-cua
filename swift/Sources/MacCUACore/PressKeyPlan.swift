// PressKeyPlan — pure, Linux-testable decomposition of a press_key request into
// the ordered, timed key-event stream the Mac input layer (US-034) delivers.
//
// Ports `input.py::press_key` + `_post_keycode_with_modifiers`: a key combo
// parses to a single keycode plus a modifier mask; the mask rides as *flags* on
// the keyDown/keyUp events, NEVER as separate `flagsChanged` events — discrete
// flagsChanged via `CGEventPostToPid` leaks into the user's live modifier state
// (Invariant 3). Per-key down/up plus inter-key interval timing is preserved so
// chords (Cmd-Shift-T) and held keys both register; for a multi-key sequence the
// interval delay separates consecutive keys.

/// One physical key transition. `flags` is the cumulative modifier mask that
/// rides on the event — there is intentionally no `flagsChanged` case, so a
/// plan can never emit a leaking discrete modifier event on the postToPid path.
public enum KeyTransition: Equatable, Sendable {
    case down(keycode: Int, flags: Int)
    case up(keycode: Int, flags: Int)
}

/// A key transition followed by a settle delay (seconds) before the next event.
public struct TimedKeyEvent: Equatable, Sendable {
    public let transition: KeyTransition
    public let delayAfter: Double

    public init(transition: KeyTransition, delayAfter: Double) {
        self.transition = transition
        self.delayAfter = delayAfter
    }
}

public enum PressKeyPlan {
    /// Delay held between a key's down and up (`_KEY_HOLD_DELAY`).
    public static let holdDelay = 0.008
    /// Delay after a key's up before the next event (`_KEY_EVENT_DELAY`).
    public static let eventDelay = 0.003

    /// Normalize a raw key argument the way `press_key` does: a single literal
    /// character may be a text key (coerced to its key name), and a literal
    /// space becomes the named `space` key.
    public static func resolveKeyName(_ key: String) -> String {
        var resolved = InputCoords.coerceTextKey(key)
        if resolved == " " { resolved = "space" }
        return resolved ?? key
    }

    /// Decompose one key combo into a timed down/up pair. Throws the same parse
    /// error `KeyParser` raises (unknown key, multiple non-modifiers, …).
    public static func plan(for key: String) throws -> [TimedKeyEvent] {
        let name = resolveKeyName(key)
        let parsed = try KeyParser.parseKeyCombo(name)
        return [
            TimedKeyEvent(transition: .down(keycode: parsed.keycode, flags: parsed.mask),
                          delayAfter: holdDelay),
            TimedKeyEvent(transition: .up(keycode: parsed.keycode, flags: parsed.mask),
                          delayAfter: eventDelay),
        ]
    }

    /// Decompose an ordered sequence of key combos, preserving inter-key
    /// interval timing (the trailing `eventDelay` of each key already spaces
    /// it from the next). Each combo is delivered as its own down/up pair.
    public static func plan(forSequence keys: [String]) throws -> [TimedKeyEvent] {
        var out: [TimedKeyEvent] = []
        for key in keys {
            out.append(contentsOf: try plan(for: key))
        }
        return out
    }
}
