// CaptureGeometry.swift — pure sizing math for window capture (B1/B5, US-022).
//
// Linux-green: NO ScreenCaptureKit / CoreGraphics import. The macOS SCK capture
// path (KitCaptureProvider) feeds an SCStreamConfiguration's width/height from
// `CaptureSizing.outputPixelSize` and picks the backing (Retina) scale via
// `CaptureGeometry.backingScale` — both ported verbatim from
// screen_capture.py (`_capture_impl` sizing + `_get_backing_scale_for_rect`).

/// One display as the window server sees it, for backing-scale selection.
public struct ScreenInfo: Equatable, Sendable {
    /// Screen frame in screen points (top-left origin).
    public var frame: Rect
    /// `backingScaleFactor` (1.0 non-Retina, 2.0 Retina, etc.).
    public var backingScale: Double
    /// Whether this is the main screen (the `mainScreen` fallback tier).
    public var isMain: Bool

    public init(frame: Rect, backingScale: Double, isMain: Bool = false) {
        self.frame = frame
        self.backingScale = backingScale
        self.isMain = isMain
    }
}

public enum CaptureGeometry {
    /// Backing scale for the screen containing the most of `rect`.
    ///
    /// Ported from `_get_backing_scale_for_rect`: pick the screen with the
    /// greatest intersection area; if no screen overlaps, fall back to the main
    /// screen, then to `defaultScale` (2.0, the Retina default).
    public static func backingScale(
        forRect rect: Rect,
        screens: [ScreenInfo],
        defaultScale: Double = 2.0
    ) -> Double {
        var bestScale: Double? = nil
        var bestArea = 0.0
        for screen in screens {
            let area = intersectionArea(rect, screen.frame)
            if area > bestArea {
                bestArea = area
                bestScale = screen.backingScale
            }
        }
        if let s = bestScale { return s }
        if let main = screens.first(where: { $0.isMain }) { return main.backingScale }
        return defaultScale
    }

    /// Intersection area of two screen-point rects (0 when disjoint).
    static func intersectionArea(_ a: Rect, _ b: Rect) -> Double {
        let ix = max(a.x, b.x)
        let iy = max(a.y, b.y)
        let iw = min(a.x + a.w, b.x + b.w) - ix
        let ih = min(a.y + a.h, b.y + b.h) - iy
        guard iw > 0 && ih > 0 else { return 0 }
        return iw * ih
    }
}

public enum CaptureSizing {
    /// Output pixel dimensions for an SCK capture: the window's point size scaled
    /// to backing (Retina) resolution. Returns `nil` for an invalid (<= 0) size,
    /// matching screen_capture.py's "skip capture with invalid size" guard.
    public static func outputPixelSize(
        windowSize: Size,
        scale: Double
    ) -> (width: Int, height: Int)? {
        let w = Int(windowSize.w)
        let h = Int(windowSize.h)
        guard w > 0 && h > 0 else { return nil }
        return (width: Int(windowSize.w * scale), height: Int(windowSize.h * scale))
    }
}
