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
        var windowCGRect: Rect
        init(panel: NSPanel, sprite: CALayer, windowCGRect: Rect) {
            self.panel = panel
            self.sprite = sprite
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
            // Decorative move: reposition the sprite layer only — no cursor warp.
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            entry.sprite.position = CGPoint(x: local.x, y: local.y)
            CATransaction.commit()
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

        let sprite = makeSprite(style: style)
        host.layer?.addSublayer(sprite)

        return Entry(panel: panel, sprite: sprite, windowCGRect: windowCGRect)
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
