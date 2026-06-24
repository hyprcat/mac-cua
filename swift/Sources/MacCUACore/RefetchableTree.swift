import Foundation

// Port of `app/_lib/refetchable_tree.py` — the re-walk + rebind logic for a
// cached AX tree.
//
// Per §5.3 ("AX observers are NOT a correctness dependency"), the source of
// truth for staleness is: liveness-check + full re-walk + locator match. The
// invalidation monitor is only a fast-path optimisation, not the correctness
// gate. Every external/macOS dependency the Python class injects is expressed
// here as a protocol or closure so this module is pure and Linux-testable:
//   - walk_fn            -> WalkFn
//   - graph_state_getter -> GraphStateGetter
//   - reopen_fn          -> ReopenFn
//   - TreeInvalidationMonitor -> InvalidationMonitor protocol
//   - ax_window (opaque AX root handle) -> AXElementRef?

// MARK: - Injection seams

/// Seam for `walk_fn: Callable[..., list[Node]]`. Re-walks the AX subtree
/// rooted at `axWindow` for `targetPid`. Throwing mirrors the Python
/// try/except around the walk.
public typealias WalkFn = (_ axWindow: AXElementRef, _ targetPid: Int?) throws -> [Node]

/// Seam for `graph_state_getter: Callable[[], GraphState]`.
public typealias GraphStateGetter = () -> GraphState

/// Seam for `reopen_fn: Callable[[], list[Node] | None]`. Re-opens a closed
/// transient surface and returns its freshly walked nodes (or nil on failure).
public typealias ReopenFn = () -> [Node]?

/// Protocol seam for `app/_lib/observer.py:TreeInvalidationMonitor`. Only the
/// two members `RefetchableTree` actually uses are surfaced.
public protocol InvalidationMonitor: AnyObject {
    var isInvalidated: Bool { get }
    func reset()
}

// MARK: - Errors / result

/// Mirrors `refetchable_tree.py:RefetchErrorCode`.
public enum RefetchErrorCode: String, Sendable, Equatable {
    case noInvalidationMonitor = "no_monitor"
    case ambiguousBefore = "ambiguous_before_refetch"
    case ambiguousAfter = "ambiguous_after_refetch"
    case notFound = "not_found_after_refetch"
}

/// Mirrors `refetchable_tree.py:RefetchResult`.
public struct RefetchResult {
    public var node: Node?
    public var errorCode: RefetchErrorCode?
    public var errorMessage: String?

    public init(node: Node? = nil, errorCode: RefetchErrorCode? = nil, errorMessage: String? = nil) {
        self.node = node
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    /// Mirrors the Python `success` property.
    public var success: Bool {
        node != nil && errorCode == nil
    }
}

// MARK: - Equivalence helpers

/// Mirrors `refetchable_tree.py:_find_equivalent_elements`.
func findEquivalentElements(_ nodes: [Node], targetRole: String?, targetLabel: String?) -> [Node] {
    nodes.filter { $0.axRole == targetRole && $0.label == targetLabel }
}

// MARK: - RefetchableTree

/// Mirrors `refetchable_tree.py:RefetchableTree`. Cached AX tree with
/// re-walk-driven element rebinding.
public final class RefetchableTree {
    private var nodesStorage: [Node]
    private var monitor: InvalidationMonitor?
    private var axWindow: AXElementRef?
    private var targetPid: Int?
    private var walkFn: WalkFn?
    private var graphId: String?
    private var generation: Int
    private var graphStateGetter: GraphStateGetter?
    private var reopenFn: ReopenFn?

    public init(
        nodes: [Node],
        monitor: InvalidationMonitor?,
        axWindow: AXElementRef? = nil,
        targetPid: Int? = nil,
        walkFn: WalkFn? = nil,
        graphId: String? = nil,
        generation: Int = 0,
        graphStateGetter: GraphStateGetter? = nil,
        reopenFn: ReopenFn? = nil
    ) {
        self.nodesStorage = nodes
        self.monitor = monitor
        self.axWindow = axWindow
        self.targetPid = targetPid
        self.walkFn = walkFn
        self.graphId = graphId
        self.generation = generation
        self.graphStateGetter = graphStateGetter
        self.reopenFn = reopenFn
    }

    /// Current cached nodes.
    public var nodes: [Node] { nodesStorage }

