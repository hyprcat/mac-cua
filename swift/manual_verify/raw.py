import sys
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m = MCP(); m.initialize()
t = text_of(m.call("get_app_state", {"app":"Safari"}))
print("\n".join(t.splitlines()[:14]))
print("..."); print("HAS IMAGE:", "<image" in t)
m.close()
