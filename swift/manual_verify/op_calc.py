import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def front(): return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
m=MCP(); m.initialize(); APP="Calculator"
t=text_of(m.call("get_app_state",{"app":APP}))
print("=== Calculator buttons (sample) ===")
btns={}
for l in t.splitlines():
    s=l.strip()
    if s[:1].isdigit() and "button" in s.lower():
        # capture label after 'button'
        print("  ", s[:70])
print("front:",front())
m.close()
