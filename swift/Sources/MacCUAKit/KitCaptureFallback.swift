// KitCaptureFallback.swift — private GPU capture fallback + cache plumbing (B3/B2, US-024).
//
// B3: when SCK is unavailable (or returns nil), fall back to the private window-
// server one-shot `CGSHWCaptureWindowList`. Per-symbol-optional via dlsym — nil
// when the symbol is gone (macOS-26 SPI-removal resilience), in which case capture
// fails honestly (returns nil) and NEVER foregrounds. SkyLight/CGS needs no
// entitlement. The fallback is a pure read of the window's backing store — no
// activation, no cursor.
//
// B2: display-config reconfiguration invalidates the whole `filterCache` so a
// stale SCContentFilter is never reused after the layout changes.

#if os(macOS)
import Foundation
import MacCUACore
import CoreGraphics

// MARK: - Private CoreGraphicsServices (CGS) capture SPI (per-symbol-optional)

/// `CGSHWCaptureWindowList(CGSConnectionID, CGWindowID *list, int count, UInt32 opts)
/// -> CFArrayRef of CGImageRef` — private hardware-composited one-shot capture of a
/// window's backing store, occlusion-independent. Resolved once via
/// `dlsym(RTLD_DEFAULT,…)`; nil when unavailable. Resolving does not call it.
enum CapturePrivateSPI {
    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias HWCaptureFn = @convention(c) (
        Int32, UnsafePointer<CGWindowID>, Int32, UInt32
    ) -> Unmanaged<CFArray>?

    // Capture options: nominal resolution + ignore global clip shape so an
    // occluded/clipped window still yields its full backing store.
    static let optionNominalResolution: UInt32 = 0x0200
    static let optionIgnoreGlobalClipShape: UInt32 = 0x0800

    static let mainConnectionID: MainConnectionFn? = {
        // RTLD_DEFAULT searches all loaded images.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: MainConnectionFn.self)
    }()

    static let hwCaptureWindowList: HWCaptureFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSHWCaptureWindowList") else { return nil }
        return unsafeBitCast(sym, to: HWCaptureFn.self)
    }()

    /// True only when BOTH symbols resolved — i.e. the fallback can actually run.
    static var isAvailable: Bool { mainConnectionID != nil && hwCaptureWindowList != nil }
}

extension KitCaptureProvider {
    // MARK: - B2: display-config invalidation

    /// Bump the whole filter cache on any display reconfiguration. Stored as a
    /// `@convention(c)` callback (cannot capture self) — `self` is threaded through
    /// the userInfo pointer.
    func registerDisplayReconfigurationObserver() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, _, userInfo in
            guard let userInfo else { return }
            let provider = Unmanaged<KitCaptureProvider>.fromOpaque(userInfo).takeUnretainedValue()
            // Only the "configuration finished" pass matters, but invalidating on
            // any flag is cheap and safe (a re-resolve is one cold SCShareableContent).
            provider.filterCache.invalidateAll()
        }, ctx)
    }

    /// Live signature for window-replace detection (B2): owner pid + bounds + title.
    func currentSignature(windowId: Int) -> CapturedWindowSignature? {
        let (windows, _) = cgWindowList()
        guard let w = windows.first(where: { $0.windowId == windowId }) else { return nil }
        return CapturedWindowSignature(
            ownerPid: w.ownerPid,
            bounds: Rect(x: w.x, y: w.y, w: w.width, h: w.height),
            title: w.title
        )
    }

    // MARK: - B3: private GPU one-shot fallback

    /// Capture a single window via `CGSHWCaptureWindowList`. Returns nil when the
    /// SPI is unavailable or the call yields no image — the caller then fails
    /// honestly. Reads the backing store only; no activation, no cursor (Inv 13).
    func captureWindowPrivate(windowId: Int) -> CGImage? {
        guard let mainConn = CapturePrivateSPI.mainConnectionID,
              let hwCapture = CapturePrivateSPI.hwCaptureWindowList else {
            return nil
        }
        guard let widValue = CGWindowID(exactly: windowId) else { return nil }
        let cid = mainConn()
        var wid = widValue
        let opts = CapturePrivateSPI.optionNominalResolution
            | CapturePrivateSPI.optionIgnoreGlobalClipShape
        guard let arrayRef = withUnsafePointer(to: &wid, { ptr in
            hwCapture(cid, ptr, 1, opts)
        }) else { return nil }
        let array = arrayRef.takeRetainedValue() as NSArray
        guard let first = array.firstObject else { return nil }
        // Elements are CGImageRef; bridge defensively.
        let cf = first as CFTypeRef
        guard CFGetTypeID(cf) == CGImage.typeID else { return nil }
        let cg = unsafeBitCast(cf, to: CGImage.self)
        guard cg.width > 0, cg.height > 0 else { return nil }
        return cg
    }
}
#endif
