import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of

def frontmost():
    return subprocess.run(["osascript","-e",'tell application "System Events" to return name of first process whose frontmost is true'],capture_output=True,text=True).stdout.strip()
def doc_text():
    return subprocess.run(["osascript","-e",'tell application "TextEdit" to get text of document 1'],capture_output=True,text=True).stdout

m=MCP(); m.initialize()
APP="TextEdit"
viol=[]; step=0
def do(label, tool, args):
    global step; step+=1
    f0=frontmost()
    r=text_of(m.call(tool,args))
    f1=frontmost()
    bad = (f0!=f1)
    if bad: viol.append((step,label,f0,f1))
    err = next((l for l in r.splitlines() if "error" in l.lower() or "not allowed" in l.lower() or "fail" in l.lower()),"")
    print(f"{step:2} [{'  ' if not bad else 'FG'}] {label:34} front={f1:9} {('ERR:'+err[:50]) if err else ''}")
    return r

# clear and author a structured note
do("select all","press_key",{"app":APP,"key":"cmd+a"})
do("delete","press_key",{"app":APP,"key":"delete"})
do("title","type_text",{"app":APP,"text":"QUARTERLY REVIEW"})
do("nl","press_key",{"app":APP,"key":"return"})
do("nl","press_key",{"app":APP,"key":"return"})
do("h1","type_text",{"app":APP,"text":"Agenda:"})
do("nl","press_key",{"app":APP,"key":"return"})
do("i1","type_text",{"app":APP,"text":"1. Revenue review — Q3 up 12%"})
do("nl","press_key",{"app":APP,"key":"return"})
do("i2","type_text",{"app":APP,"text":"2. Roadmap planning 🚀"})
do("nl","press_key",{"app":APP,"key":"return"})
do("i3","type_text",{"app":APP,"text":"3. Café offsite ☕ — Zürich"})
do("nl","press_key",{"app":APP,"key":"return"})
do("nl","press_key",{"app":APP,"key":"return"})
do("foot","type_text",{"app":APP,"text":"Owner: ATG"})
do("read mid","get_app_state",{"app":APP})
do("select all 2","press_key",{"app":APP,"key":"cmd+a"})
do("copy","press_key",{"app":APP,"key":"cmd+c"})
do("clip get","clipboard",{"action":"get"})
do("right (deselect)","press_key",{"app":APP,"key":"right"})
do("nl","press_key",{"app":APP,"key":"return"})
do("append","type_text",{"app":APP,"text":"-- END --"})
do("home","press_key",{"app":APP,"key":"cmd+up"})
do("read final","get_app_state",{"app":APP})

print("\n--- final document (oracle) ---")
print(doc_text())
print("--- summary ---")
print("steps:", step, "| foreground violations:", len(viol), viol)
m.close()
