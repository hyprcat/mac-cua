#!/usr/bin/env python3
"""Minimal MCP/stdio driver for the Swift mac-cua binary.

Launches .build/debug/mac-cua, performs the MCP handshake, and lets us call
tools to exercise the REAL Kit providers against live apps for manual-verify.
"""
import json
import subprocess
import sys
import threading
import time

BIN = "/Users/affan/mac-cua/swift/.build/debug/mac-cua"


class MCP:
    def __init__(self, binary=BIN, env=None):
        self.p = subprocess.Popen(
            [binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self._id = 0
        self.stderr_lines = []
        t = threading.Thread(target=self._drain_stderr, daemon=True)
        t.start()

    def _drain_stderr(self):
        for line in self.p.stderr:
            self.stderr_lines.append(line.rstrip())

    def _send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def _recv(self, timeout=15):
        # naive: read one line (one JSON-RPC message) with timeout
        result = {}
        done = threading.Event()

        def reader():
            line = self.p.stdout.readline()
            result["line"] = line
            done.set()

        threading.Thread(target=reader, daemon=True).start()
        if not done.wait(timeout):
            return {"_timeout": True}
        line = result.get("line", "")
        if not line:
            return {"_eof": True}
        return json.loads(line)

    def request(self, method, params=None, timeout=20):
        self._id += 1
        rid = self._id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params or {}})
        # skip any notifications until we get our id
        for _ in range(20):
            msg = self._recv(timeout)
            if msg.get("_timeout") or msg.get("_eof"):
                return msg
            if msg.get("id") == rid:
                return msg
        return {"_no_response": True}

    def notify(self, method, params=None):
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def initialize(self):
        r = self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "manual-verify", "version": "0"},
        })
        self.notify("notifications/initialized")
        return r

    def list_tools(self):
        return self.request("tools/list")

    def call(self, name, arguments, timeout=30):
        return self.request("tools/call", {"name": name, "arguments": arguments}, timeout=timeout)

    def close(self):
        try:
            self.p.terminate()
        except Exception:
            pass


def text_of(call_result):
    """Extract text content from a tools/call result."""
    out = []
    res = call_result.get("result", {})
    for c in res.get("content", []):
        if c.get("type") == "text":
            out.append(c.get("text", ""))
        elif c.get("type") == "image":
            out.append(f"<image {len(c.get('data',''))}b {c.get('mimeType')}>")
    return "\n".join(out)


if __name__ == "__main__":
    m = MCP()
    print("=== initialize ===")
    print(json.dumps(m.initialize().get("result", m.initialize()), indent=2)[:800])
    print("=== tools/list ===")
    tl = m.list_tools()
    names = [t["name"] for t in tl.get("result", {}).get("tools", [])]
    print("tools:", names)
    if m.stderr_lines:
        print("=== stderr ===")
        print("\n".join(m.stderr_lines[-30:]))
    m.close()
