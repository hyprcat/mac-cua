import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def front(): return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
def disp():
    # Calculator result is in the static text / AXValue of the display
    r=subprocess.run(["osascript","-e",'tell application "System Events" to tell process "Calculator" to get value of static text 1 of group 1 of window 1'],capture_output=True,text=True)
    return (r.stdout or r.stderr).strip()
m=MCP(); m.initialize(); APP="Calculator"; fg=[]
m.call("get_app_state",{"app":APP})
seq=[("7","9"),("×","12"),("8","10"),("=","24")]
for label,idx in seq:
    text_of(m.call("click",{"app":APP,"element_index":idx}))
    f=front()
    if f!="Terminal": fg.append((label,f))
    time.sleep(0.2)
    print(f"click {label:3} (#{idx}) front={f:9} display={disp()}")
print("\nfinal display (oracle):", disp())
print("foreground violations:", fg)
m.close()
