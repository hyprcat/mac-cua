import Foundation
import MacCUACore

// `select_text` tool (Codex parity §D1, US-010 wiring). Turns a content/prefix/
// suffix/caret request into an unambiguous range via the pure `SelectTextResolver`
// (US-005), then applies it through the `SelectionProvider` seam. The real Mac
// selection (Tier-1 CFRange / Tier-2 AXTextMarker) lands in US-040 — for now the
// seam is mock-backed, but the spine wiring + range resolution are real.
//
// Background-only: the selection apply never raises/focuses/activates the window
// (Invariant 7). It is still an effect, so the user's frontmost is saved and
// restored (Invariant 15).
extension SessionManager {
    public func executeSelectText(_ params: [String: Any]) -> ToolResponse {
        providers.analytics.mcpToolCalled("select_text")

        guard let content = params["content"] as? String, !content.isEmpty else {
            return errorOnly("select_text requires non-empty 'content'.")
        }
        let prefix = params["prefix"] as? String
        let suffix = params["suffix"] as? String
        let caret = SessionManager.caretPlacement(stringArg(params, "caret"))

        var previousFrontmost: AppInfo?
        do {
            ensureTrackersStarted()
            let session = try resolveSession("select_text", params)
            try checkSafety(session.target.bundleId)
            checkApproval(session.target.bundleId)
            lifecycle.trackAppUsed(session.target.bundleId)
            lifecycle.incrementStep()
            if lifecycle.checkStepLimit() {
                throw AutomationError.stepLimit(
                    "Step limit reached (\(workarounds.loopStepLimit)). "
                    + "End your current loop and summarize progress.")
            }

            previousFrontmost = providers.apps.getFrontmostApp()

            // Resolve the optional target element (else the focused field).
            var axRef: AXElementRef?
            if let idx = elementIndex(params) {
                axRef = try resolveIndex(session, idx).axRef
            }

            // Ensure a selection client exists even when the systemSelection flag
            // is off — select_text needs it regardless.
            let client = session.selectionClient ?? providers.makeSelectionClient(session)
            session.selectionClient = client

            let text = try client.selectableText(axRef: axRef)
            let resolution = SelectTextResolver.resolve(
                text: text, target: content, prefix: prefix, suffix: suffix, caret: caret)

            switch resolution {
            case .resolved(let range):
                try client.applySelection(axRef: axRef, range: range)
                var response = takeSnapshot(session, skipRefresh: true)
                response.result = SessionManager.selectTextResultText(range: range, caret: caret)
                providers.analytics.serviceResult("select_text", success: true, durationMs: 0.0)
                restorePreviousFrontmostApp(session, previousFrontmost)
                return response
            case .notFound:
                restorePreviousFrontmostApp(session, previousFrontmost)
                return errorOnly(
                    "select_text: could not find \(repr(content)) in the target text.")
            case .ambiguous(let count):
                restorePreviousFrontmostApp(session, previousFrontmost)
                return errorOnly(
                    "select_text: \(repr(content)) matches \(count) places — add 'prefix' "
                    + "and/or 'suffix' to disambiguate.")
            }
        } catch let e as AutomationError {
            return errorOnly(e.message)
        } catch {
            return errorOnly("\(error)")
        }
    }

    /// Map the `caret` param to the pure `CaretPlacement` (default `.select`).
    static func caretPlacement(_ raw: String?) -> CaretPlacement {
        switch raw {
        case "before": return .before
        case "after": return .after
        default: return .select
        }
    }

    /// Human-readable summary of the applied selection / caret placement.
    static func selectTextResultText(range: MacCUACore.TextRange, caret: CaretPlacement) -> String {
        switch caret {
        case .select:
            return "Selected \(range.length) chars at offset \(range.location)."
        case .before:
            return "Placed caret before the match (offset \(range.location))."
        case .after:
            return "Placed caret after the match (offset \(range.location))."
        }
    }
}
