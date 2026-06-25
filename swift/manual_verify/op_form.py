import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def front(): return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
m=MCP(); m.initialize()
APP="Safari"
t=text_of(m.call("get_app_state",{"app":APP}))
print("=== Safari form AX tree (interactive nodes) ===")
for l in t.splitlines():
    s=l.strip()
    if s[:1].isdigit() and any(k in s.lower() for k in ["text field","text area","checkbox","button","pop up","combo","slider","menu button","incrementor","field"]):
        print("  ", s[:90])
# find indices
def idx_for(keyword, label=None):
    for l in t.splitlines():
        s=l.strip()
        if s[:1].isdigit() and keyword in s.lower() and (label is None or label.lower() in s.lower()):
            return s.split()[0]
    return None
print("front:",front())
m.close()
