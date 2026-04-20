"""Tests for RefetchableTree cache behavior.

Verifies:
- Cache hit when tree not invalidated
- Cache miss and re-walk when invalidated
- Element refetch with 0/1/N matches
- Ambiguity detection before and after refetch
- Disambiguation by position
"""
from __future__ import annotations

import unittest
from unittest.mock import MagicMock

from app._lib.observer import TreeInvalidationMonitor
from app._lib.refetchable_tree import RefetchableTree, RefetchErrorCode
from app.response import Node


def _node(index: int, role: str = "AXButton", label: str = "Ok", depth: int = 1) -> Node:
    return Node(
        index=index,
        role="button",
        label=label,
        states=[],
        description=None,
        value=None,
        ax_id=None,
        secondary_actions=[],
        depth=depth,
        ax_ref=object(),
        ax_role=role,
    )


class TestCacheHitMiss(unittest.TestCase):
    """Sequential reads with/without changes."""

    def test_cache_hit_returns_cached_nodes(self) -> None:
        monitor = TreeInvalidationMonitor()
        nodes = [_node(0), _node(1)]
        tree = RefetchableTree(nodes, monitor)

        # Not invalidated — should use cache
        result = tree.element(0)
        self.assertTrue(result.success)
        self.assertIs(result.node, nodes[0])

    def test_cache_miss_triggers_rewalk(self) -> None:
        monitor = TreeInvalidationMonitor()
        original_nodes = [_node(0, label="Save"), _node(1, label="Cancel")]
        new_nodes = [_node(0, label="Save"), _node(1, label="Cancel"), _node(2, label="Help")]
        walk_fn = MagicMock(return_value=new_nodes)

        tree = RefetchableTree(
            original_nodes, monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )

        # Invalidate the tree
        monitor.on_notification("AXCreated")

        result = tree.element(0)
        self.assertTrue(result.success)
        walk_fn.assert_called_once()

    def test_get_nodes_returns_cache_when_not_invalidated(self) -> None:
        monitor = TreeInvalidationMonitor()
        nodes = [_node(0)]
        tree = RefetchableTree(nodes, monitor)

        result = tree.get_nodes()
        self.assertIs(result, nodes)

    def test_get_nodes_rewalks_when_invalidated(self) -> None:
        monitor = TreeInvalidationMonitor()
        original = [_node(0)]
        refreshed = [_node(0), _node(1)]
        walk_fn = MagicMock(return_value=refreshed)

        tree = RefetchableTree(
            original, monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )
        monitor.on_notification("AXUIElementDestroyed")

        result = tree.get_nodes()
        self.assertEqual(len(result), 2)
        walk_fn.assert_called_once()


class TestElementRefetch(unittest.TestCase):
    """Element refetch after UI changes."""

    def test_single_match_after_refetch_succeeds(self) -> None:
        monitor = TreeInvalidationMonitor()
        original = [_node(0, label="Save")]
        new_nodes = [_node(0, label="Save")]
        walk_fn = MagicMock(return_value=new_nodes)

        tree = RefetchableTree(
            original, monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )
        monitor.on_notification("AXCreated")

        result = tree.element(0)
        self.assertTrue(result.success)
        self.assertEqual(result.node.label, "Save")

    def test_zero_matches_after_refetch_returns_not_found(self) -> None:
        monitor = TreeInvalidationMonitor()
        original = [_node(0, label="TempButton")]
        new_nodes = [_node(0, label="DifferentButton")]
        walk_fn = MagicMock(return_value=new_nodes)

        tree = RefetchableTree(
            original, monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )
        monitor.on_notification("AXUIElementDestroyed")

        result = tree.element(0)
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, RefetchErrorCode.NOT_FOUND)

    def test_ambiguous_before_refetch_detected(self) -> None:
        monitor = TreeInvalidationMonitor()
        # Two elements with same role+label in original tree
        original = [
            _node(0, label="Submit"),
            _node(1, label="Submit"),
        ]
        walk_fn = MagicMock(return_value=original)

        tree = RefetchableTree(
            original, monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )
        monitor.on_notification("AXCreated")

        result = tree.element(0)
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, RefetchErrorCode.AMBIGUOUS_BEFORE)

    def test_ambiguous_after_refetch_disambiguates_by_depth(self) -> None:
        monitor = TreeInvalidationMonitor()
        # Unique in original
        original = [_node(0, label="Ok", depth=1)]
        # Multiple matches at different depths in new tree
        new_nodes = [
            _node(0, label="Ok", depth=1),
            _node(1, label="Ok", depth=3),
        ]
        walk_fn = MagicMock(return_value=new_nodes)

        tree = RefetchableTree(
            original, monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )
        monitor.on_notification("AXCreated")

        result = tree.element(0)
        # Should disambiguate by depth and succeed
        self.assertTrue(result.success)
        self.assertEqual(result.node.depth, 1)

    def test_out_of_bounds_index_returns_not_found(self) -> None:
        monitor = TreeInvalidationMonitor()
        tree = RefetchableTree([_node(0)], monitor)

        result = tree.element(99)
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, RefetchErrorCode.NOT_FOUND)

    def test_no_monitor_returns_no_invalidation_monitor(self) -> None:
        tree = RefetchableTree([_node(0)], monitor=None)

        # No monitor = always invalidated, but element() should handle gracefully
        result = tree.element(0)
        self.assertEqual(result.error_code, RefetchErrorCode.NO_INVALIDATION_MONITOR)

    def test_rewalk_failure_returns_not_found(self) -> None:
        monitor = TreeInvalidationMonitor()
        walk_fn = MagicMock(side_effect=Exception("AX error"))

        tree = RefetchableTree(
            [_node(0)], monitor,
            ax_window=object(), target_pid=123,
            walk_fn=walk_fn,
        )
        monitor.on_notification("AXCreated")

        result = tree.element(0)
        self.assertFalse(result.success)
        self.assertEqual(result.error_code, RefetchErrorCode.NOT_FOUND)


class TestTreeUpdate(unittest.TestCase):
    """update() replaces cached nodes and resets monitor."""

    def test_update_replaces_nodes(self) -> None:
        monitor = TreeInvalidationMonitor()
        original = [_node(0)]
        tree = RefetchableTree(original, monitor)

        new_nodes = [_node(0), _node(1)]
        tree.update(new_nodes)

        self.assertEqual(len(tree.nodes), 2)

    def test_update_resets_monitor(self) -> None:
        monitor = TreeInvalidationMonitor()
        tree = RefetchableTree([_node(0)], monitor)

        monitor.on_notification("AXCreated")
        self.assertTrue(tree.is_invalidated)

        tree.update([_node(0)])
        self.assertFalse(tree.is_invalidated)


if __name__ == "__main__":
    unittest.main()
