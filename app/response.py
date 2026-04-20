import hashlib
from dataclasses import dataclass, field
from typing import Any


@dataclass
class Rect:
    x: float
    y: float
    w: float
    h: float


@dataclass
class Point:
    x: float
    y: float


@dataclass
class Size:
    w: float
    h: float


@dataclass
class Node:
    index: int
    role: str
    label: str | None
    states: list[str]
    description: str | None
    value: str | None
    ax_id: str | None
    secondary_actions: list[str]
    depth: int
    ax_ref: Any = field(repr=False, default=None)
    # DisplayElement fields
    lm_role: str | None = None
    lm_description: str | None = None
    # Web content flags
    is_web_area: bool = False
    is_oop: bool = False
    # Original AX role for pruning decisions
    ax_role: str | None = None
    # PID of the element's process (for OOP detection)
    element_pid: int | None = None
    # Rich text / web content
    web_content: str | None = None  # Extracted web area or text area content
    web_area_url: str | None = None  # URL of web area element
    url: str | None = None  # URL for link elements (AXLink AXURL attribute)


@dataclass
class AppState:
    """Geometry and state metadata for the target application."""
    bundle_id: str
    is_active: bool
    is_running: bool
    window_title: str | None
    visible_rect: Rect | None = None
    scaling_factor: float = 2.0
    scaled_screen_size: Size | None = None
    cursor_position: Point | None = None


@dataclass
class ToolResponse:
    app: str
    pid: int
    snapshot_id: int
    window_title: str | None = None
    tree_text: str | None = None
    tree_nodes: list[Node] = field(default_factory=list)
    focused_element: int | None = None
    screenshot: str | None = None
    result: str | None = None
    error: str | None = None
    guidance: str | None = None
    app_state: AppState | None = None
    system_selection: str | None = None  # formatted selection text


_VERSION: str | None = None


def compute_version_hash() -> str:
    """Compute a short version hash for the server."""
    global _VERSION
    if _VERSION is not None:
        return _VERSION
    try:
        from importlib.metadata import version as pkg_version
        ver = pkg_version("mac-cua")
    except Exception:
        ver = "0.1.0"
    _VERSION = hashlib.sha256(ver.encode()).hexdigest()[:8]
    return _VERSION


def format_response_header() -> str:
    """Prepend to every tool response."""
    return f"Desktop Automation state (version: {compute_version_hash()})"
