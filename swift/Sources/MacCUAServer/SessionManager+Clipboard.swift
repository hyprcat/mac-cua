import Foundation
import MacCUACore

// `clipboard` tool (Codex parity §D2, US-010 wiring). Background-safe pasteboard
// get/set/clear through the `ClipboardProvider` seam. The real Mac NSPasteboard
// impl is US-041 — for now the seam is mock-backed, but the spine routing is real.
//
// The pasteboard is system-wide: there is no app target, no session, no settle,
// and nothing is ever foregrounded, so the Prime Invariant holds trivially.
extension SessionManager {
    public func executeClipboard(_ params: [String: Any]) -> ToolResponse {
        providers.analytics.mcpToolCalled("clipboard")

        guard let action = stringArg(params, "action") else {
            return errorOnly("clipboard requires 'action' (get | set | clear).")
        }

        do {
            let result: String
            switch action {
            case "get":
                let text = try providers.clipboard.get()
                result = text.map { "Clipboard: \(repr($0))" } ?? "Clipboard is empty."
            case "set":
                guard let text = params["text"] as? String else {
                    return errorOnly("clipboard action='set' requires 'text'.")
                }
                try providers.clipboard.set(text)
                result = "Clipboard set (\(text.count) chars)."
            case "clear":
                try providers.clipboard.clear()
                result = "Clipboard cleared."
            default:
                return errorOnly("clipboard: unknown action \(repr(action)) (use get | set | clear).")
            }
            providers.analytics.serviceResult("clipboard", success: true, durationMs: 0.0)
            return ToolResponse(app: "clipboard", pid: 0, snapshotId: 0, result: result)
        } catch let e as AutomationError {
            return errorOnly(e.message)
        } catch {
            return errorOnly("\(error)")
        }
    }
}
