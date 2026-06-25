// US-051 — GhostCursorOverlay AppKit impl: a single desktop-spanning ghost cursor.
//
// The decorative payoff layer. There is exactly ONE borderless, transparent,
// click-through, NON-ACTIVATING `NSPanel` spanning the union of all displays,
// hosting a single CALayer "sprite" (the blue Bibata-style arrow). The agent's
// logical cursor drives this one sprite to wherever it acts — so a single cursor
// visibly TRAVELS across apps/windows, gliding over whatever is between them.
// It is created on the first `show` and persists for the whole process (the
// agent/session lifetime); per-window hide/occlusion/follow no longer apply.
//
// HARD RULE (Prime Invariant): decorative ONLY. This never routes through the
// system cursor, never warps it, never foregrounds/activates/raises anything:
//   - `.nonactivatingPanel` style + `canBecomeKey/Main = false` → ordering the
//     panel in NEVER steals key/main from the user's app.
//   - `ignoresMouseEvents = true` → clicks pass THROUGH to the underlying app.
//   - `orderFrontRegardless()` shows without activating our process.
// There is no system-cursor or activation API touched anywhere in this file.

#if os(macOS)
import Foundation
import AppKit
import QuartzCore
import MacCUACore

/// Real `GhostCursorOverlay`: a single non-activating, desktop-spanning `NSPanel`
/// hosting one travelling cursor sprite. Used on the main thread (AppKit
/// requirement) — call sites hop to main. The `windowId` arguments of the
/// protocol are ignored: every driven window shares the one cursor.
public final class KitGhostCursorOverlay: GhostCursorOverlay {
    /// Bounding size (points) used for the reusable click-ripple ring.
    public static let spriteSize: CGFloat = 22

    /// Bibata source viewBox + the scale from it to on-screen points.
    private static let viewBox: CGFloat = 256
    private static let renderScale: CGFloat = 0.14

    /// "Bibata-Modern-Ice, but blue": saturated azure body + white "Ice" outline.
    private static let bibataBlue = CGColor(red: 0.16, green: 0.51, blue: 0.97, alpha: 0.97)
    private static let iceOutline = CGColor(gray: 1.0, alpha: 0.98)
    /// Outline width in Bibata's 256 space (matches the source SVG stroke-width).
    private static let strokeWidth256: CGFloat = 17

    /// One Bibata-Modern pointer: its SVG path `d` (256×256 viewBox, top-left /
    /// y-down) plus the hotspot in that same space.
    private struct CursorShape { let d: String; let hotspot: CGPoint }
    private static let shapes: [GhostCursorKind: CursorShape] = [
        .arrow: CursorShape(d: arrowD, hotspot: CGPoint(x: 55, y: 17)),
        .ibeam: CursorShape(d: ibeamD, hotspot: CGPoint(x: 128, y: 128)),
        .hand:  CursorShape(d: handD,  hotspot: CGPoint(x: 114, y: 18)),
    ]

