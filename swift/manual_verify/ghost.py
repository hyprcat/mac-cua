import sys, subprocess, time, threading
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m=MCP(); m.initialize()
# warm the session so ghost is tracking
text_of(m.call("get_app_state",{"app":"TextEdit"}))
# fire several rapid clicks while capturing screen mid-stream
def capture(n): subprocess.run(["screencapture","-x","-t","png",f"/Users/affan/mac-cua/swift/manual_verify/ghost_{n}.png"])
for i in range(6):
    threading.Thread(target=lambda i=i: m.call("click",{"app":"TextEdit","x":300,"y":250})).start()
    time.sleep(0.08)
    capture(i)
    time.sleep(0.25)
print("captured")
m.close()
