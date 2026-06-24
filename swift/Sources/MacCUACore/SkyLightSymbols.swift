// SkyLight private-SPI symbol surface + optional-resolution branch logic (US-029).
//
// The background-input path (US-030 mouse, US-031 keyboard, US-029b window-owner
// validation) needs a handful of private SkyLight / CoreGraphics-Server symbols.
// Each one is resolved INDIVIDUALLY at runtime (dlopen+dlsym in Kit): a missing
// symbol is simply absent — never a hard link dependency, never a crash, never a
// foregrounding trigger (Invariant 17). This file holds the PURE, Linux-testable
// half of that: the catalogue of symbols and the decision logic that turns a set
// of "which symbols resolved" into capability flags + `isAvailable`.
//
// The real dlsym loader and the `@convention(c)` call sites live in MacCUAKit
// (KitSkyLightProvider.swift) behind `#if os(macOS)`; here we only model
// resolution as an injectable seam so the branch logic is fake-tested on Linux.
//
// Mirrors `app/_lib/skylight.py`'s "resolve each symbol, set missing ones to
// None, `is_available()` = framework loaded AND main connection != 0" — but we
// DELIBERATELY DO NOT port `micro_activate` / `_set_frontmost`
// (`CGSSetConnectionProperty "SetFrontmost"`): that is forbidden by the Prime
// Invariant (Invariant 18). The targeted-delivery family below replaces the
// macOS-26-removed `CGSPost*EventToProcess` SPIs.

/// Every private symbol the SkyLight provider may resolve. The `rawValue` is the
/// EXACT C symbol name, so the Kit dlsym loader can resolve it by
/// `symbol.rawValue` with no separate name table to drift out of sync.
public enum SkyLightSymbol: String, CaseIterable, Sendable {
    // Stable / lookup symbols.
    case CGSMainConnectionID            // uint32_t CGSMainConnectionID(void)
    case SLSGetWindowOwner              // int32_t (cid, wid, uint32_t *ownerCidOut)
    case SLSGetConnectionPSN            // int32_t (cid, ProcessSerialNumber *psnOut)
    case CGSConnectionGetPID            // int32_t (cid, int32_t *pidOut)  — macOS 26+ reverse lookup
    // Targeted-delivery symbols.
    case SLEventPostToPid               // void (int32_t pid, CGEventRef e)
    case SLEventSetIntegerValueField    // void (CGEventRef e, uint32_t field, int64_t v) — field 40 = pid
    case SLEventSetAuthenticationMessage // void (CGEventRef e, id message)
    case CGEventSetWindowLocation       // void (CGEventRef e, CGPoint p) — a SkyLight export, not CoreGraphics
    case CGEventPostToPSN               // void (ProcessSerialNumber *psn, CGEventRef e)
}

/// Injectable resolver seam. Kit implements this with dlopen+dlsym; tests inject
/// a fake that "resolves" a fixed set of symbols. Returning a non-nil opaque
/// pointer means the symbol is present; `nil` means absent (fall through).
public protocol SkyLightSymbolLoader {
    func resolve(_ symbol: SkyLightSymbol) -> UnsafeMutableRawPointer?
}

/// The outcome of resolving the symbol surface: which symbols are present plus
/// our process's window-server main connection id. All capability decisions are
/// pure functions of these two facts, so they are identical on every host and
/// fully testable on Linux.
public struct SkyLightCapabilities: Sendable, Equatable {
    /// Symbols that resolved to a live pointer.
    public let resolved: Set<SkyLightSymbol>
    /// `CGSMainConnectionID()` result (0 when the symbol is absent or returned 0,
    /// matching `skylight._main_cid`).
    public let mainConnectionId: UInt32

    public init(resolved: Set<SkyLightSymbol>, mainConnectionId: UInt32) {
        self.resolved = resolved
        self.mainConnectionId = mainConnectionId
    }

    /// Port of `skylight.is_available()`: framework loaded (we could resolve and
    /// call `CGSMainConnectionID`) AND the main connection is non-zero. Dynamic —
    /// recomputed from the live capabilities each time so it stays test-patchable.
    public var isAvailable: Bool {
        resolved.contains(.CGSMainConnectionID) && mainConnectionId != 0
    }

    /// Window-owner validation (US-029b) needs the owner lookup. Connection→PID /
    /// connection-compare strategies are layered on top by the validator.
    public var canValidateWindowOwner: Bool {
        isAvailable && resolved.contains(.SLSGetWindowOwner)
    }

    /// Targeted MOUSE delivery (C2/US-030): post to a pid, stamp the target
    /// window id into the integer fields, and place the event in window-local
    /// coordinates.
    public var canDeliverMouse: Bool {
        isAvailable && resolved.isSuperset(of: [
            .SLEventPostToPid, .SLEventSetIntegerValueField, .CGEventSetWindowLocation,
        ])
    }

    /// Targeted KEYBOARD delivery (C3/US-031): authenticated SkyLight post to the
    /// pid PLUS a `CGEventPostToPSN` to the window owner resolved via
    /// `SLSGetWindowOwner` → `SLSGetConnectionPSN`. (The ObjC
    /// `SLSEventAuthenticationMessage` class is resolved separately via the ObjC
    /// runtime in Kit, not through this dlsym set.)
    public var canDeliverKeyboard: Bool {
        isAvailable && resolved.isSuperset(of: [
            .SLEventPostToPid, .SLEventSetAuthenticationMessage,
            .CGEventPostToPSN, .SLSGetWindowOwner, .SLSGetConnectionPSN,
        ])
    }
}

/// Pure evaluator: walk every catalogued symbol through the injected loader,
/// collect the ones that resolve, and pair them with the main connection id to
/// produce `SkyLightCapabilities`. `mainConnectionIdProvider` is only invoked
/// when `CGSMainConnectionID` itself resolved — exactly like
/// `skylight._init()` only calls the function after a successful load — so a
/// host missing the base symbol reports `mainConnectionId == 0` (unavailable)
/// without ever attempting the call.
public enum SkyLightAvailability {
    public static func evaluate(
        loader: SkyLightSymbolLoader,
        mainConnectionIdProvider: () -> UInt32
    ) -> SkyLightCapabilities {
        var resolved: Set<SkyLightSymbol> = []
        for symbol in SkyLightSymbol.allCases where loader.resolve(symbol) != nil {
            resolved.insert(symbol)
        }
        let cid = resolved.contains(.CGSMainConnectionID) ? mainConnectionIdProvider() : 0
        return SkyLightCapabilities(resolved: resolved, mainConnectionId: cid)
    }
}

/// Provider seam for the SkyLight targeted-delivery layer. `isAvailable` is
/// DYNAMIC (re-evaluated on read, test-patchable) so a host where the SPIs are
/// absent or were removed (macOS 26) reports `false` and callers fall through to
/// the always-available CGEvent base path (US-028) — they never foreground.
public protocol SkyLightProviding: AnyObject {
    var isAvailable: Bool { get }
    var capabilities: SkyLightCapabilities { get }
}
