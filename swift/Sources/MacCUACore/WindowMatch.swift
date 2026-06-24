// WindowMatch.swift — pure fallback for binding an AX window to a CGWindowID
// (A4). The PRIMARY binding is the private `_AXUIElementGetWindow` SPI in
// MacCUAKit (US-020); this is the bounds/title scoring fallback used only when
// that symbol is absent (per-symbol-optional) or returns no id. Ported from
// screenshot.py `find_window_id_for_ax_window`. Linux-pure (no macOS imports):
// the AX signature + window list are read in Kit and handed in as plain values.

/// The AX-side signature of a window: its title and on-screen geometry, as read
/// from `kAXTitle`/`kAXPosition`/`kAXSize`. Any field may be missing.
public struct AXWindowSignature: Equatable, Sendable {
    public var title: String?
    public var position: Point?
    public var size: Point?

    public init(title: String? = nil, position: Point? = nil, size: Point? = nil) {
        self.title = title
        self.position = position
        self.size = size
    }
}

/// Pure scoring matcher: pick the CGWindowID whose window-server record best
/// matches an AX window's signature. Mirrors screenshot.py exactly so the Mac
/// fallback path is Linux-testable.
public enum WindowMatcher {
    /// Score a single candidate window against the AX signature + expected pid.
    /// Returns `nil` for ineligible candidates (id 0, off-base layer, empty size)
    /// — they must be skipped, never chosen.
    public static func score(
        window w: WindowInfo,
        layer: Int,
        signature: AXWindowSignature,
        pid: Int
    ) -> Double? {
        if w.windowId == 0 { return nil }
        // Only the normal window layer (0) is a real app window; ignore menus,
        // the Dock, overlays, etc.
        if layer != 0 { return nil }
        if w.width <= 0 || w.height <= 0 { return nil }

        var score = 0.0

        if w.ownerPid == pid {
            score += 200
        }

        if let axTitle = signature.title, !axTitle.isEmpty {
            let windowName = w.title ?? ""
            if windowName == axTitle {
                score += 1000
            } else if windowName.lowercased() == axTitle.lowercased() {
                score += 950
            } else if !windowName.isEmpty,
                      windowName.lowercased().contains(axTitle.lowercased()) {
                score += 700
            }
        }

        if let pos = signature.position, let size = signature.size {
            let dx = abs(w.x - pos.x)
            let dy = abs(w.y - pos.y)
            let dw = abs(w.width - size.x)
            let dh = abs(w.height - size.y)
            score += max(0.0, 600.0 - ((dx + dy) * 4.0) - (dw + dh))
        }

        if w.onscreen {
            score += 50
        }
        if !(w.title ?? "").isEmpty {
            score += 10
        }

        return score
    }

    /// Best-matching window id, or nil if no candidate is eligible. `layers`
    /// supplies the CGWindowLayer for each window (Core does not carry it on
    /// `WindowInfo`); a missing entry is treated as layer 0.
    public static func bestMatch(
        windows: [WindowInfo],
        layers: [Int: Int],
        signature: AXWindowSignature,
        pid: Int
    ) -> Int? {
        var bestId: Int? = nil
        var bestScore = -Double.infinity
        for w in windows {
            let layer = layers[w.windowId] ?? 0
            guard let s = score(window: w, layer: layer, signature: signature, pid: pid) else {
                continue
            }
            if s > bestScore {
                bestScore = s
                bestId = w.windowId
            }
        }
        return bestId
    }
}
