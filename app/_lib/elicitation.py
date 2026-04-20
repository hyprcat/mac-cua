"""App approval store — session and persistent approval tracking."""

from __future__ import annotations

import json
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

_DEFAULT_STORAGE_PATH = Path("~/.config/mac-cua/approvals.json")

RISK_WARNING = (
    "Allowing automation to use this app introduces new risks, including those "
    "related to prompt injection attacks, such as data theft or loss. "
    "Carefully monitor automation while it uses this app."
)


class AppApprovalStore:
    """Track which apps the user has approved for automation."""

    def __init__(self, storage_path: Path | None = None) -> None:
        self._storage_path = (
            storage_path.expanduser()
            if storage_path is not None
            else _DEFAULT_STORAGE_PATH.expanduser()
        )
        self._session_approved: set[str] = set()
        self._persistent_approved: set[str] = set()
        self._denied: set[str] = set()
        self._mod_date: float | None = None
        self._load_persistent()

    def is_approved(self, bundle_id: str) -> bool:
        return bundle_id in self._session_approved or bundle_id in self._persistent_approved

    def is_denied(self, bundle_id: str) -> bool:
        return bundle_id in self._denied

    def approve_for_session(self, bundle_id: str) -> None:
        self._session_approved.add(bundle_id)
        self._denied.discard(bundle_id)

    def approve_persistently(self, bundle_id: str) -> None:
        self._persistent_approved.add(bundle_id)
        self._denied.discard(bundle_id)
        self._save_persistent()

    def deny(self, bundle_id: str) -> None:
        self._denied.add(bundle_id)

    def clear_session_approvals(self) -> None:
        self._session_approved.clear()

    def _load_persistent(self) -> None:
        if not self._storage_path.exists():
            return
        try:
            stat = self._storage_path.stat()
            if self._mod_date is not None and stat.st_mtime == self._mod_date:
                return
            self._mod_date = stat.st_mtime
            data = json.loads(self._storage_path.read_text())
            self._persistent_approved = set(data.get("approved_bundles", []))
        except Exception as e:
            logger.warning("Failed to load persistent approvals: %s", e)

    def _save_persistent(self) -> None:
        try:
            self._storage_path.parent.mkdir(parents=True, exist_ok=True)
            data = {"approved_bundles": sorted(self._persistent_approved)}
            self._storage_path.write_text(json.dumps(data, indent=2) + "\n")
            self._mod_date = self._storage_path.stat().st_mtime
        except Exception as e:
            logger.warning(
                "Could not persist the approval permanently: %s", e
            )
