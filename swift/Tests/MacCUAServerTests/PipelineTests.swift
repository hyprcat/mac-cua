import XCTest
import MacCUACore
@testable import MacCUAServer

/// Linux-buildable port of `tests/test_pipeline.py` — the execute() pipeline
/// step ordering, settle gating, transient-probe fast path, and the
/// error/cleanup arms. Where the Python test patches private methods to record a
/// call order, the Swift port drives the real spine through `execute(_:_:)`
/// against the fakes and asserts the OBSERVABLE consequences (which seam ran,
/// what settle budget, whether a snapshot was produced) — the spine here has no
/// separate `_activate_focus_enforcement` seam (focus is the frontmost
/// tracker + restore), so those order checks are expressed via the recorders.
final class PipelineTests: XCTestCase {

    // MARK: - Fixtures

    private let pid = 111
    private let windowId = 77

    /// Capture fake with one window owned by `pid` so window-id resolution works.
    private func capture() -> FakeCapture {
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowId, ownerPid: pid, ownerName: "Example",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true)
        ]
        return cap
    }

    private func apps() -> FakeAppResolver {
        let a = FakeAppResolver()
        a.running = [AppInfo(name: "Example", bundleId: "com.example.App", pid: pid, running: true)]
        a.resolved = a.running.first
        return a
    }

    /// Flags geared for deterministic pipeline runs against fakes: transient
    /// graphs + menu tracking on (for gating), interruption detection on,
    /// verification observers off, focus enforcement off (no real frontmost).
    private func flags(
        menuTracking: Bool = true,
        transientGraphs: Bool = true,
        userInterruptionDetection: Bool = true
    ) -> FeatureFlags {
        FeatureFlags(
            treePruning: false,
            userInterruptionDetection: userInterruptionDetection,
            focusEnforcement: false,
            menuTracking: menuTracking,
            transientGraphs: transientGraphs,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: false,
            confirmedDelivery: false)
    }

    // MARK: - Step ordering & gating (TestPipelineStepOrdering)

    /// Ports test_get_app_state_skips_focus_and_interruption + the action-tool
    /// counterpart: an action tool starts interaction monitoring; get_app_state
    /// does not. (Focus-activate has no separate seam here.)
    func testActionToolStartsInteractionMonitoringStateToolDoesNot() throws {
        let interaction = FakeUserInteraction()
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps(), capture: capture(), userInteraction: interaction),
            flags: flags())

        // get_app_state: monitoring is never started → stays idle.
        _ = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertFalse(interaction.monitoring)

        // An action tool starts (and then stops) monitoring around dispatch.
        // It's stopped by the end, but the start was observed by the fact that
        // the interruption was checked (a primed interruption would yield).
        interaction.interruption = "USER TOUCHED IT"
        let resp = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])
        // The interruption surfaced → monitoring WAS started for the action tool.
        XCTAssertNotNil(resp.error)
        XCTAssertTrue(resp.error?.contains("USER TOUCHED IT") ?? false)
    }

    /// Ports test_settle_timeout_zero_skips_settle: get_app_state has a settle
    /// budget of 0.0 → wait_for_settle is never called.
    func testSettleTimeoutZeroSkipsSettle() throws {
        let factory = RecordingSettleFactory()
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(),
                makeSettleMonitor: factory.make),
            flags: flags())

        _ = mgr.execute("get_app_state", ["window_id": windowId])
        // A settle monitor was created for the session, but never asked to wait.
        XCTAssertNotNil(factory.last)
        XCTAssertEqual(factory.last?.waits, 0)
    }

    /// Ports test_action_tool_fires_all_steps_in_order (the settle slice): an
    /// action tool with no open menu uses the FULL settle budget (1.0s for click).
    func testActionToolUsesFullSettleBudget() throws {
        let factory = RecordingSettleFactory()
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(),
                makeSettleMonitor: factory.make),
            flags: flags(menuTracking: false))

        _ = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])
        XCTAssertEqual(factory.last?.calls.count, 1)
        XCTAssertEqual(factory.last?.calls.first?.timeout, 1.0)
        XCTAssertEqual(factory.last?.calls.first?.context, "click")
    }

    /// Ports test_open_menu_uses_short_settle_wait + test_open_menu_does_not_block:
    /// when a menu is open (tracker reports menus_open) but there is NO active
    /// transient graph, the transient-probe fast path is skipped and settle is
    /// capped at the short 0.15s budget (a short settle, NOT skipped, NOT blocked).
    func testOpenMenuUsesShortSettleNotBlocking() throws {
        let factory = RecordingSettleFactory()
        let menu = FakeMenuTracking()
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(),
                makeSettleMonitor: factory.make,
                makeMenuTracker: { _ in menu }),
            flags: flags())

        // Establish a session, then report a menu open WITHOUT an active
        // transient graph → transient probe doesn't apply, short-settle does.
        _ = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        menu.menusOpen = true

        _ = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])

        // Settle ran exactly once (not blocked) but capped at the short budget.
        XCTAssertEqual(factory.last?.calls.count, 1)
        XCTAssertEqual(factory.last?.calls.first?.timeout, 0.15)
    }

    /// Ports test_transient_probe_captures_snapshot_immediately_without_settle:
    /// when a menu surface is open, the transient-probe fast path captures a
    /// transient snapshot and SKIPS settle entirely.
    func testTransientProbeCapturesSnapshotWithoutSettle() throws {
        let factory = RecordingSettleFactory()
        let menu = FakeMenuTracking()
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "menu", depth: 0, axRef: FakeAXRef("menu-node"), axRole: "AXMenu")]
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), accessibility: ax, capture: capture(),
                makeSettleMonitor: factory.make,
                makeMenuTracker: { _ in menu }),
            flags: flags())

        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        let snapshotBefore = session.snapshotId
        openTransientSurface(session, menu: menu)

        let response = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])

        // Transient probe → settle not called; a transient snapshot was produced
        // (snapshot id advanced, no screenshot), and the dispatch result attached.
        XCTAssertEqual(factory.last?.waits, 0)
        XCTAssertNil(response.screenshot)
        XCTAssertGreaterThan(response.snapshotId, snapshotBefore)
        XCTAssertNil(response.error)
        XCTAssertTrue(response.result?.contains("Clicked") ?? false)
    }

    /// Ports test_list_apps_bypasses_pipeline: list_apps returns immediately
    /// without resolving a session (no window_id/app required, no settle).
    func testListAppsBypassesPipeline() {
        let factory = RecordingSettleFactory()
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(),
                makeSettleMonitor: factory.make),
            flags: flags())

        let response = mgr.execute("list_apps", [:])
        XCTAssertNil(response.error)
        XCTAssertNotNil(response.result)
        // No session was created → no settle monitor was ever built.
        XCTAssertTrue(factory.created.isEmpty)
        XCTAssertTrue(mgr.sessions.isEmpty)
    }

    // MARK: - Error / cleanup arms (TestPipelineErrorPaths)

    /// Ports test_blocked_app_raises_app_blocked_error: a safety-blocked app
    /// surfaces an error (never throws to the caller).
    func testBlockedAppSurfacesError() {
        let a = FakeAppResolver()
        // A blocklisted bundle (see Core blockedApps). Resolve it by window pid.
        let blockedPid = 4321
        a.running = [AppInfo(name: "Keychain", bundleId: "com.apple.keychainaccess",
                             pid: blockedPid, running: true)]
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: 90, ownerPid: blockedPid, ownerName: "Keychain",
                       title: "Login", x: 0, y: 0, width: 400, height: 300, onscreen: true)
        ]
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: a, capture: cap), flags: flags())

        let response = mgr.execute("click", ["window_id": 90, "x": 1.0, "y": 2.0])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("com.apple.keychainaccess") ?? false)
    }

    /// Ports test_step_limit_raises_step_limit_error: hitting the loop step limit
    /// produces a "Step limit" error.
    func testStepLimitSurfacesError() {
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps(), capture: capture()),
            flags: flags(),
            workarounds: WorkaroundFlags(loopStepLimit: 1))

        // First action consumes the only allowed step.
        _ = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])
        // Second action trips the limit.
        let response = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("Step limit") ?? false)
    }

    /// Ports test_stale_reference_refreshes_tree: a StaleReferenceError from
    /// dispatch is caught and turned into a refreshed snapshot with the error
    /// attached ("Tree refreshed").
    func testStaleReferenceRefreshesTree() throws {
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps(), capture: capture()),
            flags: flags())

        // set_value with an index that resolves to a stale reference: wire a
        // refetchable tree whose element() returns notFound. Easiest path:
        // resolve a session, then drive set_value against an empty tree so
        // resolveIndex → badIndex (an AutomationError, not stale). To hit the
        // STALE arm specifically we use the spine's own classification: a
        // refetchable tree present with a monitor + missing locator → notFound.
        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        let monitor = FakeSettleMonitor()
        // A tree that has a node but the requested index is absent after refetch
        // (empty nodes + monitor present) → RefetchableTree returns notFound.
        session.refetchableTree = RefetchableTree(
            nodes: [], monitor: SettleInvalidationAdapter(monitor), axWindow: nil,
            targetPid: pid, walkFn: { _, _ in [] })

        let response = mgr.execute(
            "set_value", ["window_id": windowId, "element_index": 0, "value": "x"])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.lowercased().contains("stale") ?? false)
        XCTAssertTrue(response.error?.contains("Tree refreshed") ?? false)
    }

    /// US-038: when the cached ref is dead (liveness probe fails), resolveIndex
    /// re-walks + rebinds via the RefetchableTree to the element's NEW position
    /// rather than acting on the stale index-0 ref.
    func testLivenessGateRebindsDeadRefToNewIndex() throws {
        let ax = FakeAccessibility()
        // The element the model targeted ("Save") moved from index 0 to index 1.
        ax.aliveForNode = { $0.index != 0 }  // index-0 ref is dead; the rest live
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps(), accessibility: ax, capture: capture()),
            flags: flags())

        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        let original = [Node(index: 0, role: "button", label: "Save", depth: 1, axRef: FakeAXRef("x"))]
        let rewalked = [
            Node(index: 0, role: "button", label: "Help", depth: 1, axRef: FakeAXRef("x")),
            Node(index: 1, role: "button", label: "Save", depth: 1, axRef: FakeAXRef("x")),
        ]
        let monitor = FakeSettleMonitor()
        session.treeNodes = original
        session.refetchableTree = RefetchableTree(
            nodes: original, monitor: SettleInvalidationAdapter(monitor),
            axWindow: FakeAXRef("x"), targetPid: pid, walkFn: { _, _ in rewalked })

        _ = mgr.execute(
            "set_value", ["window_id": windowId, "element_index": 0, "value": "x"])
        // set_value acted on the rebound element (new index 1), NEVER the dead 0.
        // (The fake's makeEditableText returns nil so verification can't confirm,
        // but the recorded AX writes prove which element the spine targeted.)
        XCTAssertFalse(ax.setAttributes.isEmpty, "the rebound element was acted on")
        XCTAssertTrue(ax.setAttributes.allSatisfy { $0.2 == 1 },
                      "every AX write targeted the rebound index 1, never the dead 0")
    }

    /// US-038: a dead ref that cannot be rebound (element gone after re-walk)
    /// surfaces as a stale-reference + refreshed tree, never acts on the dead ref.
    func testLivenessGateGoneElementSurfacesStale() throws {
        let ax = FakeAccessibility()
        ax.aliveForNode = { _ in false }
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps(), accessibility: ax, capture: capture()),
            flags: flags())

        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        let original = [Node(index: 0, role: "button", label: "Save", depth: 1, axRef: FakeAXRef("x"))]
        let monitor = FakeSettleMonitor()
        session.treeNodes = original
        session.refetchableTree = RefetchableTree(
            nodes: original, monitor: SettleInvalidationAdapter(monitor),
            axWindow: FakeAXRef("x"), targetPid: pid, walkFn: { _, _ in [] })

        let response = mgr.execute(
            "set_value", ["window_id": windowId, "element_index": 0, "value": "x"])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.lowercased().contains("stale") ?? false)
        XCTAssertTrue(ax.setAttributes.isEmpty, "never act on the dead ref")
    }

    /// Ports test_cleanup_called_on_error: a generic AutomationError from dispatch
    /// still stops the interaction monitor (cleanup fires) and returns a snapshot
    /// + error rather than throwing.
    func testCleanupFiresOnError() throws {
        let interaction = FakeUserInteraction()
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(), userInteraction: interaction),
            flags: flags())

        // press_key with no "key" param → handler throws AutomationError.
        let response = mgr.execute("press_key", ["window_id": windowId])
        XCTAssertNotNil(response.error)
        // Cleanup ran: monitoring was stopped (left idle) after the error.
        XCTAssertFalse(interaction.monitoring)
        // A snapshot was still produced (failproof) → tree text present.
        XCTAssertNotNil(response.treeText)
    }

    // MARK: - User interruption (TestPipelineUserInterruption)

    /// Ports test_interruption_returns_error_without_snapshot: a detected user
    /// interruption returns an error response, marks the session invalidated,
    /// and does NOT attach a fresh snapshot.
    func testInterruptionReturnsErrorWithoutSnapshot() throws {
        let interaction = FakeUserInteraction()
        interaction.interruption =
            "The user changed 'com.example.App'. Re-query the latest state with "
            + "`get_app_state` before sending more actions."
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(), userInteraction: interaction),
            flags: flags(menuTracking: false))

        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        let snapshotBefore = session.snapshotId

        let response = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])
        XCTAssertEqual(response.error, interaction.interruption)
        XCTAssertTrue(session.userStateInvalidated)
        // No new snapshot was captured on the interruption arm.
        XCTAssertNil(response.treeText)
        XCTAssertEqual(session.snapshotId, snapshotBefore)
    }

    // MARK: - Helpers

    /// Open a transient surface on a resolved session: push a transient graph
    /// with a root ref and flip the (captured) menu tracker to open so
    /// `activeTransientSurface(session)` returns non-nil.
    private func openTransientSurface(_ session: AppSession, menu: FakeMenuTracking) {
        let root = FakeAXRef("transient-root")
        session.graphRegistry.pushTransient(
            session.graphs, rootRef: root,
            nodes: [Node(index: 0, role: "menu", depth: 0, axRef: root, axRole: "AXMenu")],
            rootLocator: nil, source: nil, transientKind: "menu")
        menu.menusOpen = true
    }
}
