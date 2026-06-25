import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m=MCP(); m.initialize()

def safari_url():
    return subprocess.run(["osascript","-e",'tell application "Safari" to get URL of current tab of window 1'],capture_output=True,text=True).stdout.strip()

# --- Click navigation: find the "More information" link node + coords in Safari ---
t=text_of(m.call("get_app_state",{"app":"Safari"}))
print("URL before:", safari_url())
link=None
for l in t.splitlines():
    s=l.strip()
    if s and s[0].isdigit() and ("link" in s.lower()) :
        link=s; break
print("link node:", (link or "NONE")[:80])
# click via element_index (first token)
if link:
    idx=link.split()[0]
    r=text_of(m.call("click",{"app":"Safari","element_index":idx}))
    time.sleep(1.2)
    print("URL after click:", safari_url())

# --- Clipboard unicode round-trip ---
payload="clip-✅-café-🚀-Ωμέγα"
m.call("clipboard",{"action":"set","text":payload})
got=text_of(m.call("clipboard",{"action":"get"}))
print("clipboard set==get:", payload in got, "| got:", got[:60].replace("\n"," "))

m.close()
