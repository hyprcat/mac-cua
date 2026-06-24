// US-051 — GhostCursorOverlay AppKit impl: non-activating panel per window (§7.2).
//
// The decorative payoff layer. For each driven window we create ONE borderless,
// transparent, click-through, NON-ACTIVATING `NSPanel` whose frame == the target
// window's screen rect, hosting a CALayer "sprite" tinted per session. The sprite
// is clamped to the window rect so the ghost can never paint over another app.
//
// HARD RULE (Prime Invariant): decorative ONLY. This never routes through the
// system cursor, never warps it, never foregrounds/activates/raises anything:
//   - `.nonactivatingPanel` style + `canBecomeKey/Main = false` → ordering the
//     panel in NEVER steals key/main from the user's app.
//   - `ignoresMouseEvents = true` → clicks pass THROUGH to the underlying app.
//   - `orderFrontRegardless()` shows without activating our process.
// There is no system-cursor or activation API touched anywhere in this file.
//
// All coordinate math (CG-global top-left → AppKit bottom-left) lives in the pure,
// Linux-tested `GhostCursorGeometry`. This file owns only the AppKit objects and
// their lifecycle. Window-follow/animation/occlusion are later stories
// (US-052/054/055); this story renders a static, correctly-placed sprite.

#if os(macOS)
import Foundation
import AppKit
import QuartzCore
import MacCUACore

/// Real `GhostCursorOverlay`: one non-activating `NSPanel` per `windowId`.
/// Must be used on the main thread (AppKit requirement) — call sites hop to main.
public final class KitGhostCursorOverlay: GhostCursorOverlay {
    /// Sprite diameter in points.
    public static let spriteSize: CGFloat = 22

    private final class Entry {
        let panel: NSPanel
        let sprite: CALayer
        /// Reusable click-ripple ring (kept at opacity 0 between pulses → no
        /// per-click layer churn / no cross-isolation layer capture).
        let ripple: CALayer
        /// Reusable element-highlight outline (opacity 0 when idle).
        let highlightLayer: CALayer
        var windowCGRect: Rect
        var thinking = false
        init(panel: NSPanel, sprite: CALayer, ripple: CALayer,
             highlightLayer: CALayer, windowCGRect: Rect) {
            self.panel = panel
            self.sprite = sprite
            self.ripple = ripple
            self.highlightLayer = highlightLayer
            self.windowCGRect = windowCGRect
        }
    }

    private var entries: [Int: Entry] = [:]

    public init() {}

    /// Height of the primary display — the AppKit y-flip reference. The primary
    /// screen is `NSScreen.screens.first` (the one containing the menu bar / origin).
    private var primaryScreenHeight: Double {
        Double(NSScreen.screens.first?.frame.height ?? 0)
    }

    // MARK: - GhostCursorOverlay

    public func show(windowId: Int, style: GhostCursorStyle, windowFrame: Rect?) {
        onMain {
            if let existing = self.entries[windowId] {
                self.applyStyle(style, to: existing.sprite)
                if let windowFrame { self.position(existing, toCGRect: windowFrame) }
                return
            }
            guard let windowFrame else {
                // No frame yet → defer panel creation until setWindowFrame/move
                // supplies one. (Off-screen windows simply have no ghost.)
                return
            }
            let entry = self.makePanel(style: style, windowCGRect: windowFrame)
            self.entries[windowId] = entry
            entry.panel.orderFrontRegardless()
        }
    }

