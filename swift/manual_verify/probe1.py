import sys, json
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of

m = MCP()
m.initialize()
print("=== list_apps (first real call — triggers permission gate) ===")
r = m.call("list_apps", {})
print(text_of(r)[:1500])
print("\n=== get_app_state on Finder ===")
r = m.call("get_app_state", {"app": "Finder"})
print(text_of(r)[:1200])
print("\n=== stderr (symbol report / logs) ===")
import time; time.sleep(0.5)
print("\n".join(m.stderr_lines[-40:]))
m.close()
