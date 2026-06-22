import Foundation

// Local stand-in for the MCP SDK's content blocks (`mcp.types.TextContent` /
// `ImageContent` in `app/server.py`). The real swift-sdk is a remote dependency
// and the build env is offline, so the server layer is implemented as PURE,
// Linux-testable Swift against this value type. When the stdio/JSON-RPC
// transport is wired in a later phase, this maps 1:1 onto the SDK types.

/// One output block returned to the model from a tool call. Mirrors the
/// `TextContent | ImageContent` union that `format_mcp` produces in `server.py`.
public enum MCPContent: Equatable {
    /// A text block (`TextContent(type="text", text=...)`).
    case text(String)
    /// An inline image block (`ImageContent(type="image", data=..., mimeType=...)`).
    /// `base64` is the raw base64 PNG payload; `mimeType` is e.g. `"image/png"`.
    case image(base64: String, mimeType: String)
}
