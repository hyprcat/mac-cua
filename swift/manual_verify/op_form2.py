import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def front(): return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
def out(): return subprocess.run(["osascript","-e",'tell application "Safari" to do JavaScript "document.getElementById(\'out\').textContent" in current tab of window 1'],capture_output=True,text=True).stdout.strip()
def fieldval(i): return subprocess.run(["osascript","-e",f'tell application "Safari" to do JavaScript "document.getElementById(\'{i}\').value" in current tab of window 1'],capture_output=True,text=True).stdout.strip()
m=MCP(); m.initialize(); APP="Safari"; fg=[]
def OP(label, fn):
    r=fn(); f=front()
    if f!="Terminal": fg.append((label,f))
    print(f"OP {label:42} front={f:9} | {r if isinstance(r,str) else ''}")
def call(tool,args): 
    text_of(m.call(tool,args)); return ""

# refresh tree (indices stable from prior read)
m.call("get_app_state",{"app":APP})
OP("set_value name field (#8)", lambda: (call("set_value",{"app":APP,"element_index":"8","value":"Ada Lovelace"}), "name="+fieldval("name"))[1])
OP("type into email field via click+type", lambda: (call("click",{"app":APP,"element_index":"11"}), call("type_text",{"app":APP,"element_index":"11","text":"ada@analytical.engine"}), "email="+fieldval("email"))[1])
OP("set_value bio textarea (#14)", lambda: (call("set_value",{"app":APP,"element_index":"14","value":"First programmer. Loves looms & numbers."}), "bio="+fieldval("bio")[:30])[1])
OP("dropdown select Japan (set_value #17)", lambda: (call("set_value",{"app":APP,"element_index":"17","value":"Japan"}), "country="+fieldval("country"))[1])
OP("checkbox toggle agree (#18)", lambda: (call("click",{"app":APP,"element_index":"18"}), "agree="+fieldval("agree"))[1])
OP("slider set_value 75 (#21)", lambda: (call("set_value",{"app":APP,"element_index":"21","value":"75"}), "vol="+fieldval("vol"))[1])
OP("scroll form down", lambda: call("scroll",{"app":APP,"x":300,"y":400,"direction":"down","amount":3}))
OP("click Submit (#23)", lambda: (call("click",{"app":APP,"element_index":"23"}), "")[1])
time.sleep(0.6)
print("\nFORM OUTPUT:", out())
print("foreground violations:", fg)
m.close()
