import XCTest
@testable import MacCUACore

/// US-059 — remote-aware AX observer registration decision.
///
/// The pure chooser picks `_AXObserverAddNotificationAndCheckRemote`
/// (`remoteAware`) only when the private SPI resolved AND the feature flag is
/// on; in every other case it falls back to the public
/// `AXObserverAddNotification` (`publicAPI`). This is an occluded-Electron
/// notification-liveness optimization, never a correctness lever (the AX tree
/// re-walk is the source of truth), so the decision must always be expressible
/// as a fall-back. The two resilience corners below are the load-bearing ones:
/// flag-on but symbol-absent must NOT depend on the private symbol (Invariant
/// 17), and symbol-present but flag-off must honour the flag.
final class RemoteObserverSupportTests: XCTestCase {

    // MARK: - 2x2 truth table for registration()

    func testRemoteAwareOnlyWhenSymbolResolvedAndFlagEnabled() {
        XCTAssertEqual(
            RemoteObserverSupport.registration(remoteSymbolResolved: true, flagEnabled: true),
            .remoteAware)
    }

    func testPublicWhenSymbolResolvedButFlagDisabled() {
        // Symbol present, flag off → honour the flag, use the public API.
        XCTAssertEqual(
            RemoteObserverSupport.registration(remoteSymbolResolved: true, flagEnabled: false),
            .publicAPI)
    }

    func testPublicWhenFlagEnabledButSymbolAbsent() {
        // Resilience (Invariant 17): an enabled flag must NEVER force a dependency
        // on a private symbol that did not resolve — degrade silently to public.
        XCTAssertEqual(
            RemoteObserverSupport.registration(remoteSymbolResolved: false, flagEnabled: true),
            .publicAPI)
    }

    func testPublicWhenBothAbsent() {
        XCTAssertEqual(
            RemoteObserverSupport.registration(remoteSymbolResolved: false, flagEnabled: false),
            .publicAPI)
    }

    // MARK: - raw values pin the two registration cases

    func testRegistrationRawValues() {
        XCTAssertEqual(AXObserverRegistration.remoteAware.rawValue, "remoteAware")
        XCTAssertEqual(AXObserverRegistration.publicAPI.rawValue, "publicAPI")
    }
}
