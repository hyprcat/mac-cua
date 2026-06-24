import XCTest
@testable import MacCUACore

// Ports the intent of `tests/test_tree_cache.py` plus locator-scoring coverage
// for `graphs.py`. All macOS seams are filled with injected fakes so the suite
// runs on Linux.

// MARK: - Fakes

/// Opaque AX handle stand-in (Python uses `object()` for `ax_ref`/`ax_window`).
private final class FakeRef: AXElementRef {}

/// Fake of `app/_lib/observer.py:TreeInvalidationMonitor` matching the behavior
/// exercised by the Python tests: certain notifications flip `isInvalidated`,
/// and `reset()` clears it.
private final class FakeMonitor: InvalidationMonitor {
    private(set) var isInvalidated = false

    func onNotification(_ name: String) {
        // Mirrors the monitor: structural AX notifications invalidate the tree.
        switch name {
        case "AXCreated", "AXUIElementDestroyed", "AXMoved", "AXResized":
            isInvalidated = true
        default:
            isInvalidated = true
        }
    }

    func reset() { isInvalidated = false }
}

// MARK: - Node factory (mirrors `_node` in the Python test)

private func node(_ index: Int, role: String = "AXButton", label: String? = "Ok", depth: Int = 1) -> Node {
    Node(
        index: index,
        role: "button",
        label: label,
        depth: depth,
        axRef: FakeRef(),
        axRole: role
    )
}

// MARK: - Cache hit / miss

final class TreeGraphTests_Cache: XCTestCase {
    func testCacheHitReturnsCachedNode() {
        let monitor = FakeMonitor()
        let nodes = [node(0), node(1)]
        let tree = RefetchableTree(nodes: nodes, monitor: monitor)

        let result = tree.element(0)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.node === nodes[0])
    }

    func testCacheMissTriggersRewalk() {
        let monitor = FakeMonitor()
        let original = [node(0, label: "Save"), node(1, label: "Cancel")]
        let new = [node(0, label: "Save"), node(1, label: "Cancel"), node(2, label: "Help")]
        var walkCalls = 0
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in walkCalls += 1; return new }
        )

        monitor.onNotification("AXCreated")

        let result = tree.element(0)
        XCTAssertTrue(result.success)
        XCTAssertEqual(walkCalls, 1)
    }

    func testGetNodesReturnsCacheWhenNotInvalidated() {
        let monitor = FakeMonitor()
        let nodes = [node(0)]
        let tree = RefetchableTree(nodes: nodes, monitor: monitor)
        XCTAssertEqual(tree.getNodes().count, 1)
        XCTAssertTrue(tree.getNodes()[0] === nodes[0])
    }

    func testGetNodesRewalksWhenInvalidated() {
        let monitor = FakeMonitor()
        let original = [node(0)]
        let refreshed = [node(0), node(1)]
        var calls = 0
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in calls += 1; return refreshed }
        )
        monitor.onNotification("AXUIElementDestroyed")

        let result = tree.getNodes()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(calls, 1)
    }
}

// MARK: - Element refetch

