import sys, json
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP
m = MCP(); m.initialize()
tl = m.list_tools()
for t in tl["result"]["tools"]:
    if t["name"] in ("get_app_state","click","type_text","list_apps"):
        print("###", t["name"])
        print(json.dumps(t["inputSchema"].get("properties",{}), indent=1)[:900])
        print("required:", t["inputSchema"].get("required"))
m.close()
