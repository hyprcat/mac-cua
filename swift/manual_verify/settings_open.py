import sys
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m=MCP(); m.initialize()
# Launch + read System Settings purely through the CUA (no shell open)
t=text_of(m.call("get_app_state",{"app":"System Settings"}))
print("\n".join(t.splitlines()[:6]))
print("--- nav / interactive nodes ---")
for l in t.splitlines():
    s=l.strip()
    if s[:1].isdigit() and any(k in s.lower() for k in ["wallpaper","button","row","cell","search","text field","Wallpaper"]):
        print("  ", s[:90])
m.close()
