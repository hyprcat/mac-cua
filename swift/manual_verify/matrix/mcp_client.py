#!/usr/bin/env python3
"""Reusable MCP/stdio client for the Swift mac-cua binary.

Transport/handshake logic adapted from manual_verify/driver.py: launch
.build/debug/mac-cua, do the MCP `initialize` + `notifications/initialized`
handshake, and exchange one JSON-RPC message per line over stdio.

This module adds a clean `Client` / `ToolResult` API used by the
tool x app verification matrix.
"""
import base64
import json
import subprocess
import threading
from dataclasses import dataclass, field

BIN = "/Users/affan/mac-cua/swift/.build/debug/mac-cua"
DEFAULT_TIMEOUT = 20


@dataclass
class ToolResult:
    ok: bool
    text: str
    images: list = field(default_factory=list)  # list[bytes]
    raw: dict = field(default_factory=dict)
    error: str = None


class Client:
    def __init__(self, binary=BIN, env=None):
        # Use binary stdio so we can lift the line-buffer limit and handle
        # very large (100KB+) single-line JSON-RPC messages without truncation.
        self.p = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self._id = 0
        self._lock = threading.Lock()
        self.stderr_lines = []
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()
        self._initialize()

    # ---- transport -------------------------------------------------------
    def _drain_stderr(self):
        for line in self.p.stderr:
            try:
                self.stderr_lines.append(line.decode("utf-8", "replace").rstrip())
            except Exception:
                pass

    def _send(self, obj):
        data = (json.dumps(obj) + "\n").encode("utf-8")
        with self._lock:
            self.p.stdin.write(data)
            self.p.stdin.flush()

    def _recv_line(self, timeout):
        """Read exactly one JSON-RPC message (one line). No length cap.

        readline() on a binary, unbuffered pipe handles arbitrarily long
        lines, so 100KB+ get_app_state payloads come through intact.
        """
        result = {}
        done = threading.Event()

        def reader():
            try:
                result["line"] = self.p.stdout.readline()
            except Exception as e:  # pragma: no cover
                result["exc"] = e
            done.set()

        threading.Thread(target=reader, daemon=True).start()
        if not done.wait(timeout):
            return {"_timeout": True}
        if "exc" in result:
            return {"_eof": True}
        line = result.get("line", b"")
        if not line:
            return {"_eof": True}
        return json.loads(line.decode("utf-8"))

    def _request(self, method, params=None, timeout=DEFAULT_TIMEOUT):
        self._id += 1
        rid = self._id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        # Skip notifications / out-of-band messages until our id comes back.
        for _ in range(50):
            msg = self._recv_line(timeout)
            if msg.get("_timeout") or msg.get("_eof"):
                return msg
            if msg.get("id") == rid:
                return msg
        return {"_no_response": True}

    def _notify(self, method, params=None):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _initialize(self):
        r = self._request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "matrix-mcp-client", "version": "0"},
        })
        self._notify("notifications/initialized")
        return r

    # ---- public API ------------------------------------------------------
    def list_tools(self):
        r = self._request("tools/list")
        return [t["name"] for t in r.get("result", {}).get("tools", [])]

    def call(self, tool, timeout=DEFAULT_TIMEOUT, **params):
        msg = self._request(
            "tools/call",
            {"name": tool, "arguments": params},
            timeout=timeout,
        )
        if msg.get("_timeout"):
            return ToolResult(ok=False, text="", raw={}, error="timeout")
        if msg.get("_eof"):
            return ToolResult(ok=False, text="", raw={}, error="server closed connection (EOF)")
        if msg.get("_no_response"):
            return ToolResult(ok=False, text="", raw={}, error="no response for request id")
        if "error" in msg:
            err = msg["error"]
            return ToolResult(
                ok=False, text="", raw={},
                error=f"JSON-RPC error {err.get('code')}: {err.get('message')}",
            )

        result = msg.get("result", {})
        texts = []
        images = []
        for c in result.get("content", []):
            ctype = c.get("type")
            if ctype == "text":
                texts.append(c.get("text", ""))
            elif ctype == "image":
                data = c.get("data", "")
                if data:
                    try:
                        images.append(base64.b64decode(data))
                    except Exception:
                        pass
        is_error = bool(result.get("isError", False))
        return ToolResult(
            ok=not is_error,
            text="\n".join(texts),
            images=images,
            raw=result,
            error=("result.isError" if is_error else None),
        )

    def save_screenshot(self, result, path):
        """Write the first image block of `result` to `path` (.png). Returns
        the path, or None if there is no image."""
        if not result.images:
            return None
        if not path.endswith(".png"):
            path = path + ".png"
        with open(path, "wb") as f:
            f.write(result.images[0])
        return path

    def close(self):
        try:
            self.p.terminate()
            try:
                self.p.wait(timeout=5)
            except Exception:
                self.p.kill()
        except Exception:
            pass

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()
        return False


# ---- self-test -----------------------------------------------------------
REQUIRED_TOOLS = {
    "list_apps", "get_app_state", "click", "type_text", "press_key",
    "set_value", "scroll", "drag", "select_text", "clipboard", "wait",
    "perform_secondary_action", "batch",
}


if __name__ == "__main__":
    with Client() as c:
        tools = c.list_tools()
        tool_set = set(tools)
        missing = REQUIRED_TOOLS - tool_set
        assert not missing, f"missing required tools: {sorted(missing)}\nhave: {sorted(tools)}"

        probe = "matrix-harness-probe-123"
        set_res = c.call("clipboard", action="set", text=probe)
        assert set_res.ok, f"clipboard set failed: {set_res.error} / {set_res.text}"

        get_res = c.call("clipboard", action="get")
        assert get_res.ok, f"clipboard get failed: {get_res.error} / {get_res.text}"
        assert probe in get_res.text, f"clipboard did not round-trip; got: {get_res.text!r}"

        apps_res = c.call("list_apps")
        assert apps_res.ok, f"list_apps failed: {apps_res.error} / {apps_res.text}"
        assert apps_res.text.strip(), "list_apps returned empty text"

        print(f"clipboard round-trip: {probe!r} OK")
        print(f"list_apps text length: {len(apps_res.text)} chars")
        print(f"tools: {sorted(tools)}")
        print(f"PASS - {len(tools)} tools available")
