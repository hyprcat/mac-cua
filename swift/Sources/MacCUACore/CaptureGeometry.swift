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

// MARK: - Capture-time downscale (B6) + metadata (B4) — US-023

/// Pure downscale math for the transport image. Ported in spirit from
/// screenshot.py `prepare_image_for_transport` (cap the longest side, preserve
/// aspect) — but expressed as the cap to feed the *GPU* path
/// (`SCStreamConfiguration.width/height` + `scalesToFit`) and the ImageIO encode
/// (`kCGImageDestinationImageMaxPixelSize`), so we never shell out to
/// `screencapture`/`sips` and never resample a full-res bitmap on the CPU.
///
/// The Python reference clamps `width`; ImageIO's max-pixel-size clamps the
/// *longest side*. For the landscape windows we capture these coincide; for the
/// rare tall window we prefer the longest-side semantics ImageIO actually
/// implements so the transport image never exceeds `maxDimension` in either axis.
public enum CaptureDownscale {
    /// Default longest-side cap (matches screenshot.py `max_width = 1920`).
    public static let defaultMaxDimension = 1920

    /// `true` when an image of `width`×`height` exceeds the cap and must shrink.
    public static func needsDownscale(
        width: Int, height: Int, maxDimension: Int = defaultMaxDimension
    ) -> Bool {
        guard maxDimension > 0 else { return false }
        return max(width, height) > maxDimension
    }

    /// Value to pass as `kCGImageDestinationImageMaxPixelSize`, or `nil` when the
    /// image already fits (encode at native size — no resample).
    public static func maxPixelSize(
        width: Int, height: Int, maxDimension: Int = defaultMaxDimension
    ) -> Int? {
        guard needsDownscale(width: width, height: height, maxDimension: maxDimension)
        else { return nil }
        return maxDimension
    }

    /// Final transport pixel dimensions after clamping the longest side to
    /// `maxDimension` with aspect preserved. Returns the input unchanged when it
    /// already fits or when either dimension is invalid (<= 0).
    public static func scaledSize(
        width: Int, height: Int, maxDimension: Int = defaultMaxDimension
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0,
              needsDownscale(width: width, height: height, maxDimension: maxDimension)
        else { return (width, height) }
        let longest = Double(max(width, height))
        let ratio = Double(maxDimension) / longest
        let w = max(1, Int((Double(width) * ratio).rounded(.toNearestOrAwayFromZero)))
        let h = max(1, Int((Double(height) * ratio).rounded(.toNearestOrAwayFromZero)))
        return (w, h)
    }
}

/// What frame the model is reasoning over (B4). Attached to a `CapturedImage` so
/// the spine can surface exact produced dims, the backing factor, the window's
/// on-screen crop origin, and the window/display identity.
public struct CaptureMetadata: Equatable, Sendable {
    /// Produced (post-downscale) pixel dimensions of the transport image.
    public var producedWidth: Int
    public var producedHeight: Int
    /// Backing (Retina) scale of the screen the window is mostly on.
    public var backingScale: Double
    /// The window's top-left in screen points (the crop origin of the capture).
    public var cropOrigin: Point
    /// CGWindowID of the captured window.
    public var windowId: Int
    /// Window title at capture time, when known.
    public var windowTitle: String?
    /// CGDirectDisplayID the window is mostly on, when resolvable.
    public var displayId: Int?

    public init(
        producedWidth: Int,
        producedHeight: Int,
        backingScale: Double,
        cropOrigin: Point,
        windowId: Int,
        windowTitle: String? = nil,
        displayId: Int? = nil
    ) {
        self.producedWidth = producedWidth
        self.producedHeight = producedHeight
        self.backingScale = backingScale
        self.cropOrigin = cropOrigin
        self.windowId = windowId
        self.windowTitle = windowTitle
        self.displayId = displayId
    }
}
