import XCTest
import MacCUACore
@testable import MacCUAServer

/// Phase-2 foundation smoke test: the Server target wires up against fakes and
/// the spine/handler stubs compile and route. Real behavior tests land once the
/// spine and handler sub-agents fill in their files.
final class FoundationSmokeTests: XCTestCase {
    func testSessionManagerConstructsWithFakeProviders() {
        let mgr = SessionManager(providers: makeFakeProviders())
        XCTAssertNotNil(mgr)
    }

    func testUnknownToolDispatchThrows() throws {
        let mgr = SessionManager(providers: makeFakeProviders())
        let target = AppTarget(
            bundleId: "com.example", pid: 1, windowId: 10, windowPid: 1,
            axApp: FakeAXRef("app"), axWindow: FakeAXRef("win"))
        let session = AppSession(target: target)
        XCTAssertThrowsError(try mgr.dispatch("nonsense", session, [:]))
    }

    func testGetAppStateDispatchReturnsMessage() throws {
        let mgr = SessionManager(providers: makeFakeProviders())
        let target = AppTarget(
            bundleId: "com.example", pid: 1, windowId: 10, windowPid: 1,
            axApp: FakeAXRef("app"), axWindow: FakeAXRef("win"))
        let session = AppSession(target: target)
        XCTAssertEqual(try mgr.dispatch("get_app_state", session, [:]), "App state retrieved.")
    }

    func testSupportTypes() {
        let approvals = AppApprovalStore()
        XCTAssertFalse(approvals.isApproved("com.x"))
        approvals.approveForSession("com.x")
        XCTAssertTrue(approvals.isApproved("com.x"))

        let life = SessionLifecycle()
        life.startTurn("t1")
        life.trackAppUsed("com.x")
        XCTAssertEqual(life.usedApps, ["com.x"])
    }
}
