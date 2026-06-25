import sys, json, subprocess, time
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of

def frontmost():
    s = 'tell application "System Events" to return name of first process whose frontmost is true'
    return subprocess.run(["osascript","-e",s], capture_output=True, text=True).stdout.strip()

def cursor_pos():
    # global mouse location via AppleScript not available; use cliclick if present else skip
    r = subprocess.run(["bash","-c","/opt/homebrew/bin/cliclick p 2>/dev/null || echo NA"], capture_output=True, text=True)
    return r.stdout.strip()

m = MCP(); m.initialize()
target = "Safari"
results = []
def check(label, fn):
    f0 = frontmost(); c0 = cursor_pos()
    out = fn()
    time.sleep(0.3)
    f1 = frontmost(); c1 = cursor_pos()
    ok = (f0 == f1)
    results.append((label, f0, f1, c0, c1, ok))
    print(f"[{'PASS' if ok else 'FAIL'}] {label}: front {f0!r}->{f1!r}  cursor {c0}->{c1}")
    print("   ->", (out or "")[:160].replace("\n"," "))

check("get_app_state(Safari) read", lambda: text_of(m.call("get_app_state", {"app": target})))
check("click(Safari) background", lambda: text_of(m.call("click", {"app": target, "x": 400, "y": 300})))
check("type_text(Safari) background", lambda: text_of(m.call("type_text", {"app": target, "text": "x"})))
check("scroll(Safari) background", lambda: text_of(m.call("scroll", {"app": target, "x": 400, "y": 300, "direction": "down", "amount": 3})))

print("\nFRONTMOST INVARIANT:", "ALL PASS" if all(r[5] for r in results) else "VIOLATION")
m.close()
