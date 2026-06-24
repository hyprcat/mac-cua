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
import AppKit
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
    let fnGetConnectionIDForPID: CSky_CGSGetConnectionIDForPID?
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
        self.fnGetConnectionIDForPID = cast(.CGSGetConnectionIDForPID, CSky_CGSGetConnectionIDForPID.self)
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

    // MARK: - Window-owner validation (US-029b; Invariant 19)

    /// Validate that `windowId` still belongs to `expectedPid`, deferring all
    /// branch logic to the pure `WindowOwnerValidator` (Core). Returns `true` on a
    /// match OR when validation cannot be performed (assume-valid) — never blocks.
    public func validateWindowOwner(windowId: UInt32, expectedPid: Int32) -> Bool {
        WindowOwnerValidator.validate(
            windowId: windowId, expectedPid: expectedPid, lookups: self
        )
    }

    // MARK: - Targeted mouse delivery (US-030; C2)

    /// Build an NSEvent-backed, SkyLight-stamped mouse event and post it to the
    /// background target pid — no cursor warp, no foregrounding.
    ///
    /// The event is created via `+[NSEvent mouseEventWithType:...windowNumber:...]`
    /// so the window server associates it with `windowId`; its `.cgEvent` is then
    /// stamped per `SkyLightMouseDelivery` (subtype 7=3, window hints 91/92=windowId,
    /// window-local coords via `CGEventSetWindowLocation`, target pid in field 40
    /// via `SLEventSetIntegerValueField`) and posted with `SLEventPostToPid`.
    ///
    /// Returns `false` (caller falls through to the CGEvent base path, US-028) when
    /// the SkyLight mouse capability is unavailable or any step fails — it NEVER
    /// foregrounds on failure (Inv 18).
    ///
    /// - Parameters:
    ///   - windowLocalPoint: the click point in the target window's coordinate
    ///     space (origin top-left, as the rest of the input layer uses).
    @discardableResult
    public func deliverMouse(
        pid: Int, windowId: Int,
        windowLocalPoint: CGPoint, type: CGEventType,
        button: CGMouseButton, clickCount: Int,
        pressure: Double, eventNumber: Int,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> Bool {
        guard capabilities.canDeliverMouse,
              let post = fnEventPostToPid,
              let setSkyInt = fnEventSetIntegerValueField,
              let setWindowLocation = fnEventSetWindowLocation else { return false }

        guard let nsType = Self.nsMouseType(for: type) else { return false }

        guard let nsEvent = NSEvent.mouseEvent(
            with: nsType, location: windowLocalPoint, modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowId,
            context: nil, eventNumber: eventNumber, clickCount: clickCount,
            pressure: Float(pressure)),
              let event = nsEvent.cgEvent else { return false }

        // For non-left buttons NSEvent encodes the button via the event type; make
        // the button number explicit so the routed event carries it.
        event.setIntegerValueField(
            CGEventField(rawValue: CGEventFieldNumber.mouseEventButtonNumber)!,
            value: Int64(button.rawValue))

        // Public CGEvent stamps: subtype=3 + window-association hints (91/92).
        for stamp in SkyLightMouseDelivery.cgStamps(windowId: windowId) {
            event.setIntegerValueField(
                CGEventField(rawValue: stamp.field)!, value: stamp.value)
        }

        // Window-local placement (SkyLight export) — routing metadata, not a warp.
        setWindowLocation(event, windowLocalPoint)

        // Private SkyLight stamp: target pid in field 40, then post to that pid.
        for stamp in SkyLightMouseDelivery.skyStamps(pid: pid) {
            setSkyInt(event, stamp.field, stamp.value)
        }
        post(Int32(pid), event)
        return true
    }

    /// Map a `CGEventType` to the AppKit `NSEvent.EventType` that
    /// `mouseEventWithType:` accepts. Non-mouse types return `nil`.
    private static func nsMouseType(for type: CGEventType) -> NSEvent.EventType? {
        switch type {
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .leftMouseDragged: return .leftMouseDragged
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .rightMouseDragged: return .rightMouseDragged
        case .otherMouseDown: return .otherMouseDown
        case .otherMouseUp: return .otherMouseUp
        case .otherMouseDragged: return .otherMouseDragged
        case .mouseMoved: return .mouseMoved
        default: return nil
        }
    }

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

/// Live SkyLight-backed owner lookups. Each method calls the resolved private
/// symbol and returns `nil` when the symbol is absent or the CGS call errored —
/// exactly the "cannot perform → assume valid" signal the pure validator expects.
extension KitSkyLightProvider: WindowOwnerLookups {
    public func windowOwnerConnectionId(windowId: UInt32) -> UInt32? {
        guard let fn = fnGetWindowOwner else { return nil }
        let cid = mainConnectionId
        guard cid != 0 else { return nil }
        var ownerCid: UInt32 = 0
        let err = fn(cid, windowId, &ownerCid)
        return err == 0 ? ownerCid : nil
    }

    public func connectionId(forPid pid: Int32) -> UInt32? {
        guard let fn = fnGetConnectionIDForPID else { return nil }  // removed in macOS 26
        let cid = mainConnectionId
        guard cid != 0 else { return nil }
        var out: UInt32 = 0
        let err = fn(cid, pid, &out)
        return err == 0 ? out : nil
    }

    public func pid(forConnectionId connectionId: UInt32) -> Int32? {
        guard let fn = fnConnectionGetPID else { return nil }
        var out: Int32 = 0
        let err = fn(connectionId, &out)
        return err == 0 ? out : nil
    }
}
#endif
