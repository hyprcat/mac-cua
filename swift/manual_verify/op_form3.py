import sys
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m=MCP(); m.initialize()
t=text_of(m.call("get_app_state",{"app":"Safari"}))
for l in t.splitlines():
    s=l.strip()
    if s[:1].isdigit() and any(k in s.lower() for k in ["text field","text area","checkbox","pop-up","slider","value:"]) and "search" not in s.lower():
        print("  ", s[:100])
m.close()
