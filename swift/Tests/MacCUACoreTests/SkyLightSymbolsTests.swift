import XCTest
@testable import MacCUACore

/// Fake loader: "resolves" exactly the symbols in `present`, everything else nil.
/// Returns a stable dummy non-nil pointer for present symbols.
private final class FakeSkyLightLoader: SkyLightSymbolLoader {
    let present: Set<SkyLightSymbol>
    private let dummy = UnsafeMutableRawPointer(bitPattern: 0xDEAD)!
    init(_ present: Set<SkyLightSymbol>) { self.present = present }
    func resolve(_ symbol: SkyLightSymbol) -> UnsafeMutableRawPointer? {
        present.contains(symbol) ? dummy : nil
    }
}

final class SkyLightSymbolsTests: XCTestCase {

    private func evaluate(_ present: Set<SkyLightSymbol>, cid: UInt32 = 1) -> SkyLightCapabilities {
        SkyLightAvailability.evaluate(loader: FakeSkyLightLoader(present), mainConnectionIdProvider: { cid })
    }

    func testSymbolRawValuesMatchCSymbolNames() {
        // The Kit dlsym loader resolves by rawValue — drift would silently break delivery.
        XCTAssertEqual(SkyLightSymbol.CGSMainConnectionID.rawValue, "CGSMainConnectionID")
        XCTAssertEqual(SkyLightSymbol.SLSGetWindowOwner.rawValue, "SLSGetWindowOwner")
        XCTAssertEqual(SkyLightSymbol.SLSGetConnectionPSN.rawValue, "SLSGetConnectionPSN")
        XCTAssertEqual(SkyLightSymbol.CGSConnectionGetPID.rawValue, "CGSConnectionGetPID")
        XCTAssertEqual(SkyLightSymbol.SLEventPostToPid.rawValue, "SLEventPostToPid")
        XCTAssertEqual(SkyLightSymbol.SLEventSetIntegerValueField.rawValue, "SLEventSetIntegerValueField")
        XCTAssertEqual(SkyLightSymbol.SLEventSetAuthenticationMessage.rawValue, "SLEventSetAuthenticationMessage")
        XCTAssertEqual(SkyLightSymbol.CGEventSetWindowLocation.rawValue, "CGEventSetWindowLocation")
        XCTAssertEqual(SkyLightSymbol.CGEventPostToPSN.rawValue, "CGEventPostToPSN")
        XCTAssertEqual(SkyLightSymbol.CGSGetConnectionIDForPID.rawValue, "CGSGetConnectionIDForPID")
        XCTAssertEqual(SkyLightSymbol.allCases.count, 10)
    }

    func testResolvedSetReflectsLoader() {
        let caps = evaluate([.CGSMainConnectionID, .SLEventPostToPid])
        XCTAssertEqual(caps.resolved, [.CGSMainConnectionID, .SLEventPostToPid])
    }

    // MARK: - isAvailable (port of skylight.is_available)

    func testAvailableRequiresBaseSymbolAndNonZeroConnection() {
        XCTAssertTrue(evaluate([.CGSMainConnectionID], cid: 7).isAvailable)
    }

    func testUnavailableWhenBaseSymbolMissing() {
        // Even with everything else resolved, no CGSMainConnectionID => unavailable.
        let all = Set(SkyLightSymbol.allCases).subtracting([.CGSMainConnectionID])
        XCTAssertFalse(evaluate(all, cid: 9).isAvailable)
    }

    func testUnavailableWhenMainConnectionIsZero() {
        XCTAssertFalse(evaluate([.CGSMainConnectionID], cid: 0).isAvailable)
    }

    func testMainConnectionProviderNotCalledWhenBaseSymbolAbsent() {
        var called = false
        let caps = SkyLightAvailability.evaluate(
            loader: FakeSkyLightLoader([.SLEventPostToPid]),
            mainConnectionIdProvider: { called = true; return 42 })
        XCTAssertFalse(called, "must not call CGSMainConnectionID when its symbol didn't resolve")
        XCTAssertEqual(caps.mainConnectionId, 0)
        XCTAssertFalse(caps.isAvailable)
    }

    // MARK: - capability flags (the per-feature fall-through gates)

    func testCanValidateWindowOwner() {
        XCTAssertTrue(evaluate([.CGSMainConnectionID, .SLSGetWindowOwner]).canValidateWindowOwner)
        XCTAssertFalse(evaluate([.CGSMainConnectionID]).canValidateWindowOwner)
        XCTAssertFalse(evaluate([.SLSGetWindowOwner]).canValidateWindowOwner) // base missing
    }

    func testCanDeliverMouse() {
        let ok: Set<SkyLightSymbol> = [.CGSMainConnectionID, .SLEventPostToPid,
                                       .SLEventSetIntegerValueField, .CGEventSetWindowLocation]
        XCTAssertTrue(evaluate(ok).canDeliverMouse)
        // Missing window-location => cannot stamp window-local coords => fall through.
        XCTAssertFalse(evaluate(ok.subtracting([.CGEventSetWindowLocation])).canDeliverMouse)
        // Available but missing post symbol.
        XCTAssertFalse(evaluate([.CGSMainConnectionID]).canDeliverMouse)
    }

    func testCanDeliverKeyboard() {
        let ok: Set<SkyLightSymbol> = [.CGSMainConnectionID, .SLEventPostToPid,
                                       .SLEventSetAuthenticationMessage, .CGEventPostToPSN,
                                       .SLSGetWindowOwner, .SLSGetConnectionPSN]
        XCTAssertTrue(evaluate(ok).canDeliverKeyboard)
        // Without the PSN route there is no authenticated owner post => fall through.
        XCTAssertFalse(evaluate(ok.subtracting([.CGEventPostToPSN])).canDeliverKeyboard)
        XCTAssertFalse(evaluate(ok.subtracting([.SLSGetConnectionPSN])).canDeliverKeyboard)
    }

    func testFullSurfaceEnablesEverything() {
        let caps = evaluate(Set(SkyLightSymbol.allCases))
        XCTAssertTrue(caps.isAvailable)
        XCTAssertTrue(caps.canValidateWindowOwner)
        XCTAssertTrue(caps.canDeliverMouse)
        XCTAssertTrue(caps.canDeliverKeyboard)
    }

    func testEmptySurfaceDisablesEverythingNoCrash() {
        let caps = evaluate([])
        XCTAssertFalse(caps.isAvailable)
        XCTAssertFalse(caps.canValidateWindowOwner)
        XCTAssertFalse(caps.canDeliverMouse)
        XCTAssertFalse(caps.canDeliverKeyboard)
    }
}
