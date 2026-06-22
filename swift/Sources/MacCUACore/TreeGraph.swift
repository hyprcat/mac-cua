import Foundation

// Port of `app/_lib/graphs.py` — the tree-graph locator type plus the
// locator scoring / matching algorithm used to re-find a cached node after the
// accessibility tree has changed underneath us.
//
// This file owns the REAL `GraphLocator` (the placeholder previously in
// Models.swift is removed). All scoring weights and tie-breaks are mirrored
// EXACTLY from Python — this is the accuracy mechanism for stale-node recovery.
//
// PURE logic only. The two macOS leaves in graphs.py — `_locator_from_ref` and
// `_refs_equal` — are expressed here as injection seams (`LocatorFromRef`,
// `RefsEqual`) so this module builds and tests on Linux.

// MARK: - Enums

/// Mirrors `graphs.py:GraphKind`.
public enum GraphKind: String, Sendable, Equatable {
    case persistent
    case transient
}

/// Mirrors `graphs.py:GraphState`. Drives the stale-graph recovery branch in
/// `RefetchableTree`. Per §5.3 the AX observers are NOT a correctness gate; this
/// state is queried lazily via an injected getter and combined with a re-walk.
public enum GraphState: String, Sendable, Equatable {
    case live
    case invalidated
    case closed
    case reopening
}

// MARK: - Ancestor signature

/// Mirrors `graphs.py:AncestorSignature = tuple[str | None, str | None, str | None]`.
/// A compact, comparable summary of an ancestor used in `parent_path`.
public struct AncestorSignature: Equatable, Sendable {
    public var axRole: String?
    public var label: String?
    /// `ax_id or description or value` — the first non-empty identity hint.
    public var identity: String?

    public init(axRole: String?, label: String?, identity: String?) {
        self.axRole = axRole
        self.label = label
        self.identity = identity
    }
}

// MARK: - GraphLocator

/// The REAL stale-node-recovery locator. Mirrors `graphs.py:GraphLocator`
/// (frozen dataclass). `frozen=True` → an immutable value type here.
///
/// Kept a `public struct` so `Node.graphLocator: GraphLocator?` in Models.swift
/// keeps compiling.
public struct GraphLocator: Equatable, Sendable {
    public var axRole: String?
    public var label: String?
    public var description: String?
    public var value: String?
    public var axId: String?
    public var depth: Int
    public var parentPath: [AncestorSignature]
    public var siblingOrdinal: Int

    public init(
        axRole: String? = nil,
        label: String? = nil,
        description: String? = nil,
        value: String? = nil,
        axId: String? = nil,
        depth: Int,
        parentPath: [AncestorSignature] = [],
        siblingOrdinal: Int = 0
    ) {
        self.axRole = axRole
        self.label = label
        self.description = description
        self.value = value
        self.axId = axId
        self.depth = depth
        self.parentPath = parentPath
        self.siblingOrdinal = siblingOrdinal
    }
}

// MARK: - Injection seams (macOS leaves of graphs.py)

/// Seam for `graphs.py:_locator_from_ref`. The macOS layer wires an
/// implementation that walks a single element ref into a depth-0 locator.
/// Pure/Linux callers may leave it `nil`.
public typealias LocatorFromRef = (_ element: AXElementRef) -> GraphLocator?

/// Seam for `graphs.py:_refs_equal`. The macOS layer wires CFEqual-based
/// identity. Default below mirrors the Python fallback (identity only).
public typealias RefsEqual = (_ left: AXElementRef?, _ right: AXElementRef?) -> Bool

/// Default reference-equality mirroring the Python fallback when CFEqual is
/// unavailable: `left is right` (object identity), with `None` handling.
public func defaultRefsEqual(_ left: AXElementRef?, _ right: AXElementRef?) -> Bool {
    if left === right { return true }
    if left == nil || right == nil { return false }
    return false
}

// MARK: - Graph records (pure bookkeeping from graphs.py)

/// Mirrors `graphs.py:TransientSource`.
public final class TransientSource {
    public var actionName: String
    public var nodeLocator: GraphLocator?
    public var graphKind: GraphKind
    public var description: String?
    /// `reopen: Callable[[], bool] | None` — repr=False in Python.
    public var reopen: (() -> Bool)?

    public init(
        actionName: String,
        nodeLocator: GraphLocator?,
        graphKind: GraphKind = .persistent,
        description: String? = nil,
        reopen: (() -> Bool)? = nil
    ) {
        self.actionName = actionName
        self.nodeLocator = nodeLocator
        self.graphKind = graphKind
        self.description = description
        self.reopen = reopen
    }
}

