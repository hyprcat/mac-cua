import XCTest
import MacCUACore
@testable import MacCUAServer

/// `wait` tool (Codex parity §D4, US-009). Verifies it drives the
/// `DebounceStateMachine` through the `SettleMonitor` seam with the requested
/// timeout and returns a fresh snapshot — on both the settles and the hit-the-cap
/// paths. No Python reference; behavior is asserted against the fakes.
final class WaitTests: XCTestCase {

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
            treePruning: false,
            userInterruptionDetection: true,
            focusEnforcement: false,
            menuTracking: true,
            transientGraphs: true,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: false,
            confirmedDelivery: false)
    }

    private func manager(_ factory: RecordingSettleFactory) -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(), makeSettleMonitor: factory.make),
            flags: flags())
    }

    /// Default wait drives one settle with the default 2.0s budget and the shared
    /// quiet period, then returns a snapshot (settled path).
    func testWaitSettlesWithDefaultTimeout() {
        let factory = RecordingSettleFactory()
        let mgr = manager(factory)

        let resp = mgr.execute("wait", ["window_id": windowId])

        XCTAssertEqual(factory.last?.calls.count, 1)
        XCTAssertEqual(factory.last?.calls.first?.context, "wait")
        XCTAssertEqual(factory.last?.calls.first?.timeout, SessionManager.waitDefaultTimeout)
        XCTAssertEqual(factory.last?.calls.first?.quietPeriod, settleQuietPeriod)
        XCTAssertNil(resp.error)
        XCTAssertNotNil(resp.screenshot)        // a fresh snapshot was captured
        XCTAssertEqual(resp.result, "UI settled.")
    }

    /// A caller-supplied timeout is passed through to the settle monitor.
    func testWaitUsesRequestedTimeout() {
        let factory = RecordingSettleFactory()
        let mgr = manager(factory)

        _ = mgr.execute("wait", ["window_id": windowId, "timeout": 3.5])

        XCTAssertEqual(factory.last?.calls.first?.timeout, 3.5)
    }

    /// The timeout is clamped to the 10.0s cap.
    func testWaitClampsTimeoutToCap() {
        let factory = RecordingSettleFactory()
        let mgr = manager(factory)

        _ = mgr.execute("wait", ["window_id": windowId, "timeout": 999.0])

        XCTAssertEqual(factory.last?.calls.first?.timeout, SessionManager.waitMaxTimeout)
    }

    /// Hit-the-cap path: when the machine never quiesces (returns `.timeout`),
    /// wait still returns a snapshot and reports the cap honestly.
    func testWaitHitsCap() {
        let factory = RecordingSettleFactory()
        let monitor = FakeSettleMonitor()
        monitor.result = .timeout
        factory.preset = monitor
        let mgr = manager(factory)

        let resp = mgr.execute("wait", ["window_id": windowId, "timeout": 1.0])

        XCTAssertEqual(monitor.waits, 1)
        XCTAssertNil(resp.error)
        XCTAssertNotNil(resp.screenshot)
        XCTAssertTrue(resp.result?.contains("hit the wait cap") ?? false)
    }

    /// A zero/negative timeout skips the settle entirely (nothing to wait for)
    /// but still returns a fresh snapshot.
    func testWaitZeroTimeoutSkipsSettle() {
        let factory = RecordingSettleFactory()
        let mgr = manager(factory)

        let resp = mgr.execute("wait", ["window_id": windowId, "timeout": 0.0])

        XCTAssertEqual(factory.last?.waits, 0)
        XCTAssertNil(resp.error)
        XCTAssertNotNil(resp.screenshot)
        XCTAssertEqual(resp.result, "UI was already quiet — nothing to wait for.")
    }

    /// Unresolvable target → a clean error response (no crash, no settle).
    func testWaitWithoutTargetErrors() {
        let factory = RecordingSettleFactory()
        let mgr = manager(factory)

        let resp = mgr.execute("wait", [:])

        XCTAssertNotNil(resp.error)
    }
}
