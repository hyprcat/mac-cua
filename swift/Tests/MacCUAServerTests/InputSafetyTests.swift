import XCTest
import MacCUACore
@testable import MacCUAServer

/// US-047 — input safety gate: refuse synthetic input against sensitive targets
/// (terminals, Keychain/SecurityAgent) and while the screen is locked, while
/// leaving read-only tools (`get_app_state`) untouched. Runs through the public
/// `execute()` entry so the `dispatch` gate is exercised end-to-end.
final class InputSafetyTests: XCTestCase {

    private func makeManager(
        bundleId: String,
        screenLock: ScreenLockProvider? = nil
    ) -> (SessionManager, Int) {
        let pid = 4242, windowId = 99
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "App", bundleId: bundleId, pid: pid, running: true)]
        apps.resolved = apps.running.first
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowId, ownerPid: pid, ownerName: "App",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true)
        ]
        let flags = FeatureFlags(
            userInterruptionDetection: false, focusEnforcement: false,
            transientGraphs: false, systemSelection: false)
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, capture: cap, screenLock: screenLock),
            flags: flags)
        return (mgr, windowId)
    }

    func testClickRefusedAgainstTerminal() {
        let (mgr, windowId) = makeManager(bundleId: "com.apple.Terminal")
        let r = mgr.execute("click", ["window_id": windowId, "index": 0])
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.error?.contains("sensitive process") ?? false, r.error ?? "no error")
    }

    func testTypeRefusedAgainstKeychain() {
        let (mgr, windowId) = makeManager(bundleId: "com.apple.keychainaccess")
        let r = mgr.execute("type_text", ["window_id": windowId, "text": "secret"])
        XCTAssertNotNil(r.error)
    }

    func testReadAllowedAgainstTerminal() {
        // get_app_state is read-only — the input gate must NOT block it.
        let (mgr, windowId) = makeManager(bundleId: "com.apple.Terminal")
        let r = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(r.error)
        XCTAssertEqual(r.result, "App state retrieved.")
    }

    func testInputRefusedWhenScreenLocked() {
        let (mgr, windowId) = makeManager(
            bundleId: "com.example.app", screenLock: FakeScreenLock(locked: true))
        let r = mgr.execute("click", ["window_id": windowId, "index": 0])
        XCTAssertNotNil(r.error)
        XCTAssertTrue(r.error?.contains("locked") ?? false, r.error ?? "no error")
    }

    func testInputAllowedWhenUnlockedAndSafeApp() {
        // Unlocked + normal app: the gate passes (any later error is NOT the gate).
        let (mgr, windowId) = makeManager(
            bundleId: "com.example.app", screenLock: FakeScreenLock(locked: false))
        let r = mgr.execute("click", ["window_id": windowId, "index": 0])
        if let err = r.error {
            XCTAssertFalse(err.contains("locked"))
            XCTAssertFalse(err.contains("sensitive process"))
        }
    }

    func testReadAllowedWhenScreenLocked() {
        let (mgr, windowId) = makeManager(
            bundleId: "com.example.app", screenLock: FakeScreenLock(locked: true))
        let r = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(r.error)
    }
}