/// Mirrors `graphs.py:GraphRecord`. A mutable class (Python dataclass, mutated
/// in place by the registry).
public final class GraphRecord {
    public var graphId: String
    public var generation: Int
    /// Opaque AX root handle (repr=False). Never serialized.
    public var rootRef: AXElementRef?
    public var rootLocator: GraphLocator?
    public var sourceAction: String?
    public var sourceNodeLocator: GraphLocator?
    public var nodes: [Node]
    public var kind: GraphKind
    public var state: GraphState
    public var source: TransientSource?
    public var transientKind: String?
    /// Back-reference to the owning `RefetchableTree` (repr=False, Any in Python).
    public var refetchableTree: AnyObject?

    public init(
        graphId: String,
        generation: Int,
        rootRef: AXElementRef? = nil,
        rootLocator: GraphLocator? = nil,
        sourceAction: String? = nil,
        sourceNodeLocator: GraphLocator? = nil,
        nodes: [Node] = [],
        kind: GraphKind = .persistent,
        state: GraphState = .live,
        source: TransientSource? = nil,
        transientKind: String? = nil,
        refetchableTree: AnyObject? = nil
    ) {
        self.graphId = graphId
        self.generation = generation
        self.rootRef = rootRef
        self.rootLocator = rootLocator
        self.sourceAction = sourceAction
        self.sourceNodeLocator = sourceNodeLocator
        self.nodes = nodes
        self.kind = kind
        self.state = state
        self.source = source
        self.transientKind = transientKind
        self.refetchableTree = refetchableTree
    }
}

/// Mirrors `graphs.py:SessionGraphs`.
public final class SessionGraphs {
    public var persistentGraph: GraphRecord?
    public var transientStack: [GraphRecord]
    public var activeGraphId: String?

    public init(
        persistentGraph: GraphRecord? = nil,
        transientStack: [GraphRecord] = [],
        activeGraphId: String? = nil
    ) {
        self.persistentGraph = persistentGraph
        self.transientStack = transientStack
        self.activeGraphId = activeGraphId
    }
}

// MARK: - GraphRegistry

/// Mirrors `graphs.py:GraphRegistry`. Pure bookkeeping; the only macOS leaf it
/// touches (`_refs_equal`) is injected.
public final class GraphRegistry {
    private var counter = 0
    private let refsEqual: RefsEqual

    public init(refsEqual: @escaping RefsEqual = defaultRefsEqual) {
        self.refsEqual = refsEqual
    }

    private func nextId(_ kind: GraphKind) -> String {
        counter += 1
        return "\(kind.rawValue)-\(counter)"
    }

    @discardableResult
    public func setPersistent(
        _ graphs: SessionGraphs,
        rootRef: AXElementRef?,
        nodes: [Node],
        rootLocator: GraphLocator?
    ) -> GraphRecord {
        let record: GraphRecord
        if let existing = graphs.persistentGraph {
            existing.generation += 1
            existing.rootRef = rootRef
            existing.rootLocator = rootLocator
            existing.nodes = nodes
            existing.state = .live
            record = existing
        } else {
            record = GraphRecord(
                graphId: nextId(.persistent),
                generation: 1,
                rootRef: rootRef,
                rootLocator: rootLocator,
                nodes: nodes,
                kind: .persistent,
                state: .live
            )
            graphs.persistentGraph = record
        }
        if graphs.transientStack.isEmpty {
            graphs.activeGraphId = record.graphId
        }
        return record
    }

    @discardableResult
    public func pushTransient(
        _ graphs: SessionGraphs,
        rootRef: AXElementRef?,
        nodes: [Node],
        rootLocator: GraphLocator?,
        source: TransientSource?,
        transientKind: String?
    ) -> GraphRecord {
        let record: GraphRecord
        if let top = graphs.transientStack.last,
           refsEqual(top.rootRef, rootRef) {
            top.generation += 1
            top.rootRef = rootRef
            top.rootLocator = rootLocator
            top.nodes = nodes
            top.source = source
            top.sourceAction = source?.actionName
            top.sourceNodeLocator = source?.nodeLocator
            top.transientKind = transientKind
            top.state = .live
            record = top
        } else {
            record = GraphRecord(
                graphId: nextId(.transient),
                generation: 1,
                rootRef: rootRef,
                rootLocator: rootLocator,
                sourceAction: source?.actionName,
                sourceNodeLocator: source?.nodeLocator,
                nodes: nodes,
                kind: .transient,
                state: .live,
                source: source,
                transientKind: transientKind
            )
            graphs.transientStack.append(record)
        }
        graphs.activeGraphId = record.graphId
        return record
    }

    public func activeGraph(_ graphs: SessionGraphs) -> GraphRecord? {
        if let top = graphs.transientStack.last { return top }
        return graphs.persistentGraph
    }

    public func find(_ graphs: SessionGraphs, graphId: String?) -> GraphRecord? {
        guard let graphId else { return activeGraph(graphs) }
        if let p = graphs.persistentGraph, p.graphId == graphId { return p }
        for graph in graphs.transientStack.reversed() where graph.graphId == graphId {
            return graph
        }
        return nil
    }

