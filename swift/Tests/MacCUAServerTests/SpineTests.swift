import XCTest
import MacCUACore
@testable import MacCUAServer

/// Linux-buildable tests for the orchestration spine: session resolution
/// (window_id preferred over app; one or the other required), the execute()
/// pipeline gating for get_app_state vs action tools, list_apps assembly, and
/// the error / stale / interruption exception arms — all against the fakes in
/// Fakes.swift.
final class SpineTests: XCTestCase {

    // MARK: helpers

    /// A capture fake pre-loaded with one window owned by `pid` so window-id and
    /// app resolution both succeed.
    private func captureWith(windowId: Int, pid: Int) -> FakeCapture {
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowId, ownerPid: pid, ownerName: "Example",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true)
        ]
        return cap
    }

    /// Flags with verification/observer-heavy features off so the pipeline runs
    /// deterministically against fakes (transient graphs still on for gating).
    private func flags() -> FeatureFlags {
        FeatureFlags(
            userInterruptionDetection: true,
            focusEnforcement: false,
            transientGraphs: true,
            systemSelection: false)
    }

    // MARK: session resolution

    func testResolveRequiresWindowIdOrApp() throws {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        XCTAssertThrowsError(try mgr.resolveSession("click", [:])) { error in
            let e = error as? AutomationError
            XCTAssertEqual(e?.kind, .automation)
            XCTAssertTrue(e?.message.contains("requires window_id or app") ?? false)
        }
    }

    func testResolveByWindowIdSucceeds() throws {
        let pid = 4242, windowId = 99
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())

        let session = try mgr.resolveSession("click", ["window_id": windowId])
        XCTAssertEqual(session.target.windowId, windowId)
        XCTAssertEqual(session.target.bundleId, "com.example")
        XCTAssertEqual(session.target.windowPid, pid)
    }

    func testWindowIdPreferredOverApp() throws {
        // Provide BOTH window_id and app pointing at different things; window_id
        // must win (resolveSession checks window_id first).
        let pid = 7, windowId = 55
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Other", bundleId: "com.other", pid: pid, running: true)]
        apps.resolved = AppInfo(name: "AppHint", bundleId: "com.apphint", pid: 999, running: true)
        let cap = captureWith(windowId: windowId, pid: pid)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())

        let session = try mgr.resolveSession("click", ["window_id": windowId, "app": "AppHint"])
        // Resolved via the window's owning pid (com.other), not the app hint.
        XCTAssertEqual(session.target.windowId, windowId)
        XCTAssertEqual(session.target.bundleId, "com.other")
    }

    func testResolveByAppSucceeds() throws {
        let pid = 1234, windowId = 11
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        apps.resolved = AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)
        let cap = captureWith(windowId: windowId, pid: pid)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())

        let session = try mgr.resolveSession("get_app_state", ["app": "Example"])
        XCTAssertEqual(session.target.bundleId, "com.example")
    }

    func testIntParamTolerance() {
        XCTAssertEqual(anyToInt(7), 7)
        XCTAssertEqual(anyToInt("42"), 42)
        XCTAssertEqual(anyToInt(3.9), 3)
    }

    // MARK: execute() pipeline gating

    func testExecuteGetAppStateDoesNotMonitorInteraction() throws {
        let pid = 5, windowId = 21
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        apps.resolved = apps.running.first
        let cap = captureWith(windowId: windowId, pid: pid)
        let interaction = FakeUserInteraction()
        interaction.interruption = "USER TOUCHED IT"  // would yield IF monitored
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap, userInteraction: interaction),
            flags: flags())

        // get_app_state is state-only → interruption is NOT checked, no yield.
        let response = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result, "App state retrieved.")
        XCTAssertEqual(response.app, "com.example")
        XCTAssertNotNil(response.treeText)
    }

    func testExecuteGetAppStateDeliversAxPoorGuidanceOnce() throws {
        let pid = 6, windowId = 22
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        apps.resolved = apps.running.first
        let cap = captureWith(windowId: windowId, pid: pid)
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "group", depth: 0)]  // 0 interactive → AX-poor
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: ax, capture: cap),
            flags: flags())

        let first = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNotNil(first.guidance)
        XCTAssertTrue(first.guidance?.contains("limited accessibility support") ?? false)

        // Once-per-session: second call carries no guidance.
        let second = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(second.guidance)
    }

    func testExecuteGetAppStateInjectsCuratedPlaybookAndFormats() throws {
        let pid = 7, windowId = 23
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Safari", bundleId: "com.apple.Safari", pid: pid, running: true)]
        apps.resolved = apps.running.first
        let cap = captureWith(windowId: windowId, pid: pid)
        let ax = FakeAccessibility()
        // Rich (AX-good) tree → only the curated playbook, no AX-poor hint.
        ax.tree = [
            Node(index: 0, role: "group", depth: 0),
            Node(index: 1, role: "button", depth: 1),
            Node(index: 2, role: "textField", depth: 1),
        ]
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: ax, capture: cap),
            flags: flags())

        let first = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNotNil(first.guidance)
        XCTAssertTrue(first.guidance?.contains("Safari Tips") ?? false)

        // Rendered into the model packet as an app_specific_instructions block.
        let blocks = formatMCP(first)
        guard case let .text(text) = blocks[0] else {
            return XCTFail("first block should be text")
        }
        XCTAssertTrue(text.contains("<app_specific_instructions>"))
        XCTAssertTrue(text.contains("Safari Tips"))

        // Once-per-session: second call carries no guidance.
        let second = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(second.guidance)
    }

    func testExecuteActionToolMissingTargetReturnsErrorNotThrow() {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        // No window_id/app → resolveSession throws .automation → caught, snapshot
        // unavailable (no session) → errorOnly. execute() never throws.
        let response = mgr.execute("click", [:])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("requires window_id or app") ?? false)
    }

    // MARK: error / interruption arms

    func testInterruptionArmYieldsForActionTool() throws {
        let pid = 8, windowId = 33
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())

        // Establish + mark the session yielded by the user.
        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        mgr.invalidateSessionForUserChange(session, "The user changed the target app.")

        // An action tool on a yielded session: resolveSession() raises the
        // user-interruption error BEFORE the local `session` is bound, so (as in
        // Python) execute() falls through to errorOnly (app "unknown").
        let response = mgr.execute("click", ["window_id": windowId])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("user changed the target app") ?? false)
        XCTAssertEqual(response.app, "unknown")

        // get_app_state clears the yield state.
        let cleared = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(cleared.error)
        XCTAssertFalse(session.userStateInvalidated)
    }

    func testStaleReferenceArmFromResolveIndex() throws {
        let pid = 9, windowId = 44
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())
        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])

        // No refetchable tree + empty tree_nodes → resolveIndex throws .badIndex.
        XCTAssertThrowsError(try mgr.resolveIndex(session, 0)) { error in
            XCTAssertEqual((error as? AutomationError)?.kind, .badIndex)
        }

        // A populated direct lookup succeeds.
        session.treeNodes = [Node(index: 0, role: "button", depth: 0)]
        let node = try mgr.resolveIndex(session, 0)
        XCTAssertEqual(node.role, "button")
    }

    func testWindowGoneRaisesAndDropsSession() throws {
        let pid = 10, windowId = 66
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())
        _ = try mgr.resolveSession("get_app_state", ["window_id": windowId])

        // Window disappears: getWindowPid now returns nil for a fresh window id.
        cap.windows = []
        XCTAssertThrowsError(try mgr.getOrCreateSessionForWindow(windowId)) { error in
            XCTAssertEqual((error as? AutomationError)?.kind, .automation)
        }
    }

    // MARK: list_apps assembly

    func testListAppsAssembly() {
        let apps = FakeAppResolver()
        apps.running = [
            AppInfo(name: "Example", bundleId: "com.example", pid: 100, running: true),
        ]
        apps.recent = [
            AppInfo(name: "Notes", bundleId: "com.apple.notes", running: false),
        ]
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: 5, ownerPid: 100, ownerName: "Example", title: "Doc",
                       x: 0, y: 0, width: 640, height: 480, onscreen: true),
            // A window owned by a pid not in running → "extra running" branch.
            WindowInfo(windowId: 6, ownerPid: 200, ownerName: "Ghost", title: nil,
                       x: 1, y: 2, width: 10, height: 20, onscreen: true),
        ]
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap), flags: flags())

        let response = mgr.execute("list_apps", [:])
        let text = response.result ?? ""
        XCTAssertTrue(text.contains("Example \u{2014} com.example [running, pid=100]"))
        XCTAssertTrue(text.contains("window_id=5"))
        XCTAssertTrue(text.contains("title='Doc'"))
        XCTAssertTrue(text.contains("Ghost \u{2014} pid.200 [running, pid=200]"))
        XCTAssertTrue(text.contains("title=\"(untitled)\""))
        XCTAssertTrue(text.contains("Notes \u{2014} com.apple.notes ["))
    }

    func testListAppsSkipsRecentDuplicatesOfRunning() {
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: 1, running: true)]
        apps.recent = [AppInfo(name: "Example", bundleId: "com.example", running: false)]
        let mgr = SessionManager(providers: makeFakeProviders(apps: apps), flags: flags())
        let text = mgr.execute("list_apps", [:]).result ?? ""
        // The recent entry duplicates a running bundle → only the running line.
        let occurrences = text.components(separatedBy: "com.example").count - 1
        XCTAssertEqual(occurrences, 1)
    }
}