    /// Whether the tree has been invalidated by AX notifications. No monitor =
    /// always assume invalidated (mirrors Python).
    public var isInvalidated: Bool {
        guard let monitor else { return true }
        return monitor.isInvalidated
    }

    /// Mirrors `get_nodes`. Fast path: cached nodes if not invalidated. Slow
    /// path: full re-walk.
    @discardableResult
    public func getNodes() -> [Node] {
        if !isInvalidated {
            return nodesStorage
        }
        if let newNodes = rewalk() {
            nodesStorage = newNodes
            monitor?.reset()
        }
        return nodesStorage
    }

    /// Mirrors `element(index)`. Look up an element by index, refetching if the
    /// graph generation moved, the graph is closed/reopening, or the tree was
    /// invalidated.
    public func element(_ index: Int) -> RefetchResult {
        if index < 0 || index >= nodesStorage.count {
            return RefetchResult(
                errorCode: .notFound,
                errorMessage: "Index \(index) out of bounds (tree has \(nodesStorage.count) elements)"
            )
        }

        let original = nodesStorage[index]

        let graphState = graphStateGetter?() ?? .live
        // Python: original.graph_generation not in (0, self._generation)
        let generationStale = (original.graphGeneration != 0 && original.graphGeneration != generation)
        if generationStale || graphState == .closed || graphState == .reopening {
            return recoverStaleGraph(original, graphState: graphState)
        }

        // Fast path: tree not invalidated → element still valid.
        if !isInvalidated {
            return RefetchResult(node: original)
        }

        // No monitor — can't determine invalidation state.
        if monitor == nil {
            return RefetchResult(
                errorCode: .noInvalidationMonitor,
                errorMessage: "No invalidation monitor attached to tree."
            )
        }

        // Slow path: tree invalidated → try to refetch.
        return refetchElement(original)
    }

    /// Liveness-driven refetch (US-038 / Inv 10). When a cheap AXRole probe on
    /// the cached ref fails, the caller forces a re-walk + GraphLocator rebind
    /// REGARDLESS of the invalidation flag — staleness truth is the dead ref, not
    /// the monitor. Returns the rebound node, or a `.notFound`/ambiguous error
    /// (the spine surfaces these as a stale-reference + tree refresh). Never
    /// returns the original dead node.
    public func refetchForLiveness(_ index: Int) -> RefetchResult {
        if index < 0 || index >= nodesStorage.count {
            return RefetchResult(
                errorCode: .notFound,
                errorMessage: "Index \(index) out of bounds (tree has \(nodesStorage.count) elements)"
            )
        }
        return refetchElement(nodesStorage[index])
    }

    /// Mirrors `_refetch_element`.
    private func refetchElement(_ original: Node) -> RefetchResult {
        let targetRole = original.axRole
        let targetLabel = original.label
        let locator = locatorForNode(original)

        // Step 1: ambiguity in the ORIGINAL tree.
        let existingMatches = findEquivalentElements(nodesStorage, targetRole: targetRole, targetLabel: targetLabel)
        if existingMatches.count > 1 {
            return RefetchResult(
                errorCode: .ambiguousBefore,
                errorMessage: "Multiple matches in current tree; ambiguous lookup "
                    + "(role=\(describe(targetRole)), label=\(describeRepr(targetLabel)), count=\(existingMatches.count))"
            )
        }

        // Step 2: re-walk.
        guard let newNodes = rewalk() else {
            return RefetchResult(
                errorCode: .notFound,
                errorMessage: "Failed to re-walk tree during refetch"
            )
        }

        nodesStorage = newNodes
        if graphId != nil {
            generation += 1
        }
        monitor?.reset()

        // Step 3: search for equivalent by locator.
        if let locator, let matched = matchNodeByLocator(newNodes, locator: locator) {
            return RefetchResult(node: matched)
        }

        let newMatches = findEquivalentElements(newNodes, targetRole: targetRole, targetLabel: targetLabel)

        // Step 4a: 0 matches.
        if newMatches.isEmpty {
            return RefetchResult(
                errorCode: .notFound,
                errorMessage: "Element gone after tree re-walk "
                    + "(role=\(describe(targetRole)), label=\(describeRepr(targetLabel)))"
            )
        }

        // Step 4b: 1 match.
        if newMatches.count == 1 {
            return RefetchResult(node: newMatches[0])
        }

        // Step 4c: N matches → disambiguate by position.
        if let positional = disambiguateByPosition(original, candidates: newMatches) {
            return RefetchResult(node: positional)
        }

        return RefetchResult(
            errorCode: .ambiguousAfter,
            errorMessage: "Multiple matches in new tree; ambiguous lookup "
                + "(role=\(describe(targetRole)), label=\(describeRepr(targetLabel)), count=\(newMatches.count))"
        )
    }

