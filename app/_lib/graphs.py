from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable

from app.response import Node
from app._lib import accessibility

logger = logging.getLogger(__name__)


class GraphKind(str, Enum):
    PERSISTENT = "persistent"
    TRANSIENT = "transient"


class GraphState(str, Enum):
    LIVE = "live"
    INVALIDATED = "invalidated"
    CLOSED = "closed"
    REOPENING = "reopening"


AncestorSignature = tuple[str | None, str | None, str | None]


@dataclass(frozen=True)
class GraphLocator:
    ax_role: str | None
    label: str | None
    description: str | None
    value: str | None
    ax_id: str | None
    depth: int
    parent_path: tuple[AncestorSignature, ...] = ()
    sibling_ordinal: int = 0


@dataclass
class TransientSource:
    action_name: str
    node_locator: GraphLocator | None
    graph_kind: GraphKind = GraphKind.PERSISTENT
    description: str | None = None
    reopen: Callable[[], bool] | None = field(default=None, repr=False)


@dataclass
class GraphRecord:
    graph_id: str
    generation: int
    root_ref: Any = field(default=None, repr=False)
    root_locator: GraphLocator | None = None
    source_action: str | None = None
    source_node_locator: GraphLocator | None = None
    nodes: list[Node] = field(default_factory=list)
    kind: GraphKind = GraphKind.PERSISTENT
    state: GraphState = GraphState.LIVE
    source: TransientSource | None = None
    transient_kind: str | None = None
    refetchable_tree: Any = field(default=None, repr=False)


@dataclass
class SessionGraphs:
    persistent_graph: GraphRecord | None = None
    transient_stack: list[GraphRecord] = field(default_factory=list)
    active_graph_id: str | None = None


@dataclass
class TransientSurface:
    root_ref: Any = field(repr=False)
    locator: GraphLocator | None
    kind: str
    opened_at: float = field(default_factory=time.monotonic)
    closed: bool = False


class GraphRegistry:
    def __init__(self) -> None:
        self._counter = 0

    def _next_id(self, kind: GraphKind) -> str:
        self._counter += 1
        return f"{kind.value}-{self._counter}"

    def set_persistent(
        self,
        graphs: SessionGraphs,
        *,
        root_ref: Any,
        nodes: list[Node],
        root_locator: GraphLocator | None,
    ) -> GraphRecord:
        record = graphs.persistent_graph
        if record is None:
            record = GraphRecord(
                graph_id=self._next_id(GraphKind.PERSISTENT),
                generation=1,
                root_ref=root_ref,
                root_locator=root_locator,
                nodes=nodes,
                kind=GraphKind.PERSISTENT,
                state=GraphState.LIVE,
            )
            graphs.persistent_graph = record
        else:
            record.generation += 1
            record.root_ref = root_ref
            record.root_locator = root_locator
            record.nodes = nodes
            record.state = GraphState.LIVE
        if not graphs.transient_stack:
            graphs.active_graph_id = record.graph_id
        return record

    def push_transient(
        self,
        graphs: SessionGraphs,
        *,
        root_ref: Any,
        nodes: list[Node],
        root_locator: GraphLocator | None,
        source: TransientSource | None,
        transient_kind: str | None,
    ) -> GraphRecord:
        if graphs.transient_stack and _refs_equal(graphs.transient_stack[-1].root_ref, root_ref):
            record = graphs.transient_stack[-1]
            record.generation += 1
            record.root_ref = root_ref
            record.root_locator = root_locator
            record.nodes = nodes
            record.source = source
            record.source_action = source.action_name if source is not None else None
            record.source_node_locator = source.node_locator if source is not None else None
            record.transient_kind = transient_kind
            record.state = GraphState.LIVE
        else:
            record = GraphRecord(
                graph_id=self._next_id(GraphKind.TRANSIENT),
                generation=1,
                root_ref=root_ref,
                root_locator=root_locator,
                source_action=source.action_name if source is not None else None,
                source_node_locator=source.node_locator if source is not None else None,
                nodes=nodes,
                kind=GraphKind.TRANSIENT,
                state=GraphState.LIVE,
                source=source,
                transient_kind=transient_kind,
            )
            graphs.transient_stack.append(record)
        graphs.active_graph_id = record.graph_id
        return record

    def active_graph(self, graphs: SessionGraphs) -> GraphRecord | None:
        if graphs.transient_stack:
            return graphs.transient_stack[-1]
        return graphs.persistent_graph

    def find(self, graphs: SessionGraphs, graph_id: str | None) -> GraphRecord | None:
        if graph_id is None:
            return self.active_graph(graphs)
        if graphs.persistent_graph is not None and graphs.persistent_graph.graph_id == graph_id:
            return graphs.persistent_graph
        for graph in reversed(graphs.transient_stack):
            if graph.graph_id == graph_id:
                return graph
        return None

    def close_transient_by_ref(self, graphs: SessionGraphs, root_ref: Any) -> GraphRecord | None:
        for index in range(len(graphs.transient_stack) - 1, -1, -1):
            graph = graphs.transient_stack[index]
            if _refs_equal(graph.root_ref, root_ref):
                graph.state = GraphState.CLOSED
                closed = graphs.transient_stack.pop(index)
                active = self.active_graph(graphs)
                graphs.active_graph_id = active.graph_id if active is not None else None
                return closed
        return None

    def mark_transients_closed(self, graphs: SessionGraphs) -> None:
        for graph in graphs.transient_stack:
            graph.state = GraphState.CLOSED
        graphs.transient_stack.clear()
        active = self.active_graph(graphs)
        graphs.active_graph_id = active.graph_id if active is not None else None


