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
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }

    public func pngBase64() -> String {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return "" }
        CGImageDestinationAddImage(dest, cgImage, nil)
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
        guard let target = shareableWindow(windowId: windowId, pid: pid) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        // Backing-resolution sizing via the pure Core math (invalid size => skip).
        let frame = target.frame
        let scale = backingScale(for: frame)
        if let size = CaptureSizing.outputPixelSize(
            windowSize: Size(w: Double(frame.width), h: Double(frame.height)),
            scale: scale
        ) {
            config.width = size.width
            config.height = size.height
        } else {
            return nil // invalid (<=0) window size
        }
        config.showsCursor = includeCursor // Inv 13: false on the primary path
        guard let cg = captureImageSync(filter: filter, config: config),
              cg.width > 0, cg.height > 0 else { return nil }
        return KitCapturedImage(cg)
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
