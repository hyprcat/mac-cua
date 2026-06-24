// KitCaptureProvider.swift — occluded single-window capture (B1/B5, US-022; Inv 13).
//
// Pipeline (ported from screen_capture.py `ScreenCapturer._capture_impl`):
//   SCShareableContent  -> find the target SCWindow by id (+pid)
//   SCContentFilter(desktopIndependentWindow:)  -> the window's own backing store
//   SCStreamConfiguration  -> backing-resolution px size (CaptureSizing), showsCursor=false
//   SCScreenshotManager.captureImage  -> a CGImage of the window, even when occluded.
//
// Captures background/occluded windows with NO activation and NO user cursor
// (Inv 13). CGWindowListCreateImage is NOT used (it returns NULL on macOS 26);
// the private CGSHWCaptureWindowList fallback is US-024.
//
// listWindows/getWindowBounds/getWindowPid are read-only CGWindowList snapshots
// (the SCK pipeline needs the owning pid to disambiguate the SCWindow).

#if os(macOS)
import Foundation
import MacCUACore
import CoreGraphics
import ImageIO
import AppKit
import ScreenCaptureKit

/// Real captured-window image: wraps a `CGImage`, encodes PNG via ImageIO.
public final class KitCapturedImage: CapturedImage {
    let cgImage: CGImage
    /// Longest-side cap applied at encode via `kCGImageDestinationImageMaxPixelSize`
    /// (belt-and-suspenders for the GPU `scalesToFit` downscale). `nil` = native.
    let maxPixelSize: Int?
    public let captureMetadata: CaptureMetadata?

    public init(_ cgImage: CGImage, maxPixelSize: Int? = nil, metadata: CaptureMetadata? = nil) {
        self.cgImage = cgImage
        self.maxPixelSize = maxPixelSize
        self.captureMetadata = metadata
    }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }

    public func pngBase64() -> String {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return "" }
        // ImageIO capture-time downscale: clamp the longest side without ever
        // shelling out to `screencapture`/`sips` or CPU-resampling ourselves.
        var props: [CFString: Any] = [:]
        if let cap = maxPixelSize {
            props[kCGImageDestinationImageMaxPixelSize] = cap
        }
        CGImageDestinationAddImage(dest, cgImage, props.isEmpty ? nil : props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return "" }
        return (data as Data).base64EncodedString()
    }
}

extension KitCaptureProvider {
    // MARK: - Window metadata (read-only window-server snapshot)

    public func listWindows(ownerPid: Int?) -> [WindowInfo] {
        let (windows, _) = cgWindowList()
        guard let pid = ownerPid else { return windows }
        return windows.filter { $0.ownerPid == pid }
    }

    public func getWindowBounds(windowId: Int) -> Rect? {
        let (windows, _) = cgWindowList()
        guard let w = windows.first(where: { $0.windowId == windowId }) else { return nil }
        return Rect(x: w.x, y: w.y, w: w.width, h: w.height)
    }

    public func getWindowPid(windowId: Int) -> Int? {
        let (windows, _) = cgWindowList()
        return windows.first(where: { $0.windowId == windowId })?.ownerPid
    }

    // MARK: - Capture

    public func captureWindow(windowId: Int, includeCursor: Bool) throws -> CapturedImage? {
        guard #available(macOS 12.3, *) else { return nil }
        let pid = getWindowPid(windowId: windowId)
        // B2: reuse a cached SCContentFilter when the window's live signature still
        // matches (window-replace guard); only re-resolve (the ~80–200 ms cold
        // SCShareableContent discovery) on a miss.
        let signature = currentSignature(windowId: windowId)
        let cachedFilter: SCContentFilter? = signature.flatMap {
            filterCache.value(forWindowId: windowId, signature: $0) as? SCContentFilter
        }
        let target: SCWindow?
        let filter: SCContentFilter
        if let cachedFilter {
            filter = cachedFilter
            target = shareableWindow(windowId: windowId, pid: pid)
        } else {
            guard let resolved = shareableWindow(windowId: windowId, pid: pid) else {
                // SCK shareable-content unavailable: try the private GPU fallback.
                return privateFallbackImage(windowId: windowId, signature: signature)
            }
            target = resolved
            filter = SCContentFilter(desktopIndependentWindow: resolved)
            if let signature {
                filterCache.store(filter, forWindowId: windowId, signature: signature)
            }
        }
        // Sizing/metadata needs the live SCWindow frame; if we only had a cached
        // filter and the window vanished, fail honestly.
        guard let target else { return nil }
        let config = SCStreamConfiguration()
        // Backing-resolution sizing via the pure Core math (invalid size => skip).
        let frame = target.frame
        let scale = backingScale(for: frame)
        guard let backingSize = CaptureSizing.outputPixelSize(
            windowSize: Size(w: Double(frame.width), h: Double(frame.height)),
            scale: scale
        ) else {
            return nil // invalid (<=0) window size
        }
        // GPU capture-time downscale: clamp the longest side at the source so the
        // window server rasterizes straight to transport size (scalesToFit keeps
        // aspect). The ImageIO maxPixelSize below is a second guard at encode.
        let scaled = CaptureDownscale.scaledSize(
            width: backingSize.width, height: backingSize.height
        )
        config.width = scaled.width
        config.height = scaled.height
        config.scalesToFit = true
        config.showsCursor = includeCursor // Inv 13: false on the primary path
        guard let cg = captureImageSync(filter: filter, config: config),
              cg.width > 0, cg.height > 0 else {
            // SCK capture returned nil: the filter may be stale (window replaced
            // under a recycled id) — drop it and try the private GPU fallback.
            filterCache.invalidate(windowId: windowId)
            return privateFallbackImage(windowId: windowId, signature: signature)
        }
        let maxPixel = CaptureDownscale.maxPixelSize(
            width: cg.width, height: cg.height
        )
        let metadata = CaptureMetadata(
            producedWidth: cg.width,
            producedHeight: cg.height,
            backingScale: scale,
            cropOrigin: Point(x: Double(frame.origin.x), y: Double(frame.origin.y)),
            windowId: windowId,
            windowTitle: target.title,
            displayId: displayId(for: frame)
        )
        return KitCapturedImage(cg, maxPixelSize: maxPixel, metadata: metadata)
    }

