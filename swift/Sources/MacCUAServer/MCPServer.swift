import Foundation
import MacCUACore

// Thin server facade. Ports the MCP request handlers from `app/server.py`
// (`handle_list_tools` / `handle_call_tool`) WITHOUT the transport:
//
//   - listTools()  ←→ @server.list_tools()  → returns TOOL_DEFS
//   - callTool()   ←→ @server.call_tool()   → permissions gate, then
//                     session_mgr.execute(name, arguments or {}), then format_mcp
//
// DEFERRED (later phase, needs the remote MCP SDK + a real runtime):
//   - The stdio / JSON-RPC transport (`stdio_server`, `server.run`) and the
//     executable target. This layer is pure and Linux-testable.
//   - The 150s per-tool timeout. In Python it is an `asyncio.wait_for` around a
//     thread-pool `run_in_executor`. The concept is preserved as
//     `toolTimeoutS` and documented here, but this pure layer does not start
//     real timers / cancel work — that belongs with the async runtime wired
//     alongside the transport. See `handle_call_tool`'s TOOL_TIMEOUT_S.

/// Per-tool execution budget from `server.py` (`TOOL_TIMEOUT_S = 150`). Carried
/// as a documented constant; enforcement is deferred to the transport phase.
public let toolTimeoutS: Double = 150

public final class MCPServer {
    private let sessionManager: SessionManager
    private let permissions: PermissionsGate

    public init(sessionManager: SessionManager, permissions: PermissionsGate) {
        self.sessionManager = sessionManager
        self.permissions = permissions
    }

    /// Convenience: build the gate from the same providers the session manager
    /// uses, so the permission checks hit the same seams.
    public convenience init(sessionManager: SessionManager, providers: Providers) {
        self.init(
            sessionManager: sessionManager,
            permissions: PermissionsGate(apps: providers.apps, capture: providers.capture)
        )
    }

    /// Mirrors `handle_list_tools()` — the static tool catalogue.
    public func listTools() -> [ToolDef] {
        toolDefs
    }

    /// Mirrors `handle_call_tool(name, arguments)`. Runs the permissions gate
    /// first (returning the pending message as a single text block), otherwise
    /// executes the tool and formats the response. The spine's `execute` never
    /// throws — it always returns a `ToolResponse` (error becomes a snapshot +
    /// hint), so the "always return text even on error" guarantee holds here.
    public func callTool(name: String, arguments: [String: Any]?) -> [MCPContent] {
        // Step 4 in server.py: check permissions before executing any tool.
        if let pending = permissions.checkWithRetryGuidance() {
            return [.text(pending)]
        }

        let response = sessionManager.execute(name, arguments ?? [:])
        return formatMCP(response)
    }
}
