from __future__ import annotations

import logging
import subprocess
import time
from dataclasses import dataclass
from typing import Any

from AppKit import NSRunningApplication, NSWorkspace, NSWorkspaceOpenConfiguration
from ApplicationServices import AXUIElementCreateApplication

from app._lib.errors import AutomationError

logger = logging.getLogger(__name__)


@dataclass
class AppInfo:
    name: str
    bundle_id: str
    pid: int | None
    running: bool
    last_used: str | None = None
    use_count: int | None = None


_pid_cache: dict[str, int] = {}
_ax_app_cache: dict[int, Any] = {}


def invalidate_caches_for_pid(pid: int) -> None:
    _ax_app_cache.pop(pid, None)
    stale_bundles = [b for b, p in _pid_cache.items() if p == pid]
    for b in stale_bundles:
        del _pid_cache[b]


def list_running_apps() -> list[AppInfo]:
    workspace = NSWorkspace.sharedWorkspace()
    apps = workspace.runningApplications()
    result = []
    seen_bundles: set[str] = set()
    for app in apps:
        bundle_id = app.bundleIdentifier()
        if not bundle_id:
            continue
        if app.activationPolicy() != 0:
            continue
        name = app.localizedName() or bundle_id.split(".")[-1]
        seen_bundles.add(str(bundle_id))
        result.append(AppInfo(
            name=str(name),
            bundle_id=str(bundle_id),
            pid=app.processIdentifier(),
            running=True,
        ))

    # Fallback: use lsappinfo to find GUI apps NSWorkspace might miss
    # (can happen when MCP server runs as a child of a sandboxed app)
    try:
        import subprocess, re
        out = subprocess.run(
            ["lsappinfo", "list"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        for block in out.split("ASN:"):
            # Only include foreground (regular GUI) apps
            if 'type="Foreground"' not in block:
                continue
            bid_m = re.search(r'bundleID="([^"]+)"', block)
            name_m = re.search(r'"LSDisplayName"="([^"]+)"', block) or re.search(r'^\s*"([^"]+)"\s', block)
            pid_m = re.search(r'pid\s*=\s*(\d+)', block)
            if bid_m and pid_m:
                bid = bid_m.group(1)
                if bid not in seen_bundles:
                    name = name_m.group(1) if name_m else bid.rsplit(".", 1)[-1]
                    result.append(AppInfo(
                        name=name,
                        bundle_id=bid,
                        pid=int(pid_m.group(1)),
                        running=True,
                    ))
                    seen_bundles.add(bid)
    except Exception:
        pass

    return result


def list_recent_apps() -> list[AppInfo]:
    try:
        from Foundation import NSBundle, NSURL
        import plistlib
        import os
        from datetime import datetime

        sfl_path = os.path.expanduser(
            "~/Library/Application Support/com.apple.sharedfilelist/"
            "com.apple.LSSharedFileList.RecentApplications.sfl3"
        )
        if not os.path.exists(sfl_path):
            return []

        with open(sfl_path, "rb") as f:
            data = plistlib.load(f)

        items = data.get("items", [])
        result = []
        for item in items:
            bookmark = item.get("Bookmark")
            if not bookmark:
                continue
            name = item.get("Name", "")
            url, _, _ = NSURL.URLByResolvingBookmarkData_options_relativeToURL_bookmarkDataIsStale_error_(
                bookmark, 0, None, None, None,
            )
            if url is None:
                continue
            path = url.path()
            if not path:
                continue
            bundle = NSBundle.bundleWithPath_(path)
            if bundle is None:
                continue
            bundle_id = bundle.bundleIdentifier()
            if not bundle_id:
                continue
            result.append(AppInfo(
                name=str(name) if name else str(bundle_id).rsplit(".", 1)[-1],
                bundle_id=str(bundle_id),
                pid=None,
                running=False,
            ))
        return result
    except Exception:
        return []


def resolve_app(app: str) -> AppInfo:
    running = list_running_apps()

    # Exact match on bundle ID or name
    for a in running:
        if a.bundle_id == app or a.name.lower() == app.lower():
            return a

    # Substring match
    for a in running:
        if app.lower() in a.name.lower() or app.lower() in a.bundle_id.lower():
            return a

    # Not running — check if it's a valid bundle ID we can launch
    if "." in app:
        workspace = NSWorkspace.sharedWorkspace()
        app_url = workspace.URLForApplicationWithBundleIdentifier_(app)
        if app_url is not None:
            path = app_url.path()
            from AppKit import NSBundle as _NSBundle
            bundle = _NSBundle.bundleWithPath_(path)
            name = app.rsplit(".", 1)[-1]
            if bundle:
                info_dict = bundle.infoDictionary()
                if info_dict:
                    name = info_dict.get("CFBundleName", name)
            return AppInfo(
                name=str(name),
                bundle_id=app,
                pid=None,
                running=False,
            )

    raise AutomationError(f"App not found: {app}. Use list_apps to see available apps.")


def resolve_running_app_by_pid(pid: int) -> AppInfo | None:
    for app in list_running_apps():
        if app.pid == pid:
            return app

    try:
        running = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
    except Exception:
        running = None

    if running is None:
        return None

    bundle_id = running.bundleIdentifier()
    if not bundle_id:
        return None

    name = running.localizedName() or str(bundle_id).rsplit(".", 1)[-1]
    return AppInfo(
        name=str(name),
        bundle_id=str(bundle_id),
        pid=pid,
        running=True,
    )


def _is_pid_alive(pid: int) -> bool:
    """Check whether a PID is still running."""
    import os, signal
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


LAUNCH_TIMEOUT_S = 30


def _launch_app_without_activation(workspace: NSWorkspace, app_url: Any) -> None:
    config = NSWorkspaceOpenConfiguration.configuration()
    config.setActivates_(False)

    # Keep launches as side-effect free as possible for background use.
    if hasattr(config, "setAddsToRecentItems_"):
        config.setAddsToRecentItems_(False)
    if hasattr(config, "setCreatesNewApplicationInstance_"):
        config.setCreatesNewApplicationInstance_(False)

    workspace.openApplicationAtURL_configuration_completionHandler_(
        app_url,
        config,
        None,
    )


def _launch_app_with_open(bundle_id: str) -> None:
    subprocess.run(
        ["open", "-g", "-b", bundle_id],
        check=True,
        timeout=10,
    )


def launch_app(bundle_id: str) -> int:
    workspace = NSWorkspace.sharedWorkspace()
    app_url = workspace.URLForApplicationWithBundleIdentifier_(bundle_id)
    if app_url is None:
        raise AutomationError(f"Cannot find app with bundle ID: {bundle_id}")

    try:
        # Prefer the modern AppKit launch API. Apple documents
        # NSWorkspaceOpenConfiguration.activates = False as the supported
        # way to avoid foreground activation during launch. Some apps may
        # still choose to self-activate after launch, but this is the best
        # available non-deprecated request path.
        _launch_app_without_activation(workspace, app_url)
    except Exception as e:
        logger.debug(
            "NSWorkspace background launch failed for %s, falling back to open -g: %s",
            bundle_id,
            e,
        )
        try:
            _launch_app_with_open(bundle_id)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as open_error:
            raise AutomationError(
                f"Failed to launch app without activation: {bundle_id}: {open_error}"
            ) from open_error

    deadline = time.monotonic() + LAUNCH_TIMEOUT_S
    while time.monotonic() < deadline:
        time.sleep(0.3)
        for a in list_running_apps():
            if a.bundle_id == bundle_id and a.pid is not None:
                _pid_cache[bundle_id] = a.pid
                return a.pid
    raise AutomationError(
        f"App {bundle_id} did not appear in process list within {LAUNCH_TIMEOUT_S}s"
    )


def get_frontmost_app() -> Any | None:
    """Return the current frontmost NSRunningApplication, or None."""
    try:
        return NSWorkspace.sharedWorkspace().frontmostApplication()
    except Exception:
        return None


def restore_frontmost(app: Any | None) -> None:
    """Re-activate a previously frontmost app if focus was stolen."""
    if app is None:
        return
    try:
        if not app.isActive():
            app.activateWithOptions_(0)
    except Exception:
        pass


def reopen_app_background(bundle_id: str) -> None:
    """Send a background reopen to a running-but-windowless app.

    Uses ``NSWorkspace.openApplicationAtURL`` with ``activates = False``.
    When the target app is already running, macOS delivers
    ``kAEReopenApplication`` to it — most apps respond by creating their
    default window.  Because ``activates`` is off, the app stays in the
    background and never steals focus.

    Falls back to ``open -g`` if the NSWorkspace call fails.
    """
    workspace = NSWorkspace.sharedWorkspace()
    app_url = workspace.URLForApplicationWithBundleIdentifier_(bundle_id)
    if app_url is None:
        logger.debug("reopen_app_background: no URL for %s, trying open -g", bundle_id)
        subprocess.run(["open", "-g", "-a", bundle_id], timeout=5, capture_output=True)
        return
    try:
        _launch_app_without_activation(workspace, app_url)
    except Exception:
        logger.debug("reopen_app_background: NSWorkspace failed for %s, trying open -g", bundle_id)
        subprocess.run(["open", "-g", "-a", bundle_id], timeout=5, capture_output=True)


def get_ax_app_for_bundle(bundle_id: str, known_pid: int | None = None) -> tuple[Any, int]:
    """Get or create an AXUIElement for an app.

    If known_pid is provided (from a prior resolve_app call), skip re-resolving.
    Validates cached PIDs are still alive before reusing them.
    """
    # Check cache, but validate the PID is still alive
    if bundle_id in _pid_cache:
        pid = _pid_cache[bundle_id]
        if _is_pid_alive(pid) and pid in _ax_app_cache:
            return _ax_app_cache[pid], pid
        # Stale — clean up
        invalidate_caches_for_pid(pid)

    # Use known PID if provided, otherwise resolve
    pid = known_pid
    if pid is None or not _is_pid_alive(pid):
        info = resolve_app(bundle_id)
        if info.pid is None:
            pid = launch_app(bundle_id)
        else:
            pid = info.pid

    _pid_cache[bundle_id] = pid
    ax_app = AXUIElementCreateApplication(pid)
    _ax_app_cache[pid] = ax_app
    return ax_app, pid


def get_ax_app_for_pid(pid: int, bundle_id: str | None = None) -> tuple[Any, int]:
    if not _is_pid_alive(pid):
        raise AutomationError(f"PID {pid} is not running")

    if pid in _ax_app_cache:
        ax_app = _ax_app_cache[pid]
    else:
        ax_app = AXUIElementCreateApplication(pid)
        _ax_app_cache[pid] = ax_app

    if bundle_id:
        _pid_cache[bundle_id] = pid

    return ax_app, pid
