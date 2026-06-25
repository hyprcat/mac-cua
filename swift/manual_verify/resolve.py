import sys
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m = MCP(); m.initialize()
for arg in [{"app":"Safari"},{"app":"com.apple.Safari"},{"app":"Firefox"},{"app":"org.mozilla.firefox"}]:
    r = m.call("get_app_state", arg)
    t = text_of(r)
    # print just the App= line and any error
    head = [l for l in t.splitlines() if l.startswith("App=") or "not allowed" in l or "error" in l.lower() or "could not" in l.lower() or "no app" in l.lower()]
    print(arg, "->", head[:3], " [img]" if "<image" in t else "")
m.close()