    public func move(windowId: Int, to point: Point, animated: Bool) {
        onMain {
            guard let entry = self.entries[windowId] else { return }
            let clamped = GhostCursorController.clampPointToWindow(point, entry.windowCGRect)
            let local = GhostCursorGeometry.spritePointInPanel(screenPoint: clamped,
                                                               windowCGRect: entry.windowCGRect)
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
                let anim = CAKeyframeAnimation(keyPath: "position")
                anim.path = path
                anim.duration = GhostAnimationParams.scootDuration
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
            guard let entry = self.entries[windowId] else { return }
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
            guard let entry = self.entries[windowId] else { return }
            // Convert the CG-global element rect into the panel's local space using
            // the same y-flip as the sprite point conversion (top-left → bottom-left).
            let cg = entry.windowCGRect
            let localX = bounds.x - cg.x
            let localY = cg.h - (bounds.y - cg.y) - bounds.h
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            entry.highlightLayer.frame = CGRect(x: localX, y: localY, width: bounds.w, height: bounds.h)
            entry.highlightLayer.borderColor = entry.sprite.borderColor
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
            guard let entry = self.entries[windowId] else { return }
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

    public func setClipRegion(windowId: Int, region: [Rect]) {
        onMain {
            guard let entry = self.entries[windowId] else { return }
            // Empty region = fully occluded → hide (keep the entry for a later show).
            if region.isEmpty {
                entry.panel.orderOut(nil)
                return
            }
            // Build a mask layer covering the still-visible rectilinear region in
            // the panel's local (bottom-left) coordinate space, then re-show.
            let cg = entry.windowCGRect
            let path = CGMutablePath()
            for r in region {
                let localX = r.x - cg.x
                let localY = cg.h - (r.y - cg.y) - r.h   // top-left CG → bottom-left local
                path.addRect(CGRect(x: localX, y: localY, width: r.w, height: r.h))
            }
            let mask: CAShapeLayer
            if let existing = entry.panel.contentView?.layer?.mask as? CAShapeLayer {
                mask = existing
            } else {
                mask = CAShapeLayer()
                entry.panel.contentView?.layer?.mask = mask
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = path
            CATransaction.commit()
            entry.panel.orderFrontRegardless()
        }
    }

    public func setWindowFrame(windowId: Int, _ frame: Rect?) {
        onMain {
            guard let entry = self.entries[windowId] else { return }
            if let frame {
                self.position(entry, toCGRect: frame)
                entry.panel.orderFrontRegardless()
            } else {
                entry.panel.orderOut(nil) // off-screen/minimized → hide, keep entry
            }
        }
    }

    public func hide(windowId: Int) {
        onMain { self.entries[windowId]?.panel.orderOut(nil) }
    }

    public func remove(windowId: Int) {
        onMain {
            guard let entry = self.entries.removeValue(forKey: windowId) else { return }
            entry.panel.orderOut(nil)
        }
    }

    // MARK: - Panel construction

    private func makePanel(style: GhostCursorStyle, windowCGRect: Rect) -> Entry {
        let frame = GhostCursorGeometry.appKitFrame(forCGRect: windowCGRect,
                                                    primaryScreenHeight: primaryScreenHeight)
        let panel = NSPanel(
            contentRect: NSRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h),
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

        let host = NSView(frame: NSRect(x: 0, y: 0, width: frame.w, height: frame.h))
        host.wantsLayer = true
        host.layer?.masksToBounds = true               // clip sprite to window rect (§7.2)
        panel.contentView = host

        let s = Self.spriteSize
        // Reusable click-ripple ring (kept invisible between pulses).
        let ripple = CALayer()
        ripple.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        ripple.cornerRadius = s / 2
        ripple.position = CGPoint(x: -s, y: -s)
        ripple.backgroundColor = CGColor(gray: 1, alpha: 0)
        ripple.borderColor = CGColor(red: style.red, green: style.green, blue: style.blue, alpha: style.alpha)
        ripple.borderWidth = 2
        ripple.opacity = 0
        host.layer?.addSublayer(ripple)

        // Reusable element-highlight outline (kept invisible until highlight()).
        let highlightLayer = CALayer()
        highlightLayer.cornerRadius = 4
        highlightLayer.borderColor = ripple.borderColor
        highlightLayer.borderWidth = 2
        highlightLayer.backgroundColor = CGColor(gray: 1, alpha: 0)
        highlightLayer.opacity = 0
        host.layer?.addSublayer(highlightLayer)

        let sprite = makeSprite(style: style)
        host.layer?.addSublayer(sprite)

        return Entry(panel: panel, sprite: sprite, ripple: ripple,
                     highlightLayer: highlightLayer, windowCGRect: windowCGRect)
    }

    private func makeSprite(style: GhostCursorStyle) -> CALayer {
        let s = Self.spriteSize
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        layer.cornerRadius = s / 2
        layer.position = CGPoint(x: -s, y: -s)         // off-panel until first move
        applyStyle(style, to: layer)
        return layer
    }

    private func applyStyle(_ style: GhostCursorStyle, to layer: CALayer) {
        layer.backgroundColor = CGColor(red: style.red, green: style.green,
                                        blue: style.blue, alpha: style.alpha)
        layer.borderColor = CGColor(red: 1, green: 1, blue: 1, alpha: min(1.0, style.alpha + 0.2))
        layer.borderWidth = 1.5
    }

    private func position(_ entry: Entry, toCGRect cg: Rect) {
        entry.windowCGRect = cg
        let frame = GhostCursorGeometry.appKitFrame(forCGRect: cg,
                                                    primaryScreenHeight: primaryScreenHeight)
        entry.panel.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h),
                             display: false)
        entry.panel.contentView?.frame = NSRect(x: 0, y: 0, width: frame.w, height: frame.h)
    }

    /// Test-only accessor: the panel currently backing a windowId (nil if none).
    /// Must be called on the main thread.
    internal func panelForTesting(windowId: Int) -> NSPanel? {
        entries[windowId]?.panel
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }
}
#endif
