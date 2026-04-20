"""Refetchable AX tree with invalidation-driven re-walks and element refetch.

Wraps a list of Node objects with an invalidation monitor:
- Fast path: if tree not invalidated, elements are still valid (0ms)
- Slow path: re-walk tree and find equivalent element by role + label + position
- Handles 0/1/N matches with typed error codes
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable

from app.response import Node
from app._lib.errors import RefetchError
from app._lib.observer import TreeInvalidationMonitor
from app._lib.tracing import controller_tracer

logger = logging.getLogger(__name__)

LOG_PREFIX = "[RefetchableTree]"


class RefetchErrorCode(Enum):
    """Error codes for element refetch failures."""
    NO_INVALIDATION_MONITOR = "no_monitor"
    AMBIGUOUS_BEFORE = "ambiguous_before_refetch"
    AMBIGUOUS_AFTER = "ambiguous_after_refetch"
    NOT_FOUND = "not_found_after_refetch"


@dataclass
class RefetchResult:
    """Result of an element refetch attempt."""
    node: Node | None = None
    error_code: RefetchErrorCode | None = None
    error_message: str | None = None

    @property
    def success(self) -> bool:
        return self.node is not None and self.error_code is None


def _element_key(node: Node) -> tuple[str | None, str | None]:
    """Matching key for element equivalence: (ax_role, label)."""
    return (node.ax_role, node.label)


def _find_equivalent_elements(
    nodes: list[Node],
    target_role: str | None,
    target_label: str | None,
) -> list[Node]:
    """Find all nodes matching the target role and label."""
    matches = []
    for node in nodes:
        if node.ax_role == target_role and node.label == target_label:
            matches.append(node)
    return matches


class RefetchableTree:
    """Cached AX tree with invalidation-driven re-walks.

    - elements: list of Node objects from the last tree walk
    - invalidationMonitor: tracks whether the tree has changed
    - pid: target process ID for re-walks
    - ax_window: AX window element for re-walks

    The tree walker function is injected to avoid circular imports.
    """

    def __init__(
        self,
        nodes: list[Node],
        monitor: TreeInvalidationMonitor | None,
        *,
        ax_window: Any = None,
        target_pid: int | None = None,
        walk_fn: Callable[..., list[Node]] | None = None,
    ) -> None:
        self._nodes = nodes
        self._monitor = monitor
        self._ax_window = ax_window
        self._target_pid = target_pid
        self._walk_fn = walk_fn

    @property
    def nodes(self) -> list[Node]:
        """Current cached nodes."""
        return self._nodes

    @property
    def is_invalidated(self) -> bool:
        """Whether the tree has been invalidated by AX notifications."""
        if self._monitor is None:
            return True  # No monitor = always assume invalidated
        return self._monitor.is_invalidated

    def get_nodes(self) -> list[Node]:
        """Get tree nodes, using cache if not invalidated.

        Fast path: return cached nodes if tree hasn't changed.
        Slow path: re-walk the full tree if invalidated.
        """
        if not self.is_invalidated:
            return self._nodes

        # Tree changed — full re-walk
        new_nodes = self._rewalk()
        if new_nodes is not None:
            self._nodes = new_nodes
            if self._monitor is not None:
                self._monitor.reset()

        return self._nodes

    def element(self, index: int) -> RefetchResult:
        """Look up element by index, refetching if invalidated."""
        logger.debug("%s Checking if element is stale", LOG_PREFIX)

        if index < 0 or index >= len(self._nodes):
            return RefetchResult(
                error_code=RefetchErrorCode.NOT_FOUND,
                error_message=f"Index {index} out of bounds (tree has {len(self._nodes)} elements)",
            )

        original = self._nodes[index]

        # Fast path: tree not invalidated → element still valid
        if not self.is_invalidated:
            logger.debug("%s Element still valid (cache hit)", LOG_PREFIX)
            return RefetchResult(node=original)

        # No monitor — can't determine invalidation state
        if self._monitor is None:
            logger.warning(
                "No invalidation monitor attached to tree."
            )
            return RefetchResult(
                error_code=RefetchErrorCode.NO_INVALIDATION_MONITOR,
                error_message="No invalidation monitor attached to tree.",
            )

        # Slow path: tree invalidated → try to refetch
        logger.debug("%s Element stale, searching for equivalent", LOG_PREFIX)
        return self._refetch_element(original)

    def _refetch_element(self, original: Node) -> RefetchResult:
        """Re-fetch an invalidated element by finding its equivalent.

        Algorithm:
        1. Check for ambiguity in the ORIGINAL tree (pre-refetch)
        2. Re-walk the tree
        3. Search for element matching original's role + label
        4. Handle 0/1/N matches in the new tree
        """
        target_role = original.ax_role
        target_label = original.label

        # Step 1: Check for ambiguity before refetch
        existing_matches = _find_equivalent_elements(self._nodes, target_role, target_label)
        if len(existing_matches) > 1:
            logger.debug(
                "%s Multiple matches in current tree; ambiguous lookup",
                LOG_PREFIX,
            )
            return RefetchResult(
                error_code=RefetchErrorCode.AMBIGUOUS_BEFORE,
                error_message=(
                    f"Multiple matches in current tree; ambiguous lookup "
                    f"(role={target_role}, label={target_label!r}, count={len(existing_matches)})"
                ),
            )

        # Step 2: Re-walk the tree
        logger.debug(
            "%s Element possibly stale due to %s, re-walking tree",
            LOG_PREFIX,
            "tree invalidation",
        )

        with controller_tracer.interval("RefetchableTree.refetch"):
            new_nodes = self._rewalk()

        if new_nodes is None:
            return RefetchResult(
                error_code=RefetchErrorCode.NOT_FOUND,
                error_message="Failed to re-walk tree during refetch",
            )

        # Update cached nodes and reset monitor
        self._nodes = new_nodes
        if self._monitor is not None:
            self._monitor.reset()

        # Step 3: Search for equivalent in new tree
        new_matches = _find_equivalent_elements(new_nodes, target_role, target_label)

        # Step 4a: 0 matches → element no longer exists
        if len(new_matches) == 0:
            logger.debug(
                "%s Element gone after tree re-walk",
                LOG_PREFIX,
            )
            return RefetchResult(
                error_code=RefetchErrorCode.NOT_FOUND,
                error_message=(
                    f"Element gone after tree re-walk "
                    f"(role={target_role}, label={target_label!r})"
                ),
            )

        # Step 4b: 1 match → success
        if len(new_matches) == 1:
            found = new_matches[0]
            logger.debug(
                "%s Found equivalent element: %s",
                LOG_PREFIX,
                f"[{found.index}] {found.ax_role} {found.label!r}",
            )
            return RefetchResult(node=found)

        # Step 4c: N matches → ambiguous after refetch
        # Try to disambiguate by original depth/position
        positional_match = self._disambiguate_by_position(original, new_matches)
        if positional_match is not None:
            logger.debug(
                "%s Found equivalent element: %s",
                LOG_PREFIX,
                f"[{positional_match.index}] {positional_match.ax_role} {positional_match.label!r}",
            )
            return RefetchResult(node=positional_match)

        logger.debug(
            "%s Multiple matches in new tree; ambiguous lookup",
            LOG_PREFIX,
        )
        return RefetchResult(
            error_code=RefetchErrorCode.AMBIGUOUS_AFTER,
            error_message=(
                f"Multiple matches in new tree; ambiguous lookup "
                f"(role={target_role}, label={target_label!r}, count={len(new_matches)})"
            ),
        )

    def _disambiguate_by_position(
        self, original: Node, candidates: list[Node]
    ) -> Node | None:
        """Try to pick the right match using depth and relative position.

        If the original element was at a certain depth and relative position
        among its siblings, prefer the candidate at the same depth and
        closest index.
        """
        # Filter by same depth first
        same_depth = [n for n in candidates if n.depth == original.depth]
        if len(same_depth) == 1:
            return same_depth[0]

        # Among same-depth candidates, pick the one closest to the original index
        search_candidates = same_depth if same_depth else candidates
        return min(search_candidates, key=lambda n: abs(n.index - original.index))

    def _rewalk(self) -> list[Node] | None:
        """Re-walk the AX tree. Returns None if unable."""
        if self._walk_fn is None or self._ax_window is None:
            return None
        try:
            return self._walk_fn(self._ax_window, target_pid=self._target_pid)
        except Exception as e:
            logger.debug("Tree re-walk failed during refetch: %s", e)
            return None

    def update(
        self,
        nodes: list[Node],
        *,
        ax_window: Any = None,
        target_pid: int | None = None,
    ) -> None:
        """Replace the cached tree with fresh nodes (after a full snapshot).

        Called after take_snapshot() produces a new tree walk.
        """
        self._nodes = nodes
        if ax_window is not None:
            self._ax_window = ax_window
        if target_pid is not None:
            self._target_pid = target_pid
        if self._monitor is not None:
            self._monitor.reset()
