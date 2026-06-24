import XCTest
import MacCUACore
@testable import MacCUAServer

/// Linux-buildable tests for the `batch` tool (US-008 / Codex parity §D3):
/// sequential execution, stop-on-first-failure with remaining steps marked
/// not-run, exactly one final snapshot, per-step outcomes, and reuse of the
/// turn-scoped pre-action tree (US-004) instead of re-walking each step.
final class BatchTests: XCTestCase {

    private func captureWith(windowId: Int, pid: Int) -> FakeCapture {
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowId, ownerPid: pid, ownerName: "Example",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true)
        ]
        return cap
    }

    private func flags() -> FeatureFlags {
        FeatureFlags(
            userInterruptionDetection: false,
            focusEnforcement: false,
            transientGraphs: false,
            systemSelection: false)
    }

    // MARK: success path

    func testBatchSuccessPathRunsAllStepsAndReturnsFinalSnapshot() {
        let pid = 11, windowId = 71
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let input = FakeInput()
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, input: input, capture: cap), flags: flags())

        let response = mgr.execute("batch", [
            "actions": [
                ["tool": "press_key", "window_id": windowId, "key": "a"],
                ["tool": "press_key", "key": "b"],  // inherits the previous target
            ],
        ])

        XCTAssertNil(response.error)
        let result = response.result ?? ""
        XCTAssertTrue(result.contains("Step 1 [press_key]"), result)
        XCTAssertTrue(result.contains("Step 2 [press_key]"), result)
        XCTAssertTrue(result.contains("Batch complete: 2/2 steps succeeded."), result)
        // Both keys delivered, in order.
        XCTAssertEqual(input.keys, ["a", "b"])
        // Exactly one final snapshot.
        XCTAssertNotNil(response.treeText)
        XCTAssertEqual(response.app, "com.example")
    }

    // MARK: mid-batch failure halts the remainder

    func testBatchHaltsOnFirstFailure() {
        let pid = 12, windowId = 72
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let input = FakeInput()
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, input: input, capture: cap), flags: flags())

        let response = mgr.execute("batch", [
            "actions": [
                ["tool": "press_key", "window_id": windowId, "key": "a"],
                ["tool": "press_key"],  // missing key → fails
                ["tool": "press_key", "key": "c"],  // must NOT run
            ],
        ])

        let result = response.result ?? ""
        XCTAssertTrue(result.contains("Step 1 [press_key]"), result)
        XCTAssertTrue(result.contains("Step 2 [press_key]: FAILED"), result)
        XCTAssertTrue(result.contains("Step 3: not run (batch halted)."), result)
        XCTAssertTrue(result.contains("Batch halted on first failure (1/3 steps succeeded)."), result)
        // Only the first key was delivered; the third never ran.
        XCTAssertEqual(input.keys, ["a"])
        // A final snapshot is still produced (failproof).
        XCTAssertNotNil(response.treeText)
    }

    // MARK: empty / malformed input

    func testBatchEmptyActionsReturnsError() {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        let response = mgr.execute("batch", ["actions": [[String: Any]]()])
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.error?.contains("non-empty 'actions'") ?? false)
        XCTAssertNil(response.treeText)
    }

    func testBatchMissingActionsReturnsError() {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        let response = mgr.execute("batch", [:])
        XCTAssertNotNil(response.error)
    }

    func testBatchUnsupportedToolFails() {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        let response = mgr.execute("batch", [
            "actions": [["tool": "get_app_state", "window_id": 1]],
        ])
        let result = response.result ?? ""
        XCTAssertTrue(result.contains("unsupported batch tool 'get_app_state'"), result)
    }

    func testBatchFirstActionWithoutTargetFails() {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        let response = mgr.execute("batch", [
            "actions": [["tool": "press_key", "key": "a"]],  // no window_id/app on first step
        ])
        let result = response.result ?? ""
        XCTAssertTrue(result.contains("first batch action must specify window_id or app"), result)
    }

    // MARK: pre-action tree reuse (US-004)

    func testBatchReusesPreActionTreeInsteadOfReWalking() {
        let pid = 13, windowId = 73
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Example", bundleId: "com.example", pid: pid, running: true)]
        let cap = captureWith(windowId: windowId, pid: pid)
        let ax = FakeAccessibility()
        let ref = FakeAXRef("node-0")
        ax.tree = [Node(index: 0, role: "text field", depth: 0, axRef: ref)]
        let input = FakeInput()
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: ax, input: input, capture: cap),
            flags: flags())

        // Three element-index actions over the same window: the tree is walked
        // once up-front (pre-action) + once for the final snapshot = 2 walks
        // total, regardless of the number of steps (no re-walk per step).
        let response = mgr.execute("batch", [
            "actions": [
                ["tool": "press_key", "window_id": windowId, "element_index": "0", "key": "a"],
                ["tool": "press_key", "element_index": "0", "key": "b"],
                ["tool": "press_key", "element_index": "0", "key": "c"],
            ],
        ])

        XCTAssertNil(response.error)
        XCTAssertEqual(input.keys, ["a", "b", "c"])
        XCTAssertTrue((response.result ?? "").contains("3/3 steps succeeded"))
        XCTAssertEqual(ax.walkCount, 2, "pre-action tree should be reused, not re-walked per step")
    }
}
