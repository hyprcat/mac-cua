// mac-cua — runnable MCP server over stdio (US-015).
//
// Wires the real MacCUAKit providers into SessionManager and exposes the same
// tool catalogue (`toolDefs`) over the official modelcontextprotocol/swift-sdk
// stdio transport. Ports the transport half of `app/server.py` that the pure
// `MCPServer` facade deliberately left out.
//
// Prime Invariant: the process sets its activation policy to `.accessory` so it
// never appears in the Dock and never becomes the active app. It NEVER calls
// `activate` / raises / warps the cursor. Permission prompts are surfaced
// through the system dialogs only.

import AppKit
import Foundation
import MCP
import MacCUACore
import MacCUAServer
import MacCUAKit

// MARK: - Bridges between the pure server layer and the MCP SDK types.

/// `ToolDef` (JSON-schema as `[String: Any]`) -> SDK `Tool` (schema as `Value`).
private func toSDKTool(_ def: ToolDef) -> Tool {
    let schema: Value
    do {
        schema = try JSONDecoder().decode(Value.self, from: def.inputSchemaJSONData())
    } catch {
        schema = .object([:])
    }
    return Tool(name: def.name, description: def.description, inputSchema: schema)
}

/// SDK call arguments (`[String: Value]`) -> the `[String: Any]` the spine takes.
private func toAnyArguments(_ args: [String: Value]?) -> [String: Any] {
    guard let args, !args.isEmpty else { return [:] }
    do {
        let data = try JSONEncoder().encode(args)
        let obj = try JSONSerialization.jsonObject(with: data)
        return (obj as? [String: Any]) ?? [:]
    } catch {
        return [:]
    }
}

/// `MCPContent` (text | image) -> SDK `Tool.Content`.
private func toSDKContent(_ block: MCPContent) -> Tool.Content {
    switch block {
    case .text(let text):
        return .text(text: text)
    case .image(let base64, let mimeType):
        return .image(data: base64, mimeType: mimeType)
    }
}

/// Serializes access to the (non-Sendable) `MCPServer` facade so the SDK's
/// concurrent `@Sendable` method handlers can reach the spine safely. The spine
/// processes one tool call at a time, which this actor enforces.
private actor ToolRouter {
    private let mcp: MCPServer
    private let permissions: PermissionsGate

    init() {
        let providers = makeKitProviders()
        let sessionManager = SessionManager(providers: providers)
        self.mcp = MCPServer(sessionManager: sessionManager, providers: providers)
        self.permissions = PermissionsGate(apps: providers.apps, capture: providers.capture)
    }

    func tools() -> [Tool] {
        mcp.listTools().map(toSDKTool)
    }

    func call(name: String, arguments: [String: Any]) -> [Tool.Content] {
        mcp.callTool(name: name, arguments: arguments).map(toSDKContent)
    }

    /// Explicit Accessibility preflight (does not consume the prompt-once latch).
    func accessibilityReady() -> Bool {
        permissions.accessibilityPreflight()
    }
}

// MARK: - Entry point.

@main
enum MacCUAMain {
    static func main() async {
        // Stay out of the Dock and the app switcher; never become the active
        // app. `.accessory` is the non-foregrounding policy (Prime Invariant).
        NSApplication.shared.setActivationPolicy(.accessory)

        let router = ToolRouter()

        // Explicit Accessibility preflight: AX is required for every tool, so
        // surface guidance early. The permissions gate still prompts on the
        // first real tool call (matching `app/server.py`). stdout is the MCP
        // wire, so guidance goes to stderr only.
        if await !router.accessibilityReady() {
            FileHandle.standardError.write(Data(
                ("[mac-cua] Accessibility permission not yet granted. The first "
                 + "tool call will prompt; grant it in System Settings > Privacy "
                 + "& Security > Accessibility, then retry.\n").utf8
            ))
        }

        let server = Server(
            name: "mac-cua",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: await router.tools())
        }

        await server.withMethodHandler(CallTool.self) { params in
            let content = await router.call(
                name: params.name,
                arguments: toAnyArguments(params.arguments)
            )
            return .init(content: content, isError: nil)
        }

        do {
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data("[mac-cua] fatal: \(error)\n".utf8))
            exit(1)
        }
    }
}