final class TreeGraphTests_Refetch: XCTestCase {
    func testSingleMatchAfterRefetchSucceeds() {
        let monitor = FakeMonitor()
        let original = [node(0, label: "Save")]
        let new = [node(0, label: "Save")]
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in new }
        )
        monitor.onNotification("AXCreated")

        let result = tree.element(0)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.node?.label, "Save")
    }

    func testZeroMatchesAfterRefetchReturnsNotFound() {
        let monitor = FakeMonitor()
        let original = [node(0, label: "TempButton")]
        let new = [node(0, label: "DifferentButton")]
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in new }
        )
        monitor.onNotification("AXUIElementDestroyed")

        let result = tree.element(0)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .notFound)
    }

    func testAmbiguousBeforeRefetchDetected() {
        let monitor = FakeMonitor()
        let original = [node(0, label: "Submit"), node(1, label: "Submit")]
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in original }
        )
        monitor.onNotification("AXCreated")

        let result = tree.element(0)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .ambiguousBefore)
    }

    func testAmbiguousAfterRefetchDisambiguatesByDepth() {
        let monitor = FakeMonitor()
        let original = [node(0, label: "Ok", depth: 1)]
        let new = [node(0, label: "Ok", depth: 1), node(1, label: "Ok", depth: 3)]
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in new }
        )
        monitor.onNotification("AXCreated")

        let result = tree.element(0)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.node?.depth, 1)
    }

    func testOutOfBoundsIndexReturnsNotFound() {
        let monitor = FakeMonitor()
        let tree = RefetchableTree(nodes: [node(0)], monitor: monitor)
        let result = tree.element(99)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .notFound)
    }

    func testNoMonitorReturnsNoInvalidationMonitor() {
        let tree = RefetchableTree(nodes: [node(0)], monitor: nil)
        let result = tree.element(0)
        XCTAssertEqual(result.errorCode, .noInvalidationMonitor)
    }

    func testRewalkFailureReturnsNotFound() {
        let monitor = FakeMonitor()
        struct AXError: Error {}
        let tree = RefetchableTree(
            nodes: [node(0)], monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in throw AXError() }
        )
        monitor.onNotification("AXCreated")

        let result = tree.element(0)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .notFound)
    }
}

// MARK: - Liveness-driven refetch (US-038)

final class TreeGraphTests_LivenessRefetch: XCTestCase {
    /// A dead-ref liveness refetch re-walks + rebinds EVEN WHEN the monitor is
    /// not invalidated (staleness truth is the dead ref, not the monitor) and
    /// rebinds by locator, NOT the same preorder index.
    func testRefetchForLivenessRewalksWhenNotInvalidated() {
        let monitor = FakeMonitor()  // never notified → isInvalidated == false
        // Tree mutated: the target ("Save") moved from index 0 to index 1.
        let original = [node(0, label: "Save")]
        let new = [node(0, label: "Help"), node(1, label: "Save")]
        var walkCalls = 0
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in walkCalls += 1; return new }
        )

        XCTAssertFalse(tree.isInvalidated)
        let result = tree.refetchForLiveness(0)
        XCTAssertEqual(walkCalls, 1, "must re-walk regardless of invalidation flag")
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.node?.label, "Save")
        XCTAssertEqual(result.node?.index, 1, "rebound to the moved element, not index 0")
    }

    func testRefetchForLivenessNotFoundWhenElementGone() {
        let monitor = FakeMonitor()
        let original = [node(0, label: "Gone")]
        let new = [node(0, label: "Other")]
        let tree = RefetchableTree(
            nodes: original, monitor: monitor,
            axWindow: FakeRef(), targetPid: 123,
            walkFn: { _, _ in new }
        )
        let result = tree.refetchForLiveness(0)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .notFound)
    }

    func testRefetchForLivenessOutOfBoundsReturnsNotFound() {
        let tree = RefetchableTree(nodes: [node(0)], monitor: FakeMonitor())
        let result = tree.refetchForLiveness(99)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorCode, .notFound)
    }
}

// MARK: - update()

final class TreeGraphTests_Update: XCTestCase {
    func testUpdateReplacesNodes() {
        let monitor = FakeMonitor()
        let tree = RefetchableTree(nodes: [node(0)], monitor: monitor)
        tree.update([node(0), node(1)])
        XCTAssertEqual(tree.nodes.count, 2)
    }

    func testUpdateResetsMonitor() {
        let monitor = FakeMonitor()
        let tree = RefetchableTree(nodes: [node(0)], monitor: monitor)
        monitor.onNotification("AXCreated")
        XCTAssertTrue(tree.isInvalidated)
        tree.update([node(0)])
        XCTAssertFalse(tree.isInvalidated)
    }