    // Real open-source Bibata-Modern outlines (github.com/ful1e5/Bibata_Cursor,
    // GPL-3.0). Recolored blue here; geometry verbatim from the source SVGs.
    private static let arrowD = "M201.163 133.54L201.149 133.528L201.134 133.515L91.6855 36.4935C86.5144 31.7659 81.4269 27.9549 76.5421 25.525C71.7671 23.1497 66.0861 21.5569 60.4133 23.1213C54.3118 24.8039 50.4875 29.4674 48.3639 34.759C46.3122 39.8715 45.4999 46.2787 45.4999 53.5383L45.4999 200.431V200.493L45.5008 200.555C45.6218 208.862 50.4279 217.843 55.9963 223.894C58.8934 227.043 62.5163 229.986 66.6704 231.742C70.9172 233.537 76.217 234.254 81.4691 231.884C85.7536 229.951 89.6754 226.055 92.8565 222.651C94.6841 220.695 96.8336 218.252 99.0355 215.749C100.71 213.847 102.414 211.91 104.03 210.126C112.189 201.122 121.346 192.286 132.161 187.407C143.013 182.511 155.809 181.375 167.963 181.146C170.959 181.089 173.85 181.087 176.65 181.085H176.663H176.686C179.447 181.083 182.164 181.081 184.662 181.019C189.231 180.906 194.643 180.609 198.777 178.88C208.711 174.723 210.972 163.838 210.753 156.445C210.521 148.596 207.57 139.272 201.163 133.54Z"
    private static let ibeamD = "M127.93 223.209C136.047 229.785 146.386 233.751 157.637 233.751H163.861C170.212 233.751 175.361 228.603 175.361 222.251V209.684C175.361 203.333 170.212 198.184 163.861 198.184H157.637C151.115 198.184 145.654 192.795 145.654 186.021V69.2299C145.654 62.4559 151.115 57.0668 157.637 57.0668H163.861C170.212 57.0668 175.361 51.9181 175.361 45.5668V33C175.361 26.6487 170.212 21.5 163.861 21.5H157.637C146.386 21.5 136.047 25.4666 127.93 32.0427C119.813 25.4666 109.475 21.5 98.2233 21.5H91.9998C85.6485 21.5 80.4998 26.6487 80.4998 33V45.5668C80.4998 51.9181 85.6485 57.0668 91.9998 57.0668H98.2233C104.746 57.0668 110.207 62.4559 110.207 69.2299V186.021C110.207 192.795 104.746 198.184 98.2233 198.184H91.9998C85.6485 198.184 80.4998 203.333 80.4998 209.684V222.251C80.4998 228.603 85.6484 233.751 91.9998 233.751H98.2233C109.475 233.751 119.813 229.785 127.93 223.209Z"
    private static let handD = "M120.764 243.559C106.064 243.654 94.9315 234.669 87.33 226.47C79.4457 217.966 72.2147 206.838 65.6646 196.382C64.2676 194.152 62.8936 191.939 61.5335 189.749C56.2005 181.16 51.0808 172.915 45.6262 165.321C38.7567 155.756 32.4011 148.765 26.3033 144.633L15.5723 137.361L19.7447 125.088L21.19 121.644C21.9919 119.999 23.1992 117.834 24.9231 115.515C28.3468 110.91 34.2913 105.096 43.5504 102.37C55.11 98.9669 67.7847 101.278 81.7607 109.426V53.5426C81.7607 33.8583 92.6922 13.7197 113.92 13.7197C135.148 13.7197 146.079 33.8583 146.079 53.5426V68.5677C148.285 68.8131 150.453 69.277 152.536 69.9474C157.658 71.5961 162.433 74.4963 166.346 78.4184C171.172 77.2686 176.261 77.2401 181.23 78.443C187.462 79.9516 192.776 83.1349 196.914 87.5425C202.677 86.2935 208.508 86.7836 213.723 88.5338C228.189 93.3895 238.812 108.053 236.948 126.259L225.329 242.882L120.764 243.559Z"

    private final class Entry {
        let panel: NSPanel
        let sprite: CAShapeLayer
        /// Reusable click-ripple ring (kept at opacity 0 between pulses → no
        /// per-click layer churn / no cross-isolation layer capture).
        let ripple: CALayer
        /// Reusable element-highlight outline (opacity 0 when idle).
        let highlightLayer: CALayer
        /// The panel's frame in AppKit (bottom-left) screen coords — the union of
        /// all displays. Used to convert CG-global points into panel-local space.
        var desktopAppKitFrame: CGRect
        var kind: GhostCursorKind = .arrow
        var thinking = false
        init(panel: NSPanel, sprite: CAShapeLayer, ripple: CALayer,
             highlightLayer: CALayer, desktopAppKitFrame: CGRect) {
            self.panel = panel
            self.sprite = sprite
            self.ripple = ripple
            self.highlightLayer = highlightLayer
            self.desktopAppKitFrame = desktopAppKitFrame
        }
    }

    /// The one and only cursor. Created lazily on first `show`, kept for the
    /// process lifetime (single cursor that travels across apps).
    private var shared: Entry?

