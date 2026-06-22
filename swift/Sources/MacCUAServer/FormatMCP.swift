import Foundation
import MacCUACore

// Faithful port of `format_mcp(response)` from `app/server.py`. Turns a
// `ToolResponse` (assembled by the spine in `session.py`) into the ordered list
// of MCP content blocks the model sees.
//
// Two paths, exactly as in Python:
//   1. No tree (`treeText == nil`): emit `result` and/or `error` as plain text
//      blocks. Used by `list_apps` and pure error responses.
//   2. Full path: a version header + result/error, then the `<app_state>`
//      wrapper holding the (already-scrubbed) tree text — with optional
//      `<app_specific_instructions>` guidance injection and an appended system
//      selection — followed by an optional trailing image block.
//
// Invariant 8: the model must never see AX refs/handles. `treeText` is produced
// by Core's serializer, which never emits `axRef`/graph metadata, so this layer
// only assembles already-safe strings and copies `response.screenshot` (base64)
// verbatim. We add nothing that could leak a reference.

/// Render a `ToolResponse` into MCP content blocks. Mirrors `format_mcp`.
public func formatMCP(_ response: ToolResponse) -> [MCPContent] {
    var blocks: [MCPContent] = []

    // ── No-tree path (error/result only) ───────────────────────────────────
    if response.treeText == nil {
        if let result = response.result, !result.isEmpty {
            blocks.append(.text(result))
        }
        if let error = response.error, !error.isEmpty {
            blocks.append(.text(error))
        }
        return blocks
    }

    // ── Full path ──────────────────────────────────────────────────────────
    let treeText = response.treeText!  // non-nil per the guard above

    var parts: [String] = []
    parts.append(Version.formatResponseHeader())
    if let result = response.result, !result.isEmpty {
        parts.append(result)
    }
    if let error = response.error, !error.isEmpty {
        parts.append(error)
    }

    var appStateParts: [String] = [treeText]

    // Guidance injection: wrap in <app_specific_instructions> and splice it in
    // right after the tree header (the text up to the first blank line), falling
    // back to prefixing the whole tree when there is no header break.
    if let guidance = response.guidance, !guidance.isEmpty {
        let wrappedGuidance =
            "<app_specific_instructions>\n\(guidance)\n</app_specific_instructions>"
        if let headerRange = treeText.range(of: "\n\n") {
            let header = String(treeText[treeText.startIndex..<headerRange.lowerBound])
            let treeBody = String(treeText[headerRange.upperBound...])
            appStateParts = ["\(header)\n\n\(wrappedGuidance)\n\n\(treeBody)"]
        } else {
            appStateParts = ["\(wrappedGuidance)\n\n\(treeText)"]
        }
    }

    // Append system selection if present.
    if let systemSelection = response.systemSelection, !systemSelection.isEmpty {
        appStateParts.append("")
        appStateParts.append(systemSelection)
    }

    parts.append("")
    parts.append("<app_state>")
    parts.append(contentsOf: appStateParts)
    parts.append("</app_state>")

    blocks.append(.text(parts.joined(separator: "\n")))

    // Optional trailing image block.
    if let screenshot = response.screenshot, !screenshot.isEmpty {
        blocks.append(.image(base64: screenshot, mimeType: "image/png"))
    }

    return blocks
}
