import Foundation
import MacCUACore

// `wait` tool (Codex parity §D4, US-009). An explicit settle/observe step with
// no synthetic input: it drives the same event-driven `DebounceStateMachine`
// (via the `SettleMonitor` seam) that the action pipeline runs after every
// effect, then returns a fresh snapshot. There is NO Python reference — this is
// a new Codex-parity surface.
//
// Read-only by construction: like `get_app_state`, it never saves/restores the
// user's frontmost app and never opens the user-interaction tap (there is no
// effect to attribute), so the Prime Invariant is preserved trivially.
extension SessionManager {
    /// Default + hard cap for the `timeout` parameter (seconds).
    static let waitDefaultTimeout = 2.0
    static let waitMaxTimeout = 10.0

    public func executeWait(_ params: [String: Any]) -> ToolResponse {
        providers.analytics.mcpToolCalled("wait")

        // Clamp the requested timeout into [0, cap]; non-positive/absent → default.
        let requested = doubleArg(params, "timeout") ?? SessionManager.waitDefaultTimeout
        let timeout = max(0.0, min(requested, SessionManager.waitMaxTimeout))

        do {
            ensureTrackersStarted()
            let session = try resolveSession("wait", params)
            try checkSafety(session.target.bundleId)
            checkApproval(session.target.bundleId)
            lifecycle.trackAppUsed(session.target.bundleId)

            // Drive the DebounceStateMachine via the SettleMonitor with the tool
            // timeout. No monitor (or zero budget) means "nothing to settle" →
            // treat as already quiet.
            let outcome: SettleResult
            if timeout > 0, let settle = session.settleMonitor {
                outcome = settle.waitForSettle(
                    context: "wait", timeout: timeout, quietPeriod: settleQuietPeriod)
            } else {
                outcome = .noChange
            }

            var response = takeSnapshot(session, skipRefresh: true)
            response.result = SessionManager.waitResultText(outcome, timeout: timeout)
            providers.analytics.serviceResult("wait", success: true, durationMs: 0.0)
            return response
        } catch let e as AutomationError {
            return errorOnly(e.message)
        } catch {
            return errorOnly("\(error)")
        }
    }

    /// Human-readable summary of how the settle resolved.
    static func waitResultText(_ outcome: SettleResult, timeout: Double) -> String {
        switch outcome {
        case .settled:
            return "UI settled."
        case .noChange:
            return "UI was already quiet — nothing to wait for."
        case .cancelled:
            return "Wait cancelled (user interaction or invalidation)."
        case .timeout:
            return String(
                format: "Waited up to %.2gs but the UI kept changing (hit the wait cap). "
                + "It may still be animating or loading.", timeout)
        }
    }
}

/// Coerce a JSON-variant value to Double (mirrors `intArg`/`stringArg`).
func doubleArg(_ params: [String: Any], _ key: String) -> Double? {
    guard let raw = params[key] else { return nil }
    switch raw {
    case let d as Double: return d
    case let i as Int: return Double(i)
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}
