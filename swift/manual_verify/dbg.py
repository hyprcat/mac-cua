import sys, os
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
env = dict(os.environ); env["MACCUA_DEBUG"]="1"
m = MCP(env=env); m.initialize()
for app in ["Safari","Finder","Firefox"]:
    t = text_of(m.call("get_app_state", {"app": app}))
    appline = next((l for l in t.splitlines() if l.startswith("App=")), "(err)")
    print(f"REQ {app!r:10} -> {appline}")
import time; time.sleep(0.4)
print("---- STDERR ----")
print("\n".join(m.stderr_lines[-20:]))
m.close()
