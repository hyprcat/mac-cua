import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def front(): return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
m=MCP(); m.initialize(); fg=[]
def note(lbl): 
    f=front()
    if f!="Terminal": fg.append((lbl,f))
    return f

print("### CALCULATOR — clean 7 x 8 = 56")
m.call("get_app_state",{"app":"Calculator"})
for idx in ["6","9","12","10","24"]:  # Clear,7,x,8,=
    text_of(m.call("click",{"app":"Calculator","element_index":idx})); note("calc")
t=text_of(m.call("get_app_state",{"app":"Calculator"}))
res=next((l.strip() for l in t.splitlines() if "Edit field" in l or ("text" in l.lower() and any(c.isdigit() for c in l))),"?")
print("  result node:", res[:60], "front:",note("calc"))

print("### NOTES — type into a note (native rich text)")
t=text_of(m.call("get_app_state",{"app":"Notes"}))
ta=next((l.strip().split()[0] for l in t.splitlines() if l.strip()[:1].isdigit() and ("text area" in l.lower() or "text view" in l.lower())),None)
print("  text area idx:", ta)
if ta:
    text_of(m.call("click",{"app":"Notes","element_index":ta})); note("notes")
text_of(m.call("type_text",{"app":"Notes","text":"CUA background entry — 1 2 3 ✓"})); note("notes")
print("  front:",note("notes"))

print("### FINDER — click sidebar + read")
t=text_of(m.call("get_app_state",{"app":"Finder"}))
row=next((l.strip().split()[0] for l in t.splitlines() if l.strip()[:1].isdigit() and ("Applications" in l or "Documents" in l or "Desktop" in l)),None)
print("  sidebar row idx:", row)
if row:
    text_of(m.call("click",{"app":"Finder","element_index":row})); note("finder"); time.sleep(0.5)
t2=text_of(m.call("get_app_state",{"app":"Finder"}))
title=next((l.strip() for l in t2.splitlines() if l.startswith("Window:")),"?")
print("  finder window now:", title[:70], "front:",note("finder"))

print("\nforeground violations:", fg)
m.close()