    public init() {}

    /// Height of the primary display — the AppKit y-flip reference. The primary
    /// screen is `NSScreen.screens.first` (the one containing the menu bar / origin).
    private var primaryScreenHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    /// The union of every display's frame in AppKit (bottom-left) screen coords —
    /// the desktop-spanning panel rect so the cursor can travel anywhere.
    private func desktopAppKitFrame() -> CGRect {
        let screens = NSScreen.screens
        guard var u = screens.first?.frame else { return .zero }
        for s in screens.dropFirst() { u = u.union(s.frame) }
        return u
    }

    /// Convert a CG-global point (top-left origin, y-down) into the desktop
    /// panel's local (bottom-left) coordinate space.
    private func localPoint(forGlobalCG cg: Point, in frame: CGRect) -> CGPoint {
        let appKitX = CGFloat(cg.x)
        let appKitY = CGFloat(primaryScreenHeight - cg.y)   // CG top-left → AppKit bottom-left
        return CGPoint(x: appKitX - frame.origin.x, y: appKitY - frame.origin.y)
    }

    // MARK: - GhostCursorOverlay (windowId ignored — one shared cursor)

    public func show(windowId: Int, style: GhostCursorStyle, windowFrame: Rect?) {
        onMain {
            if self.shared != nil { return }      // single cursor already live
            let entry = self.makeDesktopPanel(style: style)
            self.shared = entry
            entry.panel.orderFrontRegardless()
        }
    }

    public func move(windowId: Int, to point: Point, animated: Bool) {
        onMain {
            guard let entry = self.shared else { return }
            let local = self.localPoint(forGlobalCG: point, in: entry.desktopAppKitFrame)
            let target = CGPoint(x: local.x, y: local.y)
            let from = entry.sprite.position
            if animated && (from.x >= 0 || from.y >= 0) {
                // Bezier "scoot": arc the sprite to the target via Core Animation
                // keyframe path. Control points come from the pure Core geometry.
                let (c1, c2) = GhostAnimationGeometry.scootControlPoints(
                    from: Point(x: Double(from.x), y: Double(from.y)),
                    to: Point(x: Double(target.x), y: Double(target.y)))
                let path = CGMutablePath()
                path.move(to: from)
                path.addCurve(to: target,
                              control1: CGPoint(x: c1.x, y: c1.y),
                              control2: CGPoint(x: c2.x, y: c2.y))
                let dx = Double(target.x - from.x), dy = Double(target.y - from.y)
                let dist = (dx * dx + dy * dy).squareRoot()
                let anim = CAKeyframeAnimation(keyPath: "position")
                anim.path = path
                anim.duration = GhostAnimationParams.glideDuration(forDistance: dist)
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                entry.sprite.position = target          // commit final value first
                entry.sprite.add(anim, forKey: "scoot")
            } else {
                // Decorative move: reposition the sprite layer only — no cursor warp.
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                entry.sprite.position = target
                CATransaction.commit()
            }
        }
    }

    public func pulse(windowId: Int) {
        onMain {
            guard let entry = self.shared else { return }
            // Click ripple: re-animate the reusable ring (expand + fade) at the
            // sprite's current position, plus a quick scale-bounce of the sprite.
            let dur = GhostAnimationParams.pulseDuration
            entry.ripple.position = entry.sprite.position
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1.0
            grow.toValue = GhostAnimationParams.pulseMaxScale
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = dur
            entry.ripple.add(group, forKey: "ripple")     // ripple.opacity stays 0

            let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
            bounce.values = [1.0, 1.25, 1.0]
            bounce.keyTimes = [0, 0.5, 1]
            bounce.duration = dur * 0.6
            entry.sprite.add(bounce, forKey: "bounce")
        }
    }

