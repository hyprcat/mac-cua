import Foundation
import MacCUACore

// Small session-layer support types ported from the Python helpers that
// `SessionManager` composes (elicitation.AppApprovalStore, lifecycle, analytics,
// tracing). These are pure logic — no macOS dependency — so they live in the
// Server target directly rather than behind a provider seam.

/// Per-session app approval gate. Mirrors `app/_lib/elicitation.AppApprovalStore`.
/// The current build auto-approves on first use (interactive elicitation is not
/// wired up), so this records approvals for the life of the process.
public final class AppApprovalStore {
    private var approved: Set<String> = []

    public init() {}

    public func isApproved(_ bundleId: String) -> Bool {
        approved.contains(bundleId)
    }

    public func approveForSession(_ bundleId: String) {
        approved.insert(bundleId)
    }
}

/// Tracks per-session activity and enforces the loop step limit. Mirrors
/// `app/_lib/lifecycle.SessionLifecycle`.
public final class SessionLifecycle {
    public let stepLimit: Int
    private(set) public var stepCount: Int = 0
    private(set) public var usedApps: [String] = []

    public init(stepLimit: Int) {
        self.stepLimit = stepLimit
    }

    public func trackAppUsed(_ bundleId: String) {
        if !usedApps.contains(bundleId) {
            usedApps.append(bundleId)
        }
    }

    public func incrementStep() {
        stepCount += 1
    }

    /// True once the limit is reached. `stepLimit <= 0` disables the limit.
    public func checkStepLimit() -> Bool {
        stepLimit > 0 && stepCount >= stepLimit
    }
}

/// Analytics sink. Real builds emit events; tests inject a no-op (the default).
/// Mirrors the call sites of `app/_lib/analytics.analytics`.
public protocol Analytics: AnyObject {
    func serviceLaunched()
    func mcpToolCalled(_ tool: String)
    func mcpAppApprovalResolved(_ bundleId: String, approved: Bool)
    func serviceResult(_ tool: String, success: Bool, durationMs: Double)
}

public final class NoopAnalytics: Analytics {
    public init() {}
    public func serviceLaunched() {}
    public func mcpToolCalled(_ tool: String) {}
    public func mcpAppApprovalResolved(_ bundleId: String, approved: Bool) {}
    public func serviceResult(_ tool: String, success: Bool, durationMs: Double) {}
}
