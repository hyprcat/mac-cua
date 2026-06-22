import XCTest
import MacCUACore
@testable import MacCUAServer

/// Linux-buildable port of the session-resolution scenarios in
/// `tests/test_session.py`: window-id reuse, cross-running-app fallback,
/// cached-session-by-app-hint reuse, AX-window-signature-match failure window
/// fallback, and the user-invalidation block/clear gate. Drives the spine's
/// internal resolution helpers directly against the fakes.
final class SessionResolutionTests: XCTestCase {

    private func flags() -> FeatureFlags {
        FeatureFlags(
            treePruning: false,
            userInterruptionDetection: true,
            focusEnforcement: false,
            menuTracking: false,
            transientGraphs: false,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: false,
            confirmedDelivery: false)
    }

    private func makeManager(
        apps: FakeAppResolver, capture: FakeCapture,
        accessibility: FakeAccessibility = FakeAccessibility()
    ) -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: accessibility, capture: capture),
            flags: flags())
    }

    private func target(
        bundleId: String = "com.example.App", pid: Int = 111,
        windowId: Int = 77, windowPid: Int = 111
    ) -> AppTarget {
        AppTarget(
            bundleId: bundleId, pid: pid, windowId: windowId, windowPid: windowPid,
            axApp: FakeAXRef("ax-app-\(pid)"), axWindow: FakeAXRef("ax-win-\(windowId)"))
    }

    // MARK: - window_id resolution

    /// Ports test_get_or_create_session_for_window_reuses_existing_session:
    /// an existing session for the window id is returned and its window_pid is
    /// refreshed to the live owner pid.
    func testGetOrCreateSessionForWindowReusesExisting() throws {
        let apps = FakeAppResolver()
        let cap = FakeCapture()
        cap.pidForWindowId = [77: 222]  // live owner pid differs from the cached one
        let mgr = makeManager(apps: apps, capture: cap)
        let session = AppSession(target: target(pid: 111, windowId: 77, windowPid: 111))
        mgr.sessions[77] = session

        let result = try mgr.getOrCreateSessionForWindow(77)
        XCTAssertTrue(result === session)
        XCTAssertEqual(session.target.windowPid, 222)
    }

    /// Ports test_get_or_create_session_for_window_falls_back_across_running_apps:
    /// when the owning pid has no matching AX window, resolution falls back across
    /// running apps and rebinds bundle/pid/AX while keeping the window id + pid.
    func testGetOrCreateSessionForWindowFallsBackAcrossRunningApps() throws {
        let windowId = 88, ownerPid = 222, helperPid = 333
        let ownerAXApp = FakeAXRef("owner-ax-app")
        let fallbackAXApp = FakeAXRef("helper-ax-app")
        let fallbackAXWindow = FakeAXRef("helper-ax-window")

        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Helper", bundleId: "com.example.Helper",
                               pid: helperPid, running: true)]
        apps.axAppForPid = [ownerPid: ownerAXApp, helperPid: fallbackAXApp]
        // resolveRunningAppByPid(ownerPid) → nil (the window's pid isn't a known app)

        let cap = FakeCapture()
        cap.pidForWindowId = [windowId: ownerPid]
        // AX-window matching: only the helper's window matches window id 88.
        cap.windowIdForAXWindow = { ref in ref === fallbackAXWindow ? windowId : nil }

        let ax = FakeAccessibility()
        // The owner app exposes no windows (signature match fails) → cross-app
        // search; the helper app exposes the window that matches id 88.
        ax.windowsForAXApp = { axApp in
            if axApp === fallbackAXApp { return [fallbackAXWindow] }
            return []
        }

        let mgr = makeManager(apps: apps, capture: cap, accessibility: ax)
        let session = try mgr.getOrCreateSessionForWindow(windowId)

        XCTAssertEqual(session.target.bundleId, "com.example.Helper")
        XCTAssertEqual(session.target.pid, helperPid)
        XCTAssertEqual(session.target.windowId, windowId)
        XCTAssertEqual(session.target.windowPid, ownerPid)
        XCTAssertTrue(session.target.axApp === fallbackAXApp)
        XCTAssertTrue(session.target.axWindow === fallbackAXWindow)
        XCTAssertTrue(mgr.sessions[windowId] === session)
    }

    /// Ports test_get_or_create_session_for_window (window gone): a window id with
    /// no live owner pid drops any cached session and raises.
    func testGetOrCreateSessionForWindowGoneRaises() {
        let apps = FakeAppResolver()
        let cap = FakeCapture()
        cap.pidForWindowId = [:]  // window 99 owned by nobody
        let mgr = makeManager(apps: apps, capture: cap)
        XCTAssertThrowsError(try mgr.getOrCreateSessionForWindow(99)) { error in
            XCTAssertEqual((error as? AutomationError)?.kind, .automation)
        }
    }

    // MARK: - app-hint resolution

    /// Ports test_get_or_create_session_reuses_cached_session_from_app_hint:
    /// a cached session whose bundle matches the app hint is reused (fast path)
    /// without calling resolveApp, as long as the window pid is still live.
    func testGetOrCreateSessionReusesCachedFromAppHint() throws {
        let apps = FakeAppResolver()
        // resolveApp must NOT be needed: leave it unresolvable so a call would throw.
        let cap = FakeCapture()
        cap.pidForWindowId = [55: 123]  // window still alive
        let mgr = makeManager(apps: apps, capture: cap)

        let session = AppSession(target: target(bundleId: "com.apple.finder", pid: 123, windowId: 55, windowPid: 123))
        mgr.sessions[55] = session
        mgr.bundleToWindow["com.apple.finder"] = 55

        let result = try mgr.getOrCreateSession("Finder")
        XCTAssertTrue(result === session)
        XCTAssertEqual(session.target.windowPid, 123)
    }

    /// Ports test_get_or_create_session_uses_window_fallback_when_signature_matching_fails:
    /// when AX-window signature matching fails (find_window_id_for_ax_window keeps
    /// returning nil), resolution falls back to the best window for the pid
    /// (titled, onscreen, largest) — window id 2 ("Downloads") over the untitled 1.
    func testGetOrCreateSessionUsesWindowFallbackWhenSignatureMatchingFails() throws {
        let pid = 123
        let apps = FakeAppResolver()
        apps.resolved = AppInfo(name: "Finder", bundleId: "com.apple.finder", pid: pid, running: true)
        apps.axApp = FakeAXRef("finder-ax-app")

        let ax = FakeAccessibility()
        ax.keyWindow = FakeAXRef("finder-key-window")

        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: 1, ownerPid: pid, ownerName: "Finder", title: nil,
                       x: 0, y: 0, width: 1920, height: 1080, onscreen: true),
            WindowInfo(windowId: 2, ownerPid: pid, ownerName: "Finder", title: "Downloads",
                       x: 100, y: 100, width: 1200, height: 800, onscreen: true),
        ]
        cap.pidForWindowId = [1: pid, 2: pid]
        // Signature matching always fails → triggers fallbackWindowIdForPid.
        cap.windowIdForAXWindow = { _ in nil }

        let mgr = makeManager(apps: apps, capture: cap, accessibility: ax)
        let session = try mgr.getOrCreateSession("Finder")

        // Titled window (2) beats untitled (1) even though it's smaller.
        XCTAssertEqual(session.target.windowId, 2)
        XCTAssertEqual(session.target.windowPid, pid)
        XCTAssertEqual(session.target.bundleId, "com.apple.finder")
    }

    // MARK: - user-invalidation gate (Invariant 16)

    /// Ports test_resolve_session_blocks_actions_after_user_invalidation:
    /// once a session is user-invalidated, action tools raise UserInterruption
    /// while get_app_state still resolves (so it can clear the block).
    func testResolveSessionBlocksActionsAfterUserInvalidation() throws {
        let apps = FakeAppResolver()
        let cap = FakeCapture()
        cap.pidForWindowId = [77: 111]
        let mgr = makeManager(apps: apps, capture: cap)
        let session = AppSession(target: target(bundleId: "com.microsoft.VSCode", windowId: 77))
        session.userStateInvalidated = true
        session.userStateInvalidatedMessage = "The user changed 'VSCode'. Re-query."
        mgr.sessions[77] = session

        XCTAssertThrowsError(try mgr.resolveSession("click", ["window_id": 77])) { error in
            XCTAssertEqual((error as? AutomationError)?.kind, .userInterruption)
        }

        // get_app_state is exempt from the block.
        let resolved = try mgr.resolveSession("get_app_state", ["window_id": 77])
        XCTAssertTrue(resolved === session)
    }

    /// Ports test_clear_user_invalidated_state_resets_block.
    func testClearUserInvalidatedStateResetsBlock() {
        let apps = FakeAppResolver()
        let mgr = makeManager(apps: apps, capture: FakeCapture())
        let session = AppSession(target: target())
        session.userStateInvalidated = true
        session.userStateInvalidatedMessage = "stale"

        mgr.clearUserInvalidatedState(session)
        XCTAssertFalse(session.userStateInvalidated)
        XCTAssertNil(session.userStateInvalidatedMessage)
    }

    /// Ports test_invalidate_session_for_user_change: invalidation flips the flag,
    /// stores the message, marks the persistent graph invalidated and closes
    /// transients.
    func testInvalidateSessionForUserChange() {
        let apps = FakeAppResolver()
        let mgr = makeManager(apps: apps, capture: FakeCapture())
        let session = AppSession(target: target())
        let persistent = session.graphRegistry.setPersistent(
            session.graphs, rootRef: FakeAXRef("p"), nodes: [], rootLocator: nil)
        let transient = session.graphRegistry.pushTransient(
            session.graphs, rootRef: FakeAXRef("t"), nodes: [], rootLocator: nil,
            source: nil, transientKind: "menu")

        mgr.invalidateSessionForUserChange(session, "changed")
        XCTAssertTrue(session.userStateInvalidated)
        XCTAssertEqual(session.userStateInvalidatedMessage, "changed")
        XCTAssertEqual(persistent.state, .invalidated)
        XCTAssertEqual(transient.state, .closed)
    }
}