    public func highlight(windowId: Int, bounds: Rect) {
        onMain {
            guard let entry = self.shared else { return }
            // Convert the CG-global element rect into the desktop panel's local
            // (bottom-left) space — same y-flip as the sprite point conversion.
            let f = entry.desktopAppKitFrame
            let localX = CGFloat(bounds.x) - f.origin.x
            let localY = CGFloat(self.primaryScreenHeight - (bounds.y + bounds.h)) - f.origin.y
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.highlightLayer.frame = CGRect(x: localX, y: localY, width: bounds.w, height: bounds.h)
            CATransaction.commit()

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = GhostAnimationParams.highlightDuration
            entry.highlightLayer.add(fade, forKey: "highlight")  // opacity stays 0
        }
    }

    public func setThinking(windowId: Int, active: Bool) {
        onMain {
            guard let entry = self.shared else { return }
            entry.thinking = active
            if active {
                let wiggle = CABasicAnimation(keyPath: "transform.rotation.z")
                wiggle.fromValue = -GhostAnimationParams.wiggleAmplitude
                wiggle.toValue = GhostAnimationParams.wiggleAmplitude
                wiggle.duration = GhostAnimationParams.wigglePeriod / 2
                wiggle.autoreverses = true
                wiggle.repeatCount = .greatestFiniteMagnitude
                wiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                entry.sprite.add(wiggle, forKey: "wiggle")
            } else {
                entry.sprite.removeAnimation(forKey: "wiggle")
            }
        }
    }

    public func setKind(windowId: Int, _ kind: GhostCursorKind) {
        onMain {
            guard let entry = self.shared, entry.kind != kind else { return }
            entry.kind = kind
            // Swap the pointer outline in place (keeps the same screen position via
            // the hotspot-derived anchorPoint). No implicit animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.configure(entry.sprite, kind: kind)
            CATransaction.commit()
        }
    }

    // The single travelling cursor is never window-clipped, window-followed, or
    // per-session hidden — it persists for the session and glides freely over
    // everything. These remain to satisfy the protocol but are intentional no-ops.
    public func setClipRegion(windowId: Int, region: [Rect]) {}
    public func setWindowFrame(windowId: Int, _ frame: Rect?) {}
    public func hide(windowId: Int) {}
    public func remove(windowId: Int) {}

    // MARK: - Panel construction

    private func makeDesktopPanel(style _: GhostCursorStyle) -> Entry {
        let frame = desktopAppKitFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Never become key/main → ordering in never steals focus (Prime Invariant).
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true               // click-through to the app below
        panel.level = .screenSaver                     // high level, above app windows
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .ignoresCycle, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        host.wantsLayer = true
        host.layer?.masksToBounds = false              // cursor travels freely desktop-wide
        panel.contentView = host

        let s = Self.spriteSize
        // Reusable click-ripple ring (kept invisible between pulses).
        let ripple = CALayer()
        ripple.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        ripple.cornerRadius = s / 2
        ripple.position = CGPoint(x: -s, y: -s)
        ripple.backgroundColor = CGColor(gray: 1, alpha: 0)
        ripple.borderColor = Self.bibataBlue
        ripple.borderWidth = 2
        ripple.opacity = 0
        host.layer?.addSublayer(ripple)

        // Reusable element-highlight outline (kept invisible until highlight()).
        let highlightLayer = CALayer()
        highlightLayer.cornerRadius = 4
        highlightLayer.borderColor = Self.bibataBlue
        highlightLayer.borderWidth = 2
        highlightLayer.backgroundColor = CGColor(gray: 1, alpha: 0)
        highlightLayer.opacity = 0
        host.layer?.addSublayer(highlightLayer)

        let sprite = makeSprite(kind: .arrow)
        host.layer?.addSublayer(sprite)

        return Entry(panel: panel, sprite: sprite, ripple: ripple,
                     highlightLayer: highlightLayer, desktopAppKitFrame: frame)
    }

