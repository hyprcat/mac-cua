// KitSkyLightProvider — the real dlsym-backed SkyLight symbol surface (US-029).
//
// This is the macOS half of the optional-resolution story: it resolves each
// private symbol via the C shim's `csky_resolve_symbol` (dlopen+dlsym), holds
// the live function pointers, and exposes them to US-030 (mouse) / US-031
// (keyboard) / US-029b (window-owner validation). The pure branch logic — which
// capability is enabled given which symbols resolved, and `isAvailable` — lives
// in `MacCUACore.SkyLightAvailability` and is Linux-tested with a fake loader.
//
// Prime-Invariant posture: every symbol is OPTIONAL. A missing one is `nil`; the
// callers consult `capabilities.canDeliverMouse/Keyboard` and fall through to the
// CGEvent base path (US-028) — they never foreground (Invariant 17/18). We never
// declare the forbidden `SetFrontmost` / `SLPSSetFrontProcessWithOptions`
// symbols, so the foregrounding path is unreachable by construction.

#if os(macOS)
import Foundation
import CoreGraphics
import MacCUACore
import CSkyLightShim
import ObjectiveC.runtime

/// `SkyLightSymbolLoader` backed by the C shim's dlsym resolver. Resolves by the
/// symbol's `rawValue` (which IS the exact C symbol name).
public final class DlsymSkyLightLoader: SkyLightSymbolLoader {
    public init() {}
    public func resolve(_ symbol: SkyLightSymbol) -> UnsafeMutableRawPointer? {
        symbol.rawValue.withCString { csky_resolve_symbol($0) }
    }
}

public final class KitSkyLightProvider: SkyLightProviding {
    private let loader: SkyLightSymbolLoader

    // Resolved function pointers (nil = absent). Kept as the C typedefs so the
    // call sites in US-030/031 are a direct invocation with no further casting.
    let fnMainConnectionID: CSky_CGSMainConnectionID?
    let fnGetWindowOwner: CSky_SLSGetWindowOwner?
    let fnGetConnectionPSN: CSky_SLSGetConnectionPSN?
    let fnConnectionGetPID: CSky_CGSConnectionGetPID?
    let fnEventPostToPid: CSky_SLEventPostToPid?
    let fnEventSetIntegerValueField: CSky_SLEventSetIntegerValueField?
    let fnEventSetAuthenticationMessage: CSky_SLEventSetAuthenticationMessage?
    let fnEventSetWindowLocation: CSky_CGEventSetWindowLocation?
    let fnEventPostToPSN: CSky_CGEventPostToPSN?

    /// The ObjC class backing the authenticated-keyboard message
    /// (`+[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:]`).
    /// Resolved via the ObjC runtime, not dlsym, since it is a class not a C fn.
    let authMessageClass: AnyClass?

    public init(loader: SkyLightSymbolLoader = DlsymSkyLightLoader()) {
        self.loader = loader
        func cast<T>(_ symbol: SkyLightSymbol, _ type: T.Type) -> T? {
            guard let raw = loader.resolve(symbol) else { return nil }
            return unsafeBitCast(raw, to: T.self)
        }
        self.fnMainConnectionID = cast(.CGSMainConnectionID, CSky_CGSMainConnectionID.self)
        self.fnGetWindowOwner = cast(.SLSGetWindowOwner, CSky_SLSGetWindowOwner.self)
        self.fnGetConnectionPSN = cast(.SLSGetConnectionPSN, CSky_SLSGetConnectionPSN.self)
        self.fnConnectionGetPID = cast(.CGSConnectionGetPID, CSky_CGSConnectionGetPID.self)
        self.fnEventPostToPid = cast(.SLEventPostToPid, CSky_SLEventPostToPid.self)
        self.fnEventSetIntegerValueField = cast(.SLEventSetIntegerValueField, CSky_SLEventSetIntegerValueField.self)
        self.fnEventSetAuthenticationMessage = cast(.SLEventSetAuthenticationMessage, CSky_SLEventSetAuthenticationMessage.self)
        self.fnEventSetWindowLocation = cast(.CGEventSetWindowLocation, CSky_CGEventSetWindowLocation.self)
        self.fnEventPostToPSN = cast(.CGEventPostToPSN, CSky_CGEventPostToPSN.self)
        self.authMessageClass = NSClassFromString("SLSEventAuthenticationMessage")
    }

    /// Our window-server main connection id (0 when unavailable). Calls the live
    /// `CGSMainConnectionID` each time so it tracks the dynamic availability the
    /// acceptance requires.
    public var mainConnectionId: UInt32 {
        fnMainConnectionID?() ?? 0
    }

    /// DYNAMIC — recomputed on every read so the value is test-patchable and
    /// reflects a host where the SPIs are absent / removed (macOS 26).
    public var capabilities: SkyLightCapabilities {
        SkyLightAvailability.evaluate(loader: loader, mainConnectionIdProvider: { [fnMainConnectionID] in
            fnMainConnectionID?() ?? 0
        })
    }

    public var isAvailable: Bool { capabilities.isAvailable }

    #if DEBUG
    /// For the MANUAL-VERIFY pass: which symbols resolved on this host.
    public func resolvedSymbolReport() -> [String: Bool] {
        var report: [String: Bool] = [:]
        for symbol in SkyLightSymbol.allCases {
            report[symbol.rawValue] = loader.resolve(symbol) != nil
        }
        report["SLSEventAuthenticationMessage(ObjC)"] = authMessageClass != nil
        report["mainConnectionId!=0"] = mainConnectionId != 0
        return report
    }
    #endif
}
#endif
