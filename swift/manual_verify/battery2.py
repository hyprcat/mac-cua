import sys, subprocess, time
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of

def frontmost():
    s='tell application "System Events" to return name of first process whose frontmost is true'
    return subprocess.run(["osascript","-e",s],capture_output=True,text=True).stdout.strip()

m=MCP(); m.initialize()
def appline(t): return next((l for l in t.splitlines() if l.startswith("App=")), "(no App=)")
def fb(t):
    for l in t.splitlines():
        if "transport" in l.lower() or "not allowed" in l.lower() or "confirm" in l.lower():
            return l.strip()
    return ""

results=[]
def step(label, tool, args, read=False):
    f0=frontmost()
    t=text_of(m.call(tool,args))
    time.sleep(0.25); f1=frontmost()
    ok = f0==f1
    results.append(ok)
    print(f"[{'PASS' if ok else 'FAIL-FOREGROUND'}] {label}: front {f0!r}->{f1!r}")
    print("    ", appline(t), "| img" if "<image" in t else "| NO-IMG", "|", fb(t)[:90])
    return t

print("==== SAFARI (web) ====")
ts=step("read Safari","get_app_state",{"app":"Safari"})
# show a few interactive nodes
for l in ts.splitlines():
    if "link" in l.lower() or "button" in l.lower() or "More information" in l:
        print("    node:", l.strip()[:80]); break
step("click Safari @600,400","click",{"app":"Safari","x":600,"y":400})
step("scroll Safari","scroll",{"app":"Safari","x":600,"y":400,"direction":"down","amount":3})

print("==== TEXTEDIT (native) ====")
step("read TextEdit","get_app_state",{"app":"TextEdit"})
step("type TextEdit","type_text",{"app":"TextEdit","text":"Hello from mac-cua 🚀 café"})
step("read TextEdit again","get_app_state",{"app":"TextEdit"})

print("\nNO-FOREGROUND:", "ALL PASS" if all(results) else "VIOLATION DETECTED")
m.close()