    private func makeSprite(kind: GhostCursorKind) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.lineJoin = .round                        // "Modern" rounded joints
        shape.lineCap = .round
        // Subtle modern drop shadow so the cursor reads over any background.
        shape.shadowColor = CGColor(gray: 0, alpha: 1)
        shape.shadowOpacity = 0.35
        shape.shadowRadius = 1.5
        shape.shadowOffset = CGSize(width: 0, height: -1)
        configure(shape, kind: kind)
        shape.position = CGPoint(x: -9999, y: -9999)   // off-panel until first move
        return shape
    }

    /// Point the shape layer at one Bibata outline: real path, blue body + white
    /// "Ice" outline, and an `anchorPoint` placed at the cursor's hotspot so the
    /// layer's `position` is the logical cursor point regardless of which kind.
    private func configure(_ shape: CAShapeLayer, kind: GhostCursorKind) {
        let def = Self.shapes[kind] ?? Self.shapes[.arrow]!
        let box = Self.viewBox * Self.renderScale
        shape.bounds = CGRect(x: 0, y: 0, width: box, height: box)
        shape.anchorPoint = CGPoint(x: def.hotspot.x / Self.viewBox,
                                    y: (Self.viewBox - def.hotspot.y) / Self.viewBox)
        shape.path = Self.cgPath(fromSVG: def.d)
        shape.fillColor = Self.bibataBlue
        shape.strokeColor = Self.iceOutline
        shape.lineWidth = Self.strokeWidth256 * Self.renderScale
    }

    /// Minimal absolute-only SVG path → `CGPath`, scaling Bibata's 256 viewBox to
    /// on-screen points and flipping y (SVG top-left/y-down → CALayer bottom-left).
    /// Handles the M/L/H/V/C/Z commands the Bibata outlines use.
    private static func cgPath(fromSVG d: String) -> CGPath {
        let s = renderScale
        let path = CGMutablePath()
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (viewBox - y) * s) }
        let chars = Array(d)
        let n = chars.count
        var i = 0
        var cmd: Character = " "
        var cur = CGPoint.zero      // SVG coords
        var start = CGPoint.zero
        var firstM = false

        func skipSep() {
            while i < n, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        }
        func readNum() -> CGFloat? {
            skipSep()
            var str = ""
            if i < n, chars[i] == "-" || chars[i] == "+" { str.append(chars[i]); i += 1 }
            while i < n {
                let c = chars[i]
                if (c >= "0" && c <= "9") || c == "." { str.append(c); i += 1 } else { break }
            }
            return Double(str).map { CGFloat($0) }
        }

        while true {
            skipSep()
            if i >= n { break }
            let c = chars[i]
            if (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") {
                cmd = c; i += 1
                if cmd == "Z" || cmd == "z" { path.closeSubpath(); cur = start; continue }
                firstM = (cmd == "M" || cmd == "m")
            }
            switch cmd {
            case "M", "m":
                guard let x = readNum(), let y = readNum() else { i = n; break }
                cur = CGPoint(x: x, y: y)
                if firstM { path.move(to: P(x, y)); start = cur; firstM = false }
                else { path.addLine(to: P(x, y)) }
            case "L", "l":
                guard let x = readNum(), let y = readNum() else { i = n; break }
                cur = CGPoint(x: x, y: y); path.addLine(to: P(x, y))
            case "H", "h":
                guard let x = readNum() else { i = n; break }
                cur.x = x; path.addLine(to: P(cur.x, cur.y))
            case "V", "v":
                guard let y = readNum() else { i = n; break }
                cur.y = y; path.addLine(to: P(cur.x, cur.y))
            case "C", "c":
                guard let x1 = readNum(), let y1 = readNum(), let x2 = readNum(),
                      let y2 = readNum(), let x = readNum(), let y = readNum() else { i = n; break }
                path.addCurve(to: P(x, y), control1: P(x1, y1), control2: P(x2, y2))
                cur = CGPoint(x: x, y: y)
            default:
                i += 1   // unknown command char → skip to avoid an infinite loop
            }
        }
        return path
    }

    /// Test-only accessor: the single shared cursor panel (nil until first show).
    /// `windowId` is ignored. Must be called on the main thread.
    internal func panelForTesting(windowId: Int) -> NSPanel? {
        shared?.panel
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
#endif
