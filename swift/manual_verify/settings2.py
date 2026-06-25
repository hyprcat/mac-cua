import sys, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m=MCP(); m.initialize()
t=text_of(m.call("get_app_state",{"app":"com.apple.systempreferences"}))
print("\n".join(t.splitlines()[:6]))
print("--- interactive nodes ---")
for l in t.splitlines():
    s=l.strip()
    if s[:1].isdigit() and any(k in s.lower() for k in ["wallpaper","button","row","cell","search","sidebar","group"]):
        print("  ", s[:95])
m.close()
