// KitWindowBinding.swift — bind an AX window to its CGWindowID (A4, US-020).
//
// PRIMARY: the private `_AXUIElementGetWindow` SPI (resolved per-symbol-optional
// in KitAccessibilityProvider via `AXPrivateSPI`). FALLBACK (symbol absent / no
// window): bounds+title scoring against the CGWindowList, via the pure
// `MacCUACore.WindowMatcher`. All reads — never foregrounds/raises (Inv 7/13).

#if os(macOS)
import Foundation
import MacCUACore
import ApplicationServices
import CoreGraphics

extension KitCaptureProvider {
    public func findWindowIdForAXWindow(pid: Int, axWindow: AXElementRef) -> Int? {
        // 1) Primary: direct AX→CGWindowID via private SPI.
        if let direct = directWindowId(axWindow) {
            return direct
        }
        // 2) Fallback: score the CGWindowList against the AX window's signature.
        let signature = axWindowSignature(axWindow)
        let (windows, layers) = cgWindowList()
        return WindowMatcher.bestMatch(
            windows: windows, layers: layers, signature: signature, pid: pid
        )
    }

    /// Private `_AXUIElementGetWindow` binding (nil when symbol absent / no window).
    func directWindowId(_ axWindow: AXElementRef) -> Int? {
        guard let el = (axWindow as? KitAXElementRef)?.element,
              let fn = AXPrivateSPI.getWindow else { return nil }
        var wid: CGWindowID = 0
        let err = fn(el, &wid)
        guard err == .success, wid != 0 else { return nil }
        return Int(wid)
    }

    /// Read the AX window's title + on-screen geometry for fallback matching.
    func axWindowSignature(_ axWindow: AXElementRef) -> AXWindowSignature {
        guard let el = (axWindow as? KitAXElementRef)?.element else {
            return AXWindowSignature()
        }
        var title: String? = nil
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef) == .success,
           let t = titleRef as? String {
            title = t
        }
        let position = copyAXPoint(el, kAXPositionAttribute as CFString, .cgPoint)
        let size = copyAXPoint(el, kAXSizeAttribute as CFString, .cgSize)
        return AXWindowSignature(title: title, position: position, size: size)
    }

    private func copyAXPoint(
        _ el: AXUIElement, _ attr: CFString, _ type: AXValueType
    ) -> Point? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &ref) == .success,
              let v = ref, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let value = v as! AXValue
        if type == .cgPoint {
            var p = CGPoint.zero
            return AXValueGetValue(value, .cgPoint, &p) ? Point(x: Double(p.x), y: Double(p.y)) : nil
        } else {
            var s = CGSize.zero
            return AXValueGetValue(value, .cgSize, &s) ? Point(x: Double(s.width), y: Double(s.height)) : nil
        }
    }

    /// Snapshot of on-screen windows from the window server (read-only).
    /// Returns (`WindowInfo`s, layer-by-window-id). Used only for the A4 fallback.
    func cgWindowList() -> ([WindowInfo], [Int: Int]) {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return ([], [:])
        }
        var windows: [WindowInfo] = []
        var layers: [Int: Int] = [:]
        for w in raw {
            guard let wid = (w[kCGWindowNumber as String] as? Int) else { continue }
            let ownerPid = (w[kCGWindowOwnerPID as String] as? Int) ?? 0
            let ownerName = w[kCGWindowOwnerName as String] as? String
            let name = w[kCGWindowName as String] as? String
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = (bounds["X"] as? Double) ?? 0
            let y = (bounds["Y"] as? Double) ?? 0
            let width = (bounds["Width"] as? Double) ?? 0
            let height = (bounds["Height"] as? Double) ?? 0
            layers[wid] = layer
            windows.append(WindowInfo(
                windowId: wid, ownerPid: ownerPid, ownerName: ownerName, title: name,
                x: x, y: y, width: width, height: height, onscreen: onscreen
            ))
        }
        return (windows, layers)
    }
}
#endif
