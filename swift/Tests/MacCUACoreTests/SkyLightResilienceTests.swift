import XCTest
@testable import MacCUACore

/// US-042 — macOS-26 SPI-removal resilience (C8, §5.7).
///
/// These tests encode the contract that REMOVED SkyLight/CGS symbols never
/// become hard dependencies or foregrounding triggers: CGEvent base delivery
/// needs zero SkyLight symbols, every removed symbol is optional, and a host
/// with the whole (or partial) SkyLight surface gone degrades safely — every
/// targeted-delivery capability simply reports `false` so callers fall through
/// to the always-available `CGEvent.postToPid` path. The pure capability model
/// is the only thing testable on Linux; the actual fall-through wiring lives in
/// `KitInputProvider` (MANUAL-VERIFY).
private final class FakeSkyLightLoader: SkyLightSymbolLoader {
    let present: Set<SkyLightSymbol>
    private let dummy = UnsafeMutableRawPointer(bitPattern: 0xBEEF)!
    init(_ present: Set<SkyLightSymbol>) { self.present = present }
    func resolve(_ symbol: SkyLightSymbol) -> UnsafeMutableRawPointer? {
        present.contains(symbol) ? dummy : nil
    }
}

final class SkyLightResilienceTests: XCTestCase {

    private func evaluate(_ present: Set<SkyLightSymbol>, cid: UInt32 = 1) -> SkyLightCapabilities {
        SkyLightAvailability.evaluate(loader: FakeSkyLightLoader(present), mainConnectionIdProvider: { cid })
    }

    // MARK: - The core C8 invariant

    func testRemovedSymbolsAreNeverRequiredByAnyCapability() {
        // A removed-in-26 symbol gating any capability would make that feature a
        // hard dependency on a deleted SPI. It must never happen.
        XCTAssertTrue(SkyLightResilience.removedSymbolsAreNeverRequired)
        for (capability, required) in SkyLightResilience.requiredSymbols {
            XCTAssertTrue(
                required.isDisjoint(with: SkyLightResilience.removedInMacOS26),
                "\(capability) must not require a macOS-26-removed symbol")
        }
    }

    func testLegacyPerProcessPostSPIsAreNotEvenInTheCatalogue() {
        // CGSPost*EventToProcess were removed in macOS 26; we replaced them with
        // the SLEventPostToPid family. They must be impossible to depend on, i.e.
        // absent from the symbol catalogue entirely.
        let catalogue = Set(SkyLightSymbol.allCases.map(\.rawValue))
        for legacy in SkyLightResilience.neverReferencedRemovedSPIs {
            XCTAssertFalse(catalogue.contains(legacy),
                           "\(legacy) must not be a bound symbol")
        }
    }

    func testCGSGetConnectionIDForPIDIsClassifiedRemoved() {
        XCTAssertTrue(SkyLightResilience.removedInMacOS26.contains(.CGSGetConnectionIDForPID))
    }

    // MARK: - CGEvent base path needs zero SkyLight symbols

    func testBaseDeliveryHasNoSkyLightRequirement() {
        // The required-symbol map has NO "cgeventBase" entry: CGEvent.postToPid
        // delivery requires no SkyLight symbol, which is why it is the always-
        // available primary for native apps.
        XCTAssertNil(SkyLightResilience.requiredSymbols["cgeventBase"])
    }

    // MARK: - Full SkyLight surface gone (simulated macOS 26 stripped host)

    func testEntireSurfaceAbsentDegradesSafely() {
        let caps = evaluate([])
        XCTAssertFalse(caps.isAvailable)
        XCTAssertFalse(caps.canValidateWindowOwner)   // → assume-valid in validator
        XCTAssertFalse(caps.canDeliverMouse)          // → CGEvent fall-through
        XCTAssertFalse(caps.canDeliverKeyboard)       // → CGEvent fall-through
    }

    // MARK: - macOS 26 host: Strategy-1 owner symbol gone, rest present

    func testStrategy1OwnerSymbolRemovedDoesNotDisableValidationCapability() {
        // On macOS 26 CGSGetConnectionIDForPID is gone but CGSConnectionGetPID
        // (Strategy 2) remains. Window-owner validation capability depends only on
        // the owner lookup, not on the removed Strategy-1 symbol — so it stays on.
        let macOS26: Set<SkyLightSymbol> = Set(SkyLightSymbol.allCases)
            .subtracting(SkyLightResilience.removedInMacOS26)
        let caps = evaluate(macOS26)
        XCTAssertTrue(caps.isAvailable)
        XCTAssertTrue(caps.canValidateWindowOwner)
        XCTAssertTrue(caps.canDeliverMouse)
        XCTAssertTrue(caps.canDeliverKeyboard)
    }

    func testValidatorAssumesValidWhenStrategy1AbsentAndStrategy2Confirms() {
        // Strategy 1 lookup absent (removed), Strategy 2 confirms a match.
        let lookups = FakeOwnerLookups(
            available: true, ownerCid: 99, strategy1Cid: nil, strategy2Pid: 1234)
        XCTAssertTrue(WindowOwnerValidator.validate(windowId: 7, expectedPid: 1234, lookups: lookups))
    }

    func testValidatorAssumesValidWhenNeitherStrategyCanRun() {
        // Both removed/absent — never block the action (assume-valid).
        let lookups = FakeOwnerLookups(
            available: true, ownerCid: 99, strategy1Cid: nil, strategy2Pid: nil)
        XCTAssertTrue(WindowOwnerValidator.validate(windowId: 7, expectedPid: 1234, lookups: lookups))
    }

    func testValidatorOnlyFalseOnConfirmedMismatch() {
        let lookups = FakeOwnerLookups(
            available: true, ownerCid: 99, strategy1Cid: nil, strategy2Pid: 5555)
        XCTAssertFalse(WindowOwnerValidator.validate(windowId: 7, expectedPid: 1234, lookups: lookups))
    }
}

private struct FakeOwnerLookups: WindowOwnerLookups {
    let available: Bool
    let ownerCid: UInt32?
    let strategy1Cid: UInt32?
    let strategy2Pid: Int32?
    var isAvailable: Bool { available }
    func windowOwnerConnectionId(windowId: UInt32) -> UInt32? { ownerCid }
    func connectionId(forPid pid: Int32) -> UInt32? { strategy1Cid }
    func pid(forConnectionId connectionId: UInt32) -> Int32? { strategy2Pid }
}
