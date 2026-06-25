import sys, subprocess, time, threading
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP
m=MCP(); m.initialize()
m.call("get_app_state",{"app":"Safari"})
for i in range(8):
    threading.Thread(target=lambda: m.call("click",{"app":"Safari","x":300,"y":300})).start()
    time.sleep(0.06)
    subprocess.run(["screencapture","-x","-t","png",f"/Users/affan/mac-cua/swift/manual_verify/sg_{i}.png"])
    time.sleep(0.2)
m.close(); print("done")