    func testClosedTransientGraphReopensAndRebindsByLocator() {
        let original = [node(0, label: "View")]
        let reopened = [node(0, label: "View")]
        annotateGraphNodes(original, graphId: "transient-1", generation: 1)
        annotateGraphNodes(reopened, graphId: "transient-1", generation: 2)

        var reopenCalls = 0
        let tree = RefetchableTree(
            nodes: original,
            monitor: nil,
            graphId: "transient-1",
            generation: 1,
            graphStateGetter: { .closed },
            reopenFn: { reopenCalls += 1; return reopened }
        )

        let result = tree.element(0)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.node?.label, "View")
        XCTAssertEqual(reopenCalls, 1)
    }
}

// MARK: - Locator scoring / matching (graphs.py)

final class TreeGraphTests_LocatorScore: XCTestCase {
    func testRoleMismatchRejectsWithNegative() {
        let n = node(0, role: "AXButton")
        let loc = GraphLocator(axRole: "AXMenuItem", depth: 1)
        XCTAssertEqual(locatorScore(n, loc), -1)
    }

    func testFullMatchBeatsPartial() {
        // Exact label + axId + description + value + depth match.
        let exact = Node(index: 0, role: "button", label: "Save", description: "save file",
                         value: "v", axId: "id1", depth: 2, axRole: "AXButton")
        let partial = Node(index: 1, role: "button", label: "Other", depth: 5, axRole: "AXButton")
        let loc = GraphLocator(axRole: "AXButton", label: "Save", description: "save file",
                               value: "v", axId: "id1", depth: 2)
        XCTAssertGreaterThan(locatorScore(exact, loc), locatorScore(partial, loc))
    }

    func testBaseScoreWeights() {
        // role matches (nil locator role would not gate); label/axId/etc all nil
        // in locator → no penalties, only base 8 + depth-equal 4 = 12.
        let n = Node(index: 0, role: "button", label: nil, depth: 3, axRole: "AXButton")
        let loc = GraphLocator(axRole: nil, label: nil, depth: 3)
        // base 8, depth equal +4, label nil==nil +12? No: node.label(nil)==loc.label(nil) -> +12
        // axId nil==nil -> +12, description nil==nil -> +4, value nil==nil -> +3, depth +4
        XCTAssertEqual(locatorScore(n, loc), 8 + 12 + 12 + 4 + 3 + 4)
    }

    func testDepthDistancePenalty() {
        let n = Node(index: 0, role: "button", label: nil, depth: 1, axRole: "AXButton")
        let loc = GraphLocator(axRole: nil, label: nil, depth: 5)
        // base 8 + label match 12 + axId match 12 + desc 4 + value 3, depth: -abs(1-5)= -4
        XCTAssertEqual(locatorScore(n, loc), 8 + 12 + 12 + 4 + 3 - 4)
    }

    func testMatchNodeByLocatorTieBreaksByLowestIndex() {
        // Two identical-scoring nodes; lower index wins.
        let a = node(2, label: "Ok")
        let b = node(5, label: "Ok")
        let loc = GraphLocator(axRole: "AXButton", label: "Ok", depth: 1)
        let matched = matchNodeByLocator([b, a], locator: loc)
        XCTAssertTrue(matched === a)
    }

    func testMatchNodeByLocatorNilReturnsNil() {
        XCTAssertNil(matchNodeByLocator([node(0)], locator: nil))
    }

    func testMatchNodeByLocatorNoCandidatesReturnsNil() {
        // role mismatch -> all rejected
        let loc = GraphLocator(axRole: "AXMenuItem", label: "Ok", depth: 1)
        XCTAssertNil(matchNodeByLocator([node(0), node(1)], locator: loc))
    }

