import sys, subprocess, time
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
def doc(): return subprocess.run(["osascript","-e",'tell application "TextEdit" to get text of document 1'],capture_output=True,text=True).stdout.rstrip("\n")
m=MCP(); m.initialize(); APP="TextEdit"

# reset doc to known state
subprocess.run(["osascript","-e",'tell application "TextEdit" to set text of document 1 to "ABCDEFG"'])
print("seed:", repr(doc()))

# TEST 1: cmd+a select-all then type Z  -> expect "Z" if chord works, "ABCDEFGZ" if not
m.call("get_app_state",{"app":APP})
m.call("press_key",{"app":APP,"key":"cmd+a"})
time.sleep(0.3)
m.call("type_text",{"app":APP,"text":"Z"})
time.sleep(0.3)
r1=doc(); print("after cmd+a + 'Z':", repr(r1), "=> select-all", "WORKS" if r1=="Z" else "FAILED")

# TEST 2: cmd+c copy test
subprocess.run(["osascript","-e",'tell application "TextEdit" to set text of document 1 to "COPYME123"'])
subprocess.run(["osascript","-e",'set the clipboard to "PRECLIP"'])
m.call("press_key",{"app":APP,"key":"cmd+a"})
time.sleep(0.2)
m.call("press_key",{"app":APP,"key":"cmd+c"})
time.sleep(0.3)
clip=subprocess.run(["osascript","-e","get the clipboard"],capture_output=True,text=True).stdout.strip()
print("clipboard after cmd+c:", repr(clip), "=> copy", "WORKS" if "COPYME" in clip else "FAILED")

# TEST 3: plain (no modifier) sanity - type appends
subprocess.run(["osascript","-e",'tell application "TextEdit" to set text of document 1 to "X"'])
m.call("type_text",{"app":APP,"text":"YZ"})
time.sleep(0.2)
r3=doc(); print("plain type append:", repr(r3), "=>", "WORKS" if r3=="XYZ" else "?")
m.close()