class TransientGraphTracker:
    def __init__(self) -> None:
        self._stack: list[TransientSurface] = []
        self._open_event = threading.Event()
        self._close_event = threading.Event()
        self._lock = threading.Lock()
        self._event_counter = 0

    @property
    def event_counter(self) -> int:
        with self._lock:
            return self._event_counter

    @property
    def has_active_transient(self) -> bool:
        with self._lock:
            return bool(self._stack)

    @property
    def active_surface(self) -> TransientSurface | None:
        with self._lock:
            return self._stack[-1] if self._stack else None

    def is_root_live(self, root_ref: Any) -> bool:
        with self._lock:
            return any(not surface.closed and _refs_equal(surface.root_ref, root_ref) for surface in self._stack)

    def on_notification(self, observer: Any, element: Any, notification: str) -> None:
        if notification == "AXMenuClosed":
            self._close_surface(element)
            return
        if notification == "AXUIElementDestroyed":
            self._close_surface(element)
            return

        kind = _classify_transient_surface(element, notification)
        if kind is None:
            return
        self._open_surface(element, kind)

    def wait_for_open(self, timeout: float) -> bool:
        if self.has_active_transient:
            return True
        self._open_event.clear()
        return self._open_event.wait(timeout=timeout)

    def wait_for_close(self, timeout: float) -> bool:
        if not self.has_active_transient:
            return True
        self._close_event.clear()
        return self._close_event.wait(timeout=timeout)

    def reset(self) -> None:
        with self._lock:
            self._stack.clear()
            self._event_counter = 0
        self._open_event.clear()
        self._close_event.clear()

    def _open_surface(self, element: Any, kind: str) -> None:
        locator = _locator_from_ref(element)
        with self._lock:
            if self._stack and _refs_equal(self._stack[-1].root_ref, element):
                self._stack[-1].kind = kind
            else:
                self._stack.append(TransientSurface(root_ref=element, locator=locator, kind=kind))
            self._event_counter += 1
        logger.debug("[TransientGraphTracker] opened %s", kind)
        self._open_event.set()

    def _close_surface(self, element: Any) -> None:
        with self._lock:
            if not self._stack:
                return
            for index in range(len(self._stack) - 1, -1, -1):
                surface = self._stack[index]
                if _refs_equal(surface.root_ref, element):
                    surface.closed = True
                    del self._stack[index:]
                    self._event_counter += 1
                    self._close_event.set()
                    logger.debug("[TransientGraphTracker] closed %s", surface.kind)
                    return
            # Fallback: if the menu system only reports a generic close, collapse the top surface.
            surface = self._stack.pop()
            surface.closed = True
            self._event_counter += 1
            self._close_event.set()
            logger.debug("[TransientGraphTracker] closed %s (fallback)", surface.kind)