    /// Mirrors `_disambiguate_by_position`. Prefer same depth; among those (or
    /// all, if none share the depth) pick the one closest to the original index.
    private func disambiguateByPosition(_ original: Node, candidates: [Node]) -> Node? {
        let sameDepth = candidates.filter { $0.depth == original.depth }
        if sameDepth.count == 1 {
            return sameDepth[0]
        }
        let searchCandidates = sameDepth.isEmpty ? candidates : sameDepth
        // Python: min(..., key=lambda n: abs(n.index - original.index)).
        // min() returns the FIRST minimal element on ties.
        return searchCandidates.min { abs($0.index - original.index) < abs($1.index - original.index) }
    }

    /// Mirrors `_recover_stale_graph`.
    private func recoverStaleGraph(_ original: Node, graphState: GraphState) -> RefetchResult {
        let locator = locatorForNode(original)

        if graphState == .closed, let reopenFn {
            let newNodes = reopenFn()
            if let newNodes, !newNodes.isEmpty {
                nodesStorage = newNodes
                if graphId != nil {
                    generation += 1
                }
                if let locator, let matched = matchNodeByLocator(newNodes, locator: locator) {
                    return RefetchResult(node: matched)
                }
                return RefetchResult(
                    errorCode: .notFound,
                    errorMessage: "Transient graph reopened but target element could not be rebound"
                )
            }
            return RefetchResult(
                errorCode: .notFound,
                errorMessage: "Transient graph is closed and could not be reopened"
            )
        }

        if let locator {
            let newNodes = getNodes()
            if let matched = matchNodeByLocator(newNodes, locator: locator) {
                return RefetchResult(node: matched)
            }
        }

        return RefetchResult(
            errorCode: .notFound,
            errorMessage: "Graph generation changed and target element is stale"
        )
    }

    /// Mirrors `_rewalk`. Returns nil if unable (no walk_fn / no ax_window / walk
    /// threw). Annotates new nodes when this tree is graph-bound.
    private func rewalk() -> [Node]? {
        guard let walkFn, let axWindow else { return nil }
        do {
            let newNodes = try walkFn(axWindow, targetPid)
            if let graphId {
                annotateGraphNodes(newNodes, graphId: graphId, generation: generation + 1)
            }
            return newNodes
        } catch {
            return nil
        }
    }

    /// Mirrors `update`. Replaces cached tree and (optionally) rewires seams,
    /// then resets the monitor.
    public func update(
        _ nodes: [Node],
        axWindow: AXElementRef? = nil,
        monitor: InvalidationMonitor? = nil,
        targetPid: Int? = nil,
        walkFn: WalkFn? = nil,
        graphId: String? = nil,
        generation: Int? = nil,
        graphStateGetter: GraphStateGetter? = nil,
        reopenFn: ReopenFn? = nil
    ) {
        self.nodesStorage = nodes
        if let axWindow { self.axWindow = axWindow }
        if let monitor { self.monitor = monitor }
        if let targetPid { self.targetPid = targetPid }
        if let walkFn { self.walkFn = walkFn }
        if let graphId { self.graphId = graphId }
        if let generation { self.generation = generation }
        if let graphStateGetter { self.graphStateGetter = graphStateGetter }
        if let reopenFn { self.reopenFn = reopenFn }
        self.monitor?.reset()
    }

    /// Mirrors `_locator_for_node`.
    private func locatorForNode(_ node: Node) -> GraphLocator? {
        node.graphLocator
    }
}

// MARK: - repr helpers (for error-message parity with Python f-strings)

private func describe(_ value: String?) -> String {
    value ?? "None"
}

/// Mirrors Python's `{x!r}` for an optional string: `'foo'` or `None`.
private func describeRepr(_ value: String?) -> String {
    guard let value else { return "None" }
    return "'\(value)'"
}
