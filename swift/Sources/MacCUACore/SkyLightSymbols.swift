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
    case CGSGetConnectionIDForPID       // int32_t (cid, pid, uint32_t *cidOut) — pre-26 owner strategy (removed in 26)
    // Targeted-delivery symbols.
    case SLEventPostToPid               // void (int32_t pid, CGEventRef e)
    case SLEventSetIntegerValueField    // void (CGEventRef e, uint32_t field, int64_t v) — field 40 = pid
    case SLEventSetAuthenticationMessage // void (CGEventRef e, id message)
    case CGEventSetWindowLocation       // void (CGEventRef e, CGPoint p) — a SkyLight export, not CoreGraphics
    case CGEventPostToPSN               // void (ProcessSerialNumber *psn, CGEventRef e)
}

/// macOS-26 SPI-removal resilience contract (C8, §5.7).
///
/// Tahoe (macOS 26) deleted a family of CoreGraphics-Server / SkyLight private
/// symbols. The Prime-Invariant rule for this port (Invariant 17/18): a removed
/// symbol must NEVER become a hard link dependency, a crash, or a foregrounding
/// trigger — it is only ever an OPTIONAL optimization, and its absence degrades
/// to the always-available `CGEvent.postToPid` base path (US-028) or to
/// assume-valid window-owner validation (US-029b).
///
/// Two classes of removed symbol:
///   1. Symbols still in our catalogue but optional — `CGSGetConnectionIDForPID`
///      (pre-26 window-owner Strategy 1; superseded by `CGSConnectionGetPID`
///      Strategy 2). Resolved individually; `nil` when absent.
///   2. Symbols we DELIBERATELY NEVER reference — the legacy
///      `CGSPostKeyboardEventToProcess` / `CGSPostMouseEventToProcess` /
///      `CGSPostEventRecordToProcess`. They are not in `SkyLightSymbol` at all,
///      so they can never be a dependency by construction; the targeted
///      `SLEventPostToPid` family replaces them as an optimization only.
public enum SkyLightResilience {
    /// Catalogued symbols that macOS 26 removed (class 1 above). Each must stay
    /// out of every "required" set — verified by `removedSymbolsAreNeverRequired`.
    public static let removedInMacOS26: Set<SkyLightSymbol> = [.CGSGetConnectionIDForPID]

    /// Legacy per-process post SPIs we never bind (class 2 above). EXACT C names,
    /// kept here only to assert (in tests/docs) that they are absent from the
    /// catalogue and thus impossible to depend on.
    public static let neverReferencedRemovedSPIs: Set<String> = [
        "CGSPostKeyboardEventToProcess",
        "CGSPostMouseEventToProcess",
        "CGSPostEventRecordToProcess",
    ]

    /// The SkyLight symbols required by EACH capability. CGEvent base delivery is
    /// intentionally absent from this map: it requires NO SkyLight symbol, which
    /// is exactly why it is the always-available primary.
    public static let requiredSymbols: [String: Set<SkyLightSymbol>] = [
        "isAvailable": SkyLightCapabilities.requiredForAvailable,
        "canValidateWindowOwner": SkyLightCapabilities.requiredForWindowOwner,
        "canDeliverMouse": SkyLightCapabilities.requiredForMouse,
        "canDeliverKeyboard": SkyLightCapabilities.requiredForKeyboard,
    ]

    /// True iff no macOS-26-removed symbol gates any capability (the C8 invariant).
    /// A removed symbol appearing in any required set would make that capability a
    /// hard dependency on a deleted SPI — forbidden.
    public static var removedSymbolsAreNeverRequired: Bool {
        for required in requiredSymbols.values where !required.isDisjoint(with: removedInMacOS26) {
            return false
        }
        return true
    }
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

    // The per-capability required-symbol sets are exposed as named constants (not
    // inline literals) so the macOS-26 resilience guard can verify NO removed
    // symbol gates any capability. `requiredForAvailable` holds only the base
    // symbol; the non-zero-connection check is a runtime fact, not a symbol.

    /// Base symbol behind `isAvailable` (paired with a non-zero connection id).
    public static let requiredForAvailable: Set<SkyLightSymbol> = [.CGSMainConnectionID]

    /// Window-owner validation (US-029b) — owner lookup on top of availability.
    public static let requiredForWindowOwner: Set<SkyLightSymbol> = [.SLSGetWindowOwner]

    /// Targeted MOUSE delivery (C2/US-030).
    public static let requiredForMouse: Set<SkyLightSymbol> = [
        .SLEventPostToPid, .SLEventSetIntegerValueField, .CGEventSetWindowLocation,
    ]

    /// Targeted KEYBOARD delivery (C3/US-031). The ObjC
    /// `SLSEventAuthenticationMessage` class is resolved separately via the ObjC
    /// runtime in Kit, not through this dlsym set.
    public static let requiredForKeyboard: Set<SkyLightSymbol> = [
        .SLEventPostToPid, .SLEventSetAuthenticationMessage,
        .CGEventPostToPSN, .SLSGetWindowOwner, .SLSGetConnectionPSN,
    ]

    /// Port of `skylight.is_available()`: framework loaded (we could resolve and
    /// call `CGSMainConnectionID`) AND the main connection is non-zero. Dynamic —
    /// recomputed from the live capabilities each time so it stays test-patchable.
    public var isAvailable: Bool {
        resolved.isSuperset(of: Self.requiredForAvailable) && mainConnectionId != 0
    }

    /// Window-owner validation (US-029b) needs the owner lookup. Connection→PID /
    /// connection-compare strategies are layered on top by the validator.
    public var canValidateWindowOwner: Bool {
        isAvailable && resolved.isSuperset(of: Self.requiredForWindowOwner)
    }

    /// Targeted MOUSE delivery (C2/US-030): post to a pid, stamp the target
    /// window id into the integer fields, and place the event in window-local
    /// coordinates.
    public var canDeliverMouse: Bool {
        isAvailable && resolved.isSuperset(of: Self.requiredForMouse)
    }

    /// Targeted KEYBOARD delivery (C3/US-031): authenticated SkyLight post to the
    /// pid PLUS a `CGEventPostToPSN` to the window owner resolved via
    /// `SLSGetWindowOwner` → `SLSGetConnectionPSN`.
    public var canDeliverKeyboard: Bool {
        isAvailable && resolved.isSuperset(of: Self.requiredForKeyboard)
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