    /// B3 fallback wrapper: capture via the private one-shot SPI and wrap the
    /// result with downscale + metadata. Returns nil when the SPI is unavailable
    /// or yields nothing — caller fails honestly (never foregrounds).
    private func privateFallbackImage(
        windowId: Int, signature: CapturedWindowSignature?
    ) -> CapturedImage? {
        guard let cg = captureWindowPrivate(windowId: windowId) else { return nil }
        let maxPixel = CaptureDownscale.maxPixelSize(width: cg.width, height: cg.height)
        let bounds = signature?.bounds
        let frame = bounds.map {
            CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)
        } ?? CGRect(x: 0, y: 0, width: Double(cg.width), height: Double(cg.height))
        let metadata = CaptureMetadata(
            producedWidth: cg.width,
            producedHeight: cg.height,
            backingScale: backingScale(for: frame),
            cropOrigin: Point(x: frame.origin.x, y: frame.origin.y),
            windowId: windowId,
            windowTitle: nil,
            displayId: displayId(for: frame)
        )
        return KitCapturedImage(cg, maxPixelSize: maxPixel, metadata: metadata)
    }

    /// CGDirectDisplayID of the screen the window is mostly on (B4 metadata).
    private func displayId(for frame: CGRect) -> Int? {
        var best: Int? = nil
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let inter = screen.frame.intersection(frame)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea,
               let num = screen.deviceDescription[
                   NSDeviceDescriptionKey("NSScreenNumber")
               ] as? NSNumber {
                bestArea = area
                best = num.intValue
            }
        }
        return best
    }

    // MARK: - SCK helpers (synchronous wrappers around the async API)

    /// Box so the completion handler mutates a reference, not a captured var
    /// (avoids the Sendable-closure-captures warning under strict concurrency).
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    @available(macOS 12.3, *)
    private func shareableWindow(windowId: Int, pid: Int?) -> SCWindow? {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<[SCWindow]>([])
        SCShareableContent.getExcludingDesktopWindows(
            true, onScreenWindowsOnly: true
        ) { content, _ in
            box.value = content?.windows ?? []
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        let windows = box.value
        // Match by id+pid first; fall back to id only (matches screen_capture.py).
        if let pid = pid,
           let w = windows.first(where: {
               Int($0.windowID) == windowId
                   && ($0.owningApplication?.processID).map { Int($0) == pid } == true
           }) {
            return w
        }
        return windows.first(where: { Int($0.windowID) == windowId })
    }

    @available(macOS 12.3, *)
    private func captureImageSync(
        filter: SCContentFilter, config: SCStreamConfiguration
    ) -> CGImage? {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<CGImage?>(nil)
        SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        ) { cg, _ in
            box.value = cg
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3.0)
        return box.value
    }

    /// Backing (Retina) scale for the screen containing most of `frame`, via the
    /// pure Core selector fed with the current NSScreen layout.
    private func backingScale(for frame: CGRect) -> Double {
        let screens: [ScreenInfo] = NSScreen.screens.map {
            ScreenInfo(
                frame: Rect(x: Double($0.frame.origin.x), y: Double($0.frame.origin.y),
                            w: Double($0.frame.width), h: Double($0.frame.height)),
                backingScale: Double($0.backingScaleFactor),
                isMain: $0 == NSScreen.main
            )
        }
        let rect = Rect(x: Double(frame.origin.x), y: Double(frame.origin.y),
                        w: Double(frame.width), h: Double(frame.height))
        return CaptureGeometry.backingScale(forRect: rect, screens: screens)
    }
}
#endif
