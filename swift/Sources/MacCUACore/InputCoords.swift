// InputCoords — pure input-geometry + key-name helpers ported from input.py.
//
// These are the Linux-testable halves of the CGEvent base input path (US-028):
// screenshot-pixel → screen-point coordinate conversion, scroll-delta math, the
// mouse-button table, and the text-key coercion. The macOS CGEvent creation /
// `CGEventPostToPid` delivery lives in MacCUAKit (`KitInputProvider`) and feeds
// these results into events — keeping the only branchy arithmetic pure here.
//
// Prime Invariant note: none of this moves a cursor or foregrounds anything; it
// is pure math + lookups. The Kit layer posts ONLY via `CGEventPostToPid` and
// never warps the cursor (no `kCGEventMouseMoved` pre-positioning — input.py
// deliberately omits it because a posted mouse-move leaks to the visible cursor).

import Foundation

/// Logical mouse button, mapping a tool-facing button name to the CGEvent
/// button index + down/up event-type selectors the Kit layer needs.
public enum MouseButton: String, Sendable, CaseIterable {
    case left
    case right
    case middle

    /// CGEvent mouse-button index (`kCGMouseButton*`): left=0, right=1, center=2.
    public var buttonNumber: UInt32 {
        switch self {
        case .left: return CGMouseButtonNumber.left
        case .right: return CGMouseButtonNumber.right
        case .middle: return CGMouseButtonNumber.center
        }
    }

    public init?(name: String) {
        self.init(rawValue: name)
    }
}

public enum InputCoords {
    /// Convert screenshot-pixel coordinates (window-relative, top-left origin)
    /// to screen-global points. Ports `input.py::window_to_screen_coords` minus
    /// the window-bounds lookup (a Kit read — supplied here via `windowBounds`).
    ///
    /// When `screenshotSize` is provided (and positive), the point is clamped to
    /// the screenshot bounds and scaled by the window/screenshot ratio so a click
    /// computed on a downscaled capture lands at the right place on screen.
    public static func windowToScreenCoords(
        windowBounds: Rect,
        x: Double, y: Double,
        screenshotSize: (width: Int, height: Int)?
    ) -> (x: Double, y: Double) {
        var localX = x
        var localY = y
        if let shot = screenshotSize, shot.width > 0, shot.height > 0 {
            let shotW = Double(shot.width)
            let shotH = Double(shot.height)
            localX = max(0.0, min(x, shotW - 1))
            localY = max(0.0, min(y, shotH - 1))
            localX = localX * (windowBounds.w / shotW)
            localY = localY * (windowBounds.h / shotH)
        }
        return (windowBounds.x + localX, windowBounds.y + localY)
    }

    /// Line-unit scroll deltas for a direction, as `(dy, dx)`. Ports
    /// `input.py::_scroll_deltas` (`_LINE_DELTA == 5`).
    public static func lineScrollDeltas(direction: String) -> (dy: Int, dx: Int) {
        switch direction {
        case "up": return (lineDelta, 0)
        case "down": return (-lineDelta, 0)
        case "left": return (0, lineDelta)
        case "right": return (0, -lineDelta)
        default: return (0, 0)
        }
    }

    /// Pixel scroll deltas for a direction, as `(dy, dx)`. Ports the delta sign
    /// logic shared by `scroll_pid_pixel` / `deliver_scroll`.
    public static func pixelScrollDeltas(direction: String, pixels: Int) -> (dy: Int, dx: Int) {
        switch direction {
        case "up": return (pixels, 0)
        case "down": return (-pixels, 0)
        case "left": return (0, pixels)
        case "right": return (0, -pixels)
        default: return (0, 0)
        }
    }

    public static let lineDelta = 5
    public static let scrollPixelQuantum = 80

    /// Map a single-key name to the literal character to type, or nil when it is
    /// not a plain text key (a combo, or a named key that `parseKeyCombo` should
    /// resolve to a keycode). Ports `input.py::_coerce_text_key`.
    public static func coerceTextKey(_ key: String) -> String? {
        if key.contains("+") { return nil }
        if key.count == 1,
           let ch = key.unicodeScalars.first,
           ch.properties.isAlphabetic || isPrintableNonControl(key),
           key != "\t", key != "\r", key != "\n" {
            return key
        }
        return textKeyAliases[key.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// Single-character printable check matching Python's `str.isprintable()` for
    /// the common cases (excludes control characters / whitespace-only escapes).
    private static func isPrintableNonControl(_ s: String) -> Bool {
        guard s.count == 1, let scalar = s.unicodeScalars.first else { return false }
        if scalar == " " { return true }
        return !scalar.properties.isWhitespace
            && scalar.value >= 0x20
            && scalar.value != 0x7F
    }

    /// Named punctuation keys that map to a literal character. Ports
    /// `input.py::_TEXT_KEY_ALIASES`.
    public static let textKeyAliases: [String: String] = [
        "apostrophe": "'",
        "asciitilde": "~",
        "backslash": "\\",
        "comma": ",",
        "equal": "=",
        "grave": "`",
        "minus": "-",
        "period": ".",
        "quote": "'",
        "semicolon": ";",
        "slash": "/",
    ]
}
