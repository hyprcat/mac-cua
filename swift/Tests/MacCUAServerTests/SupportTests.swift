import XCTest
@testable import MacCUAServer

/// US-013: residual support-module audit/port. Covers the pure logic ported from
/// elicitation.py (AppApprovalStore), lifecycle.py (SessionLifecycle/TurnMetadata),
/// and analytics.py (BufferingAnalytics).
final class SupportTests: XCTestCase {

    // MARK: AppApprovalStore

    func testSessionApprovalAndDenyToggle() {
        let store = AppApprovalStore()
        XCTAssertFalse(store.isApproved("com.a"))
        store.approveForSession("com.a")
        XCTAssertTrue(store.isApproved("com.a"))

        store.deny("com.a")
        XCTAssertTrue(store.isDenied("com.a"))
        // Re-approving clears the denial.
        store.approveForSession("com.a")
        XCTAssertFalse(store.isDenied("com.a"))
    }

    func testClearSessionApprovalsDropsSessionButNotPersistent() {
        let storage = FakeApprovalStorage(initial: ["com.persist"])
        let store = AppApprovalStore(storage: storage)
        store.approveForSession("com.session")
        XCTAssertTrue(store.isApproved("com.session"))
        XCTAssertTrue(store.isApproved("com.persist"))

        store.clearSessionApprovals()
        XCTAssertFalse(store.isApproved("com.session"))
        XCTAssertTrue(store.isApproved("com.persist"))
    }

    func testPersistentApprovalLoadsAndSaves() {
        let storage = FakeApprovalStorage(initial: ["com.loaded"])
        let store = AppApprovalStore(storage: storage)
        XCTAssertTrue(store.isApproved("com.loaded"))

        store.approvePersistently("com.new")
        XCTAssertTrue(store.isApproved("com.new"))
        XCTAssertTrue(storage.saved.contains("com.new"))
        XCTAssertTrue(storage.saved.contains("com.loaded"))
    }

    func testNoStorageMeansSessionOnly() {
        let store = AppApprovalStore() // storage == nil
        store.approvePersistently("com.x") // must not crash without storage
        XCTAssertTrue(store.isApproved("com.x"))
    }

    func testRiskWarningMatchesPython() {
        XCTAssertTrue(appApprovalRiskWarning.contains("prompt injection attacks"))
        XCTAssertTrue(appApprovalRiskWarning.hasPrefix("Allowing automation to use this app"))
    }

    // MARK: SessionLifecycle

    func testStepLimitAndAppTracking() {
        let lc = SessionLifecycle(stepLimit: 2)
        lc.trackAppUsed("com.a")
        lc.trackAppUsed("com.a") // dedup
        lc.trackAppUsed("com.b")
        XCTAssertEqual(lc.usedApps, ["com.a", "com.b"])

        XCTAssertFalse(lc.checkStepLimit())
        lc.incrementStep()
        XCTAssertFalse(lc.checkStepLimit())
        lc.incrementStep()
        XCTAssertTrue(lc.checkStepLimit())
    }

    func testStepLimitZeroDisables() {
        let lc = SessionLifecycle(stepLimit: 0)
        for _ in 0..<100 { lc.incrementStep() }
        XCTAssertFalse(lc.checkStepLimit())
    }

    func testTurnMetadataGrouping() {
        let lc = SessionLifecycle(stepLimit: 20)
        XCTAssertNil(lc.currentTurn)
        lc.startTurn("turn-1", startedAt: 123.0)
        lc.incrementStep()
        lc.trackAppUsed("com.a")
        XCTAssertEqual(lc.currentTurn?.turnId, "turn-1")
        XCTAssertEqual(lc.currentTurn?.startedAt, 123.0)
        XCTAssertEqual(lc.currentTurn?.stepCount, 1)
        XCTAssertEqual(lc.currentTurn?.appsUsed, ["com.a"])

        lc.endTurn()
        XCTAssertNil(lc.currentTurn)
        // Session-level counters persist across the turn boundary.
        XCTAssertEqual(lc.stepCount, 1)
    }

    // MARK: BufferingAnalytics

    func testBufferingAnalyticsRecordsAndFlushes() {
        let a = BufferingAnalytics()
        a.serviceLaunched()
        a.mcpToolCalled("click")
        a.mcpAppApprovalResolved("com.a", approved: false)
        a.sessionStarted("com.a")

        let flushed = a.flush()
        XCTAssertEqual(flushed.map(\.name),
                       ["service_launched", "mcp_tool_called",
                        "mcp_app_approval_resolved", "session_started"])
        XCTAssertEqual(flushed[1].fields["mcp_tool_name"], "click")
        XCTAssertEqual(flushed[2].fields["mcp_approval_result"], "denied")
        // flush drains.
        XCTAssertTrue(a.flush().isEmpty)
    }

    func testNoopAnalyticsExtendedHooksCompileAndNoop() {
        let a: Analytics = NoopAnalytics()
        a.serviceIdleTimeoutReached()
        a.sessionStarted("com.a")
        a.sessionEnded("com.a")
        a.mcpAppApprovalRequested("com.a")
    }
}

/// In-memory approval persistence for tests (no disk).
private final class FakeApprovalStorage: ApprovalStorage {
    private let initial: [String]
    private(set) var saved: [String] = []

    init(initial: [String]) { self.initial = initial }

    func loadApprovedBundles() -> [String] { initial }
    func saveApprovedBundles(_ bundles: [String]) { saved = bundles }
}