    @discardableResult
    public func closeTransientByRef(_ graphs: SessionGraphs, rootRef: AXElementRef?) -> GraphRecord? {
        var index = graphs.transientStack.count - 1
        while index >= 0 {
            let graph = graphs.transientStack[index]
            if refsEqual(graph.rootRef, rootRef) {
                graph.state = .closed
                let closed = graphs.transientStack.remove(at: index)
                let active = activeGraph(graphs)
                graphs.activeGraphId = active?.graphId
                return closed
            }
            index -= 1
        }
        return nil
    }

    public func markTransientsClosed(_ graphs: SessionGraphs) {
        for graph in graphs.transientStack { graph.state = .closed }
        graphs.transientStack.removeAll()
        let active = activeGraph(graphs)
        graphs.activeGraphId = active?.graphId
    }
}

// MARK: - Annotation

/// Mirrors `graphs.py:annotate_graph_nodes`. Stamps each node with graph id,
/// generation and a freshly computed `GraphLocator` (depth, ancestor path of up
/// to 4 most-recent ancestors, and a per-(depth, signature, parent_path)
/// sibling ordinal).
public func annotateGraphNodes(_ nodes: [Node], graphId: String, generation: Int) {
    var lineage: [Node] = []
    // sibling_counts keyed by (depth, signature, parentPath). AncestorSignature
    // and [AncestorSignature] aren't Hashable, so we key on a stable String.
    var siblingCounts: [String: Int] = [:]

    for node in nodes {
        while lineage.count > node.depth {
            lineage.removeLast()
        }

        let parentPath = lineage.suffix(4).map { signature($0) }
        let sig = signature(node)
        let siblingKey = "\(node.depth)\u{1F}\(signatureKey(sig))\u{1F}\(pathKey(parentPath))"
        let ordinal = siblingCounts[siblingKey, default: 0]
        siblingCounts[siblingKey] = ordinal + 1

        node.graphId = graphId
        node.graphGeneration = generation
        node.graphLocator = GraphLocator(
            axRole: node.axRole,
            label: node.label,
            description: node.description,
            value: node.value,
            axId: node.axId,
            depth: node.depth,
            parentPath: parentPath,
            siblingOrdinal: ordinal
        )
        lineage.append(node)
    }
}

// MARK: - Matching / scoring

/// Mirrors `graphs.py:match_node_by_locator`. Scores every node, keeps the
/// non-negative ones, and returns the best by `(score, -index)` — i.e. highest
/// score, then lowest index as the tie-break.
public func matchNodeByLocator(_ nodes: [Node], locator: GraphLocator?) -> Node? {
    guard let locator else { return nil }

    var scored: [(score: Int, node: Node)] = []
    for node in nodes {
        let score = locatorScore(node, locator)
        if score >= 0 {
            scored.append((score, node))
        }
    }
    if scored.isEmpty { return nil }
    // Python: scored.sort(key=lambda i: (i[0], -i[1].index), reverse=True)
    // => primary: score descending; secondary: index ascending (lowest index wins).
    scored.sort { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.node.index < rhs.node.index
    }
    return scored[0].node
}

/// Mirrors `graphs.py:_locator_score` EXACTLY. Returns -1 to reject (ax_role
/// mismatch), otherwise an additive score with the documented weights.
public func locatorScore(_ node: Node, _ locator: GraphLocator) -> Int {
    if let role = locator.axRole, node.axRole != role {
        return -1
    }

    var score = 8

    if node.label == locator.label {
        score += 12
    } else if locator.label != nil {
        score -= 4
    }

    if node.axId == locator.axId {
        score += 12
    } else if locator.axId != nil {
        score -= 6
    }

    if node.description == locator.description {
        score += 4
    } else if locator.description != nil {
        score -= 1
    }

    if node.value == locator.value {
        score += 3
    } else if locator.value != nil {
        score -= 1
    }

    if node.depth == locator.depth {
        score += 4
    } else {
        score -= abs(node.depth - locator.depth)
    }

    if let nodeLocator = node.graphLocator {
        if nodeLocator.parentPath == locator.parentPath {
            score += 10
        } else {
            var shared = 0
            for (left, right) in zip(nodeLocator.parentPath, locator.parentPath) where left == right {
                shared += 1
            }
            score += shared * 2
        }
        if nodeLocator.siblingOrdinal == locator.siblingOrdinal {
            score += 3
        }
    }

    return score
}

/// Mirrors `graphs.py:_signature`.
func signature(_ node: Node) -> AncestorSignature {
    AncestorSignature(
        axRole: node.axRole,
        label: node.label,
        identity: node.axId ?? node.description ?? node.value
    )
}

// MARK: - Internal hashing helpers for sibling-ordinal keying

private func signatureKey(_ s: AncestorSignature) -> String {
    "\(s.axRole ?? "\u{0}")\u{1E}\(s.label ?? "\u{0}")\u{1E}\(s.identity ?? "\u{0}")"
}

private func pathKey(_ path: [AncestorSignature]) -> String {
    path.map(signatureKey).joined(separator: "\u{1D}")
}
