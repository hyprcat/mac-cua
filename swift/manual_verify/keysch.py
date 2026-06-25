import sys, json
sys.path.insert(0,"/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP
m=MCP(); m.initialize()
for t in m.list_tools()["result"]["tools"]:
    if t["name"] in ("press_key","select_text","set_value","drag","perform_secondary_action","batch","wait"):
        print("###",t["name"], "req:",t["inputSchema"].get("required"))
        print(" props:", list(t["inputSchema"].get("properties",{}).keys()))
m.close()