    func testParentPathFullMatchBonus() {
        // annotate so nodes carry graphLocator with parent paths.
        let nodes = [
            node(0, role: "AXWindow", label: "Win", depth: 0),
            node(1, role: "AXGroup", label: "Grp", depth: 1),
            node(2, role: "AXButton", label: "Ok", depth: 2),
        ]
        annotateGraphNodes(nodes, graphId: "g", generation: 1)
        let target = nodes[2].graphLocator!
        // Scoring the same node against its own locator includes the +10 path
        // bonus and +3 sibling-ordinal bonus.
        let withPath = locatorScore(nodes[2], target)
        // A bare node (no graphLocator) scoring the same locator misses both.
        let bare = Node(index: 9, role: "button", label: "Ok", depth: 2, axRole: "AXButton")
        let withoutPath = locatorScore(bare, target)
        XCTAssertEqual(withPath - withoutPath, 10 + 3)
    }
}

// MARK: - annotate + registry

final class TreeGraphTests_Annotate: XCTestCase {
    func testAnnotateStampsGenerationAndLocator() {
        let nodes = [node(0, label: "A", depth: 0), node(1, label: "B", depth: 1)]
        annotateGraphNodes(nodes, graphId: "persistent-1", generation: 3)
        XCTAssertEqual(nodes[0].graphId, "persistent-1")
        XCTAssertEqual(nodes[0].graphGeneration, 3)
        XCTAssertNotNil(nodes[0].graphLocator)
        XCTAssertEqual(nodes[1].graphLocator?.depth, 1)
        // parent_path of nodes[1] is the depth-0 ancestor.
        XCTAssertEqual(nodes[1].graphLocator?.parentPath.count, 1)
    }

    func testAnnotateSiblingOrdinals() {
        // Two identical siblings under the same parent get ordinals 0 and 1.
        let nodes = [
            node(0, role: "AXGroup", label: "P", depth: 0),
            node(1, role: "AXButton", label: "Ok", depth: 1),
            node(2, role: "AXButton", label: "Ok", depth: 1),
        ]
        annotateGraphNodes(nodes, graphId: "g", generation: 1)
        XCTAssertEqual(nodes[1].graphLocator?.siblingOrdinal, 0)
        XCTAssertEqual(nodes[2].graphLocator?.siblingOrdinal, 1)
    }

    func testRegistrySetAndPushAndFind() {
        let reg = GraphRegistry()
        let graphs = SessionGraphs()
        let p = reg.setPersistent(graphs, rootRef: nil, nodes: [node(0)], rootLocator: nil)
        XCTAssertEqual(p.graphId, "persistent-1")
        XCTAssertEqual(graphs.activeGraphId, "persistent-1")

        let t = reg.pushTransient(graphs, rootRef: FakeRef(), nodes: [node(0)],
                                  rootLocator: nil, source: nil, transientKind: "menu")
        XCTAssertEqual(t.graphId, "transient-2")
        XCTAssertEqual(reg.activeGraph(graphs)?.graphId, "transient-2")
        XCTAssertTrue(reg.find(graphs, graphId: "persistent-1") === p)
        XCTAssertTrue(reg.find(graphs, graphId: nil) === t)
    }

    func testRegistrySetPersistentBumpsGeneration() {
        let reg = GraphRegistry()
        let graphs = SessionGraphs()
        let first = reg.setPersistent(graphs, rootRef: nil, nodes: [], rootLocator: nil)
        XCTAssertEqual(first.generation, 1)
        let second = reg.setPersistent(graphs, rootRef: nil, nodes: [], rootLocator: nil)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.generation, 2)
    }

    func testCloseTransientByRefUsesInjectedEquality() {
        let ref = FakeRef()
        let reg = GraphRegistry(refsEqual: defaultRefsEqual)
        let graphs = SessionGraphs()
        reg.setPersistent(graphs, rootRef: nil, nodes: [], rootLocator: nil)
        reg.pushTransient(graphs, rootRef: ref, nodes: [], rootLocator: nil,
                          source: nil, transientKind: "menu")
        let closed = reg.closeTransientByRef(graphs, rootRef: ref)
        XCTAssertNotNil(closed)
        XCTAssertEqual(closed?.state, .closed)
        XCTAssertTrue(graphs.transientStack.isEmpty)
        XCTAssertEqual(graphs.activeGraphId, "persistent-1")
    }
}
