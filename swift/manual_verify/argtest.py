import sys
sys.path.insert(0, "/Users/affan/mac-cua/swift/manual_verify")
from driver import MCP, text_of
m = MCP(); m.initialize()
def appline(t): 
    return next((l for l in t.splitlines() if l.startswith("App=")), "(no App= line)")
print("window_id=410 (Terminal):", appline(text_of(m.call("get_app_state",{"window_id":410}))))
print("window_id=999999 (bogus):", appline(text_of(m.call("get_app_state",{"window_id":999999}))))
print("no args            :", appline(text_of(m.call("get_app_state",{}))))
print("type_text NO text arg:", text_of(m.call("type_text",{})).splitlines()[1] if len(text_of(m.call("type_text",{})).splitlines())>1 else "?")
m.close()
