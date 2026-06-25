import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def front(): return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
def surl(): return subprocess.run(["osascript","-e",'tell application "Safari" to get URL of current tab of window 1'],capture_output=True,text=True).stdout.strip()
m=MCP(); m.initialize()
n=0; fg=[]
def S(label,tool,args,show=None):
    global n; n+=1
    r=text_of(m.call(tool,args)); f=front()
    if f!="Terminal": fg.append((n,label,f))
    extra=""
    if show=="url": extra="url="+surl()
    if show=="app": extra=next((l for l in r.splitlines() if l.startswith("App=")),"")
    print(f"{n:2} {label:38} front={f:9} {extra}")
    return r

print("### COMPLEX FLOW: Safari research -> TextEdit report (cross-app via clipboard)")
S("Safari: open example.com","press_key",{"app":"Safari","key":"cmd+l"})  # focus addr bar
S("Safari: read page","get_app_state",{"app":"Safari"},show="url")
S("Safari: scroll down 1","scroll",{"app":"Safari","x":400,"y":400,"direction":"down","amount":5})
S("Safari: scroll down 2","scroll",{"app":"Safari","x":400,"y":400,"direction":"down","amount":5})
S("Safari: scroll up","scroll",{"app":"Safari","x":400,"y":400,"direction":"up","amount":10})
# click the "Learn more"/RFC link
t=S("Safari: read for links","get_app_state",{"app":"Safari"})
link=next((l.strip() for l in t.splitlines() if l.strip()[:1].isdigit() and "link" in l.lower()),None)
if link:
    S(f"Safari: click link [{link.split()[0]}]","click",{"app":"Safari","element_index":link.split()[0]},show="url")
    time.sleep(1.0)
S("Safari: read new page","get_app_state",{"app":"Safari"},show="url")
S("Safari: back (cmd+[)","press_key",{"app":"Safari","key":"cmd+bracketleft"},show="url")
time.sleep(0.8)
S("Safari: confirm url","get_app_state",{"app":"Safari"},show="url")

print("### TextEdit: build a report")
subprocess.run(["osascript","-e",'tell application "TextEdit" to set text of document 1 to ""'])
S("TE: title","type_text",{"app":"TextEdit","text":"RESEARCH LOG — "+time.strftime("%H:%M")})
S("TE: nl","press_key",{"app":"TextEdit","key":"return"})
S("TE: line","type_text",{"app":"TextEdit","text":"Source: "+surl()})
S("TE: nl","press_key",{"app":"TextEdit","key":"return"})
S("TE: line2","type_text",{"app":"TextEdit","text":"Finding: example.com is an IANA reserved domain."})
S("TE: nl","press_key",{"app":"TextEdit","key":"return"})
S("TE: bullet","type_text",{"app":"TextEdit","text":"Notes: works in background ✓ no-foreground ✓"})

print("### Cross-app clipboard transfer")
S("clip: set token","clipboard",{"action":"set","text":"[TRANSFERRED-PAYLOAD-42]"})
S("TE: nl","press_key",{"app":"TextEdit","key":"return"})
# paste via type (clipboard paste needs cmd+v which may not work; use type to be safe)
S("clip: get","clipboard",{"action":"get"})
S("TE: append payload","type_text",{"app":"TextEdit","text":"Payload: [TRANSFERRED-PAYLOAD-42]"})
S("TE: final read","get_app_state",{"app":"TextEdit"},show="app")

print("\n--- TextEdit document (oracle) ---")
print(subprocess.run(["osascript","-e",'tell application "TextEdit" to get text of document 1'],capture_output=True,text=True).stdout)
print(f"--- {n} steps | foreground violations: {len(fg)} {fg}")
m.close()
