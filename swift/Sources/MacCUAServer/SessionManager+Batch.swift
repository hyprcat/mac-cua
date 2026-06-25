import Foundation
import MacCUACore

// BATCH TOOL (Codex parity §D3) — N actions in one MCP call. There is NO Python
// reference for this; it is a new server-spine surface designed to remove N-1
// round-trips. Semantics (per docs/CODEX_PARITY_CHANGES.md §D3 and the US-008
// acceptance criteria):
//
//   - Linear: actions run sequentially in the order supplied.
//   - Stop-on-first-failure: the first failing step halts the batch; remaining
//     steps are reported as not-run.
//   - One final snapshot: exactly one screenshot + tree snapshot is captured at
//     the end (NOT once per step), with a per-step outcome list in `result`.
//   - Reuses the turn cache (US-004) for the pre-action tree: the tree is walked
//     at most once for the whole batch and reused for every element-index
//     resolution, instead of re-walking before each step.
//
// Like `execute`, this NEVER throws to the caller — every error becomes part of
// the per-step outcome list plus a final snapshot (the "Failproof" goal).

extension SessionManager {

    /// Tools that may appear as a batch step. State-only / meta tools (list_apps,
    /// get_app_state, batch) are intentionally excluded — a batch is a sequence
    /// of *actions* terminated by one snapshot.
    static let batchableTools: Set<String> = [
        "click", "type_text", "set_value", "press_key",
        "scroll", "drag", "perform_secondary_action",
    ]

    /// Execute a `batch` tool call. See the file header for the contract.
    public func executeBatch(_ params: [String: Any]) -> ToolResponse {
        providers.analytics.mcpToolCalled("batch")

        guard let actions = parseBatchActions(params), !actions.isEmpty else {
            return errorOnly(
                "batch requires a non-empty 'actions' array. Each item is an object "
                + "with a 'tool' field plus that tool's parameters.")
        }

        ensureTrackersStarted()

        // Turn-scoped cache (US-004): one instance for the whole batch so the
        // pre-action tree is walked once and reused for every step.
        let cache = TurnCache()

        var outcomes: [String] = []
        var previousFrontmost: AppInfo?
        var lastSession: AppSession?
        var lastTool = "click"
        var halted = false
        var succeeded = 0

        for (i, action) in actions.enumerated() {
            let step = i + 1
            let stepTool = stringArg(action, "tool") ?? ""

            // Validate the step tool before doing anything stateful.
            guard SessionManager.batchableTools.contains(stepTool) else {
                outcomes.append(
                    "Step \(step): FAILED — unsupported batch tool '\(stepTool)'. "
                    + "Allowed: \(SessionManager.batchableTools.sorted().joined(separator: ", ")).")
                halted = true
                appendNotRun(&outcomes, from: step, total: actions.count)
                break
            }

            do {
                // Resolve the target. An item may retarget via window_id/app;
                // otherwise it reuses the previous step's session.
                let session: AppSession
                if action["window_id"] != nil || action["app"] != nil {
                    session = try resolveSession(stepTool, action)
                } else if let last = lastSession {
                    session = last
                } else {
                    throw AutomationError.automation(
                        "The first batch action must specify window_id or app.")
                }
                lastSession = session
                lastTool = stepTool

                // Save the user's frontmost once, before the first effecting step
                // (Invariant 15: only ever restore the USER's app, never the target).
                if previousFrontmost == nil {
                    previousFrontmost = providers.apps.getFrontmostApp()
                }

                // Safety + approval + lifecycle, per step (a step may retarget).
                try checkSafety(session.target.bundleId)
                checkApproval(session.target.bundleId)
                lifecycle.trackAppUsed(session.target.bundleId)

                // Pre-action tree reuse (US-004): make the tree available for
                // element-index resolution without re-walking each step.
                ensureBatchPreActionTree(session, cache)

                let result = try dispatch(stepTool, session, action)
                outcomes.append("Step \(step) [\(stepTool)]: \(result)")
                succeeded += 1

                // The action may have mutated the tree → drop the cached pre-action
                // tree for this pid so the next step / final snapshot re-walks.
                cache.invalidateTree(pid: session.target.pid)
            } catch let e as AutomationError {
                outcomes.append("Step \(step) [\(stepTool)]: FAILED — \(e.message)")
                halted = true
                appendNotRun(&outcomes, from: step, total: actions.count)
                break
            } catch {
                outcomes.append("Step \(step) [\(stepTool)]: FAILED — \(error)")
                halted = true
                appendNotRun(&outcomes, from: step, total: actions.count)
                break
            }
        }

        // Build the summary line.
        let summary = halted
            ? "Batch halted on first failure (\(succeeded)/\(actions.count) steps succeeded)."
            : "Batch complete: \(succeeded)/\(actions.count) steps succeeded."
        let resultText = (outcomes + ["", summary]).joined(separator: "\n")

        // No step ever resolved a session (e.g. first tool unsupported) → bare
        // error-style response carrying the outcome list.
        guard let session = lastSession else {
            return ToolResponse(app: "unknown", pid: 0, snapshotId: 0, result: resultText)
        }

        // One settle + one final snapshot for the whole batch.
        let settleTimeout = settleTimeouts[lastTool] ?? 1.0
        if settleTimeout > 0, let settle = session.settleMonitor {
            _ = settle.waitForSettle(
                context: "batch", timeout: settleTimeout, quietPeriod: settleQuietPeriod)
        }

        var response = takeSnapshot(session, skipRefresh: true)
        response.result = resultText
        providers.analytics.serviceResult("batch", success: !halted, durationMs: 0.0)

        // Restore the user's previous frontmost (Invariant 15) + return.
        restorePreviousFrontmostApp(session, previousFrontmost)
        cache.clear()
        return response
    }

    // MARK: - Helpers

    /// Pull the ordered action list out of the raw params, tolerant of the
    /// JSON-variant shapes that arrive over MCP (`[[String: Any]]` directly, or
    /// `[Any]` whose elements are dictionaries).
    private func parseBatchActions(_ params: [String: Any]) -> [[String: Any]]? {
        if let typed = params["actions"] as? [[String: Any]] { return typed }
        if let loose = params["actions"] as? [Any] {
            return loose.compactMap { $0 as? [String: Any] }
        }
        return nil
    }

    /// Append "not run" markers for every step after `from` (1-based, inclusive
    /// of the failing step which already has its own line).
    private func appendNotRun(_ outcomes: inout [String], from failedStep: Int, total: Int) {
        guard failedStep < total else { return }
        for s in (failedStep + 1)...total {
            outcomes.append("Step \(s): not run (batch halted).")
        }
    }

    /// Ensure the session has a pre-action tree available for element-index
    /// resolution, walking at most once and caching it in the turn cache so
    /// subsequent steps reuse it instead of re-walking. If a prior snapshot
    /// already populated `treeNodes`/`refetchableTree`, that is reused as-is.
    private func ensureBatchPreActionTree(_ session: AppSession, _ cache: TurnCache) {
        let pid = session.target.pid
        if let cached = cache.tree(forPid: pid) {
            if session.treeNodes.isEmpty { session.treeNodes = cached }
            return
        }
        if session.treeNodes.isEmpty && session.refetchableTree == nil {
            let t = session.target
            var nodes = collectTreeNodes(
                t.axWindow, axApp: t.axApp, targetPid: t.pid, appType: session.appType)
            nodes = pruneTreeNodes(
                nodes, bundleId: t.bundleId, appType: session.appType,
                axApp: t.axApp, targetPid: t.pid)
            session.treeNodes = nodes
        }
        cache.setTree(session.treeNodes, forPid: pid)
    }
}
