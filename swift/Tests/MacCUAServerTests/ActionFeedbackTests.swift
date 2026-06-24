import XCTest
import MacCUACore
@testable import MacCUAServer

/// US-039: the action-feedback packet (F) is populated with real values after an
/// action, and read-only tools carry no packet. Driven through the real spine
/// against fakes (Linux-green).
final class ActionFeedbackTests: XCTestCase {
    private let pid = 222
    private let windowId = 88

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

    private func flags() -> FeatureFlags {
        FeatureFlags(
            treePruning: false, userInterruptionDetection: false, focusEnforcement: false,
            menuTracking: false, transientGraphs: false, axActionVerification: false,
            cgeventActionVerification: false, systemSelection: false, confirmedDelivery: false)
    }

    private func manager() -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(apps: apps(), capture: capture()),
            flags: flags())
    }

    func testCoordinateClickPopulatesFeedback() throws {
        let mgr = manager()
        let resp = mgr.execute("click", ["window_id": windowId, "x": 12.0, "y": 34.0])
        let fb = try XCTUnwrap(resp.actionFeedback, "click must carry an action-feedback packet")
        XCTAssertEqual(fb.deliveryPath, .cgEvent)
        XCTAssertEqual(fb.windowId, windowId)
        XCTAssertEqual(fb.cursorAfter, Point(x: 12.0, y: 34.0))
        XCTAssertNotNil(fb.changeSummary)
    }

    func testCursorBeforeReflectsPriorAction() throws {
        let mgr = manager()
        _ = mgr.execute("click", ["window_id": windowId, "x": 5.0, "y": 6.0])
        let resp = mgr.execute("click", ["window_id": windowId, "x": 7.0, "y": 8.0])
        let fb = try XCTUnwrap(resp.actionFeedback)
        XCTAssertEqual(fb.cursorBefore, Point(x: 5.0, y: 6.0))
        XCTAssertEqual(fb.cursorAfter, Point(x: 7.0, y: 8.0))
    }

    func testGetAppStateHasNoFeedback() {
        let mgr = manager()
        let resp = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(resp.actionFeedback)
    }

    func testListAppsHasNoFeedback() {
        let mgr = manager()
        let resp = mgr.execute("list_apps", [:])
        XCTAssertNil(resp.actionFeedback)
    }

    func testSessionGetsBackgroundCursorWiredToGhost() throws {
        let mgr = manager()
        let session = try mgr.resolveSession("get_app_state", ["window_id": windowId])
        XCTAssertNotNil(session.cursor, "each session must own a BackgroundCursor")
        // The ghost controller tracks the session's window (distinct tint assigned).
        XCTAssertNotNil(mgr.ghostController.style(forWindowId: windowId))
    }
}
