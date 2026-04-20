from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from app._lib.elicitation import AppApprovalStore


class TestAppApprovalStore(unittest.TestCase):
    def test_initially_not_approved(self) -> None:
        store = AppApprovalStore()
        self.assertFalse(store.is_approved("com.example.App"))

    def test_approve_for_session(self) -> None:
        store = AppApprovalStore()
        store.approve_for_session("com.example.App")
        self.assertTrue(store.is_approved("com.example.App"))

    def test_clear_session_approvals(self) -> None:
        store = AppApprovalStore()
        store.approve_for_session("com.example.App")
        store.clear_session_approvals()
        self.assertFalse(store.is_approved("com.example.App"))

    def test_approve_persistently(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "approvals.json"
            store = AppApprovalStore(storage_path=path)
            store.approve_persistently("com.example.App")
            self.assertTrue(store.is_approved("com.example.App"))
            self.assertTrue(path.exists())
            data = json.loads(path.read_text())
            self.assertIn("com.example.App", data["approved_bundles"])

    def test_persistent_survives_reload(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "approvals.json"
            store1 = AppApprovalStore(storage_path=path)
            store1.approve_persistently("com.example.App")
            store2 = AppApprovalStore(storage_path=path)
            self.assertTrue(store2.is_approved("com.example.App"))

    def test_session_approval_does_not_persist(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "approvals.json"
            store1 = AppApprovalStore(storage_path=path)
            store1.approve_for_session("com.example.App")
            store2 = AppApprovalStore(storage_path=path)
            self.assertFalse(store2.is_approved("com.example.App"))

    def test_deny(self) -> None:
        store = AppApprovalStore()
        store.deny("com.example.App")
        self.assertTrue(store.is_denied("com.example.App"))


if __name__ == "__main__":
    unittest.main()
