import XCTest
@testable import MacCUACore

final class TurnCacheTests: XCTestCase {

    private func makeAppState(_ bundleId: String) -> AppState {
        AppState(bundleId: bundleId, isActive: false, isRunning: true, windowTitle: "w")
    }

    // MARK: - name -> pid

    func testPidHitAndMiss() {
        let cache = TurnCache()
        XCTAssertNil(cache.pid(forName: "com.acme.app"))
        cache.setPid(forName: "com.acme.app", pid: 42)
        XCTAssertEqual(cache.pid(forName: "com.acme.app"), 42)
        XCTAssertNil(cache.pid(forName: "com.other.app"))
    }

    func testDeadPidIsEvictedOnNameLookup() {
        var alive = true
        let cache = TurnCache(isPidAlive: { _ in alive })
        cache.setPid(forName: "com.acme.app", pid: 7)
        XCTAssertEqual(cache.pid(forName: "com.acme.app"), 7)
        alive = false
        XCTAssertNil(cache.pid(forName: "com.acme.app"))
        // Stays evicted even if it comes back alive (entry was removed).
        alive = true
        XCTAssertNil(cache.pid(forName: "com.acme.app"))
    }

    // MARK: - pid -> AppState

    func testAppStateHitAndMiss() {
        let cache = TurnCache()
        XCTAssertNil(cache.appState(forPid: 7))
        let s = makeAppState("com.acme.app")
        cache.setAppState(s, forPid: 7)
        XCTAssertEqual(cache.appState(forPid: 7), s)
    }

    func testDeadPidEvictsAppState() {
        var alive = true
        let cache = TurnCache(isPidAlive: { _ in alive })
        cache.setAppState(makeAppState("a"), forPid: 9)
        XCTAssertNotNil(cache.appState(forPid: 9))
        alive = false
        XCTAssertNil(cache.appState(forPid: 9))
    }

    // MARK: - pid -> tree (batch reuse)

    func testBatchReusesPreActionTree() {
        let cache = TurnCache()
        var walks = 0
        func walk(pid: Int) -> [Node] {
            if let cached = cache.tree(forPid: pid) { return cached }
            walks += 1
            let tree = [Node(index: 0, role: "AXButton", depth: 0)]
            cache.setTree(tree, forPid: pid)
            return tree
        }
        // Three batch steps over the same pre-action tree => one walk.
        for _ in 0..<3 { _ = walk(pid: 100) }
        XCTAssertEqual(walks, 1)
        XCTAssertEqual(cache.tree(forPid: 100)?.count, 1)
    }

    // MARK: - invalidation

    func testInvalidatePidDropsEverythingForThatPid() {
        let cache = TurnCache()
        cache.setPid(forName: "com.acme.app", pid: 5)
        cache.setPid(forName: "com.acme.alias", pid: 5)
        cache.setPid(forName: "com.other.app", pid: 6)
        cache.setAppState(makeAppState("a"), forPid: 5)
        cache.setTree([Node(index: 0, role: "AXGroup", depth: 0)], forPid: 5)

        cache.invalidate(pid: 5)

        XCTAssertNil(cache.pid(forName: "com.acme.app"))
        XCTAssertNil(cache.pid(forName: "com.acme.alias"))
        XCTAssertNil(cache.appState(forPid: 5))
        XCTAssertNil(cache.tree(forPid: 5))
        // Unrelated pid untouched.
        XCTAssertEqual(cache.pid(forName: "com.other.app"), 6)
    }

    func testInvalidateTreeKeepsPidAndAppState() {
        let cache = TurnCache()
        cache.setPid(forName: "com.acme.app", pid: 5)
        cache.setAppState(makeAppState("a"), forPid: 5)
        cache.setTree([Node(index: 0, role: "AXGroup", depth: 0)], forPid: 5)

        cache.invalidateTree(pid: 5)

        XCTAssertNil(cache.tree(forPid: 5))
        XCTAssertEqual(cache.pid(forName: "com.acme.app"), 5)
        XCTAssertNotNil(cache.appState(forPid: 5))
    }

    func testClearWipesAll() {
        let cache = TurnCache()
        cache.setPid(forName: "a", pid: 1)
        cache.setAppState(makeAppState("a"), forPid: 1)
        cache.setTree([Node(index: 0, role: "AXGroup", depth: 0)], forPid: 1)
        cache.clear()
        XCTAssertNil(cache.pid(forName: "a"))
        XCTAssertNil(cache.appState(forPid: 1))
        XCTAssertNil(cache.tree(forPid: 1))
    }
}