def annotate_graph_nodes(nodes: list[Node], graph_id: str, generation: int) -> None:
    lineage: list[Node] = []
    sibling_counts: dict[tuple[int, AncestorSignature, tuple[AncestorSignature, ...]], int] = {}

    for node in nodes:
        while len(lineage) > node.depth:
            lineage.pop()

        parent_path = tuple(_signature(ancestor) for ancestor in lineage[-4:])
        signature = _signature(node)
        sibling_key = (node.depth, signature, parent_path)
        ordinal = sibling_counts.get(sibling_key, 0)
        sibling_counts[sibling_key] = ordinal + 1

        node.graph_id = graph_id
        node.graph_generation = generation
        node.graph_locator = GraphLocator(
            ax_role=node.ax_role,
            label=node.label,
            description=node.description,
            value=node.value,
            ax_id=node.ax_id,
            depth=node.depth,
            parent_path=parent_path,
            sibling_ordinal=ordinal,
        )
        lineage.append(node)


def match_node_by_locator(nodes: list[Node], locator: GraphLocator | None) -> Node | None:
    if locator is None:
        return None

    scored: list[tuple[int, Node]] = []
    for node in nodes:
        score = _locator_score(node, locator)
        if score >= 0:
            scored.append((score, node))
    if not scored:
        return None
    scored.sort(key=lambda item: (item[0], -item[1].index), reverse=True)
    return scored[0][1]


def _locator_score(node: Node, locator: GraphLocator) -> int:
    if locator.ax_role is not None and node.ax_role != locator.ax_role:
        return -1

    score = 8
    if node.label == locator.label:
        score += 12
    elif locator.label is not None:
        score -= 4

    if node.ax_id == locator.ax_id:
        score += 12
    elif locator.ax_id is not None:
        score -= 6

    if node.description == locator.description:
        score += 4
    elif locator.description is not None:
        score -= 1

    if node.value == locator.value:
        score += 3
    elif locator.value is not None:
        score -= 1

    if node.depth == locator.depth:
        score += 4
    else:
        score -= abs(node.depth - locator.depth)

    node_locator = getattr(node, "graph_locator", None)
    if isinstance(node_locator, GraphLocator):
        if node_locator.parent_path == locator.parent_path:
            score += 10
        else:
            shared = 0
            for left, right in zip(node_locator.parent_path, locator.parent_path):
                if left == right:
                    shared += 1
            score += shared * 2
        if node_locator.sibling_ordinal == locator.sibling_ordinal:
            score += 3

    return score


def _signature(node: Node) -> AncestorSignature:
    return (
        node.ax_role,
        node.label,
        node.ax_id or node.description or node.value,
    )


def _locator_from_ref(element: Any) -> GraphLocator | None:
    try:
        node = accessibility.node_from_ref(element, depth=0, index=0)
    except Exception:
        return None
    return GraphLocator(
        ax_role=node.ax_role,
        label=node.label,
        description=node.description,
        value=node.value,
        ax_id=node.ax_id,
        depth=0,
        parent_path=(),
        sibling_ordinal=0,
    )


def _classify_transient_surface(element: Any, notification: str) -> str | None:
    try:
        node = accessibility.node_from_ref(element, depth=0, index=0)
    except Exception:
        return None

    ax_role = node.ax_role or ""
    subrole = node.subrole or ""
    role = node.role

    if notification == "AXMenuOpened" or ax_role == "AXMenu":
        return "menu"
    if ax_role in {"AXDialog", "AXSheet"} or role in {"dialog"}:
        return "dialog"
    if ax_role == "AXPopover":
        return "popover"
    if ax_role in {"AXMenuButton", "AXPopUpButton"}:
        return "dropdown"
    if ax_role == "AXWindow" and subrole and subrole not in {"AXStandardWindow"}:
        lowered = subrole.lower()
        if "sheet" in lowered:
            return "sheet"
        if "alert" in lowered or "dialog" in lowered:
            return "alert"
        return "panel"
    return None


def _refs_equal(left: Any, right: Any) -> bool:
    if left is right:
        return True
    if left is None or right is None:
        return False
    try:
        from Foundation import CFEqual

        return bool(CFEqual(left, right))
    except Exception:
        return False
