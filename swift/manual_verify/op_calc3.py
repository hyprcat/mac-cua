import sys
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m=MCP(); m.initialize(); APP="Calculator"
m.call("get_app_state",{"app":APP})
for label,idx in [("7","9"),("x","12"),("8","10"),("=","24")]:
    text_of(m.call("click",{"app":APP,"element_index":idx}))
t=text_of(m.call("get_app_state",{"app":APP}))
# print any node carrying the result value (text/static with a number)
for l in t.splitlines():
    s=l.strip()
    if s[:1].isdigit() and ("text" in s.lower() or "result" in s.lower() or "Value" in s):
        if any(c.isdigit() for c in s.split("Value:")[-1]) or "result" in s.lower():
            print("  ", s[:90])
m.close()
