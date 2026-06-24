import Foundation
import MacCUACore

// Small session-layer support types ported from the Python helpers that
// `SessionManager` composes (elicitation.AppApprovalStore, lifecycle, analytics,
// tracing). These are pure logic — no macOS dependency — so they live in the
// Server target directly rather than behind a provider seam.
//
// US-013 audit (port load-bearing pure logic OR record out-of-scope, per PRD §9):
//   • elicitation.AppApprovalStore  -> ported in full below (session + persistent
//     + denied + RISK_WARNING). Interactive MCP elicitation *prompts* are deferred
//     to the executable/MCP layer (US-015); the auto-approve call path stays.
//   • lifecycle.SessionLifecycle    -> ported (step limit + app tracking + turn
//     metadata grouping).
//   • analytics.AnalyticsLogger     -> the spine call sites are the `Analytics`
//     protocol; a `BufferingAnalytics` mirrors the verbatim events/flush buffer.
//   • tracing.Tracer/Span           -> OUT OF SCOPE (observability only; the
//     OSSignposter-equivalent timing spans are not load-bearing and the spine does
//     not depend on them). Recorded in PRD §6/§9. Not ported.

// MARK: - App approval (ports elicitation.py)

/// Risk warning shown before granting an app automation approval.
/// Verbatim from `app/_lib/elicitation.RISK_WARNING`.
public let appApprovalRiskWarning =
    "Allowing automation to use this app introduces new risks, including those "
    + "related to prompt injection attacks, such as data theft or loss. "
    + "Carefully monitor automation while it uses this app."

/// Persistence seam for the approval store. The default build is filesystem-backed
/// (`~/.config/mac-cua/approvals.json`); tests inject an in-memory fake. Kept as a
/// protocol so the store logic stays Linux-pure and unit-testable without touching
/// the disk.
public protocol ApprovalStorage: AnyObject {
    func loadApprovedBundles() -> [String]
    func saveApprovedBundles(_ bundles: [String])
}

/// Filesystem-backed approval persistence. Mirrors elicitation.py
/// `_load_persistent`/`_save_persistent`. Foundation-only (works on Linux too).
public final class FileApprovalStorage: ApprovalStorage {
    private let path: URL

    public init(path: URL? = nil) {
        if let path {
            self.path = path
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.path = home
                .appendingPathComponent(".config/mac-cua/approvals.json")
        }
    }

    public func loadApprovedBundles() -> [String] {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundles = obj["approved_bundles"] as? [String]
        else { return [] }
        return bundles
    }

    public func saveApprovedBundles(_ bundles: [String]) {
        let dir = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = ["approved_bundles": bundles.sorted()]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: path)
    }
}

/// Per-session + persistent app approval gate. Mirrors
/// `app/_lib/elicitation.AppApprovalStore`. The current build auto-approves on
/// first use (interactive elicitation prompts are wired up in US-015); this records
/// session approvals, optionally-persisted approvals, and explicit denials.
public final class AppApprovalStore {
    private var sessionApproved: Set<String> = []
    private var persistentApproved: Set<String> = []
    private var denied: Set<String> = []
    private let storage: ApprovalStorage?

    /// `storage == nil` => session-only (no persistence), preserving the prior
    /// behavior. Pass a storage to enable persistent approvals.
    public init(storage: ApprovalStorage? = nil) {
        self.storage = storage
        if let storage {
            persistentApproved = Set(storage.loadApprovedBundles())
        }
    }

    public func isApproved(_ bundleId: String) -> Bool {
        sessionApproved.contains(bundleId) || persistentApproved.contains(bundleId)
    }

    public func isDenied(_ bundleId: String) -> Bool {
        denied.contains(bundleId)
    }

    public func approveForSession(_ bundleId: String) {
        sessionApproved.insert(bundleId)
        denied.remove(bundleId)
    }

    public func approvePersistently(_ bundleId: String) {
        persistentApproved.insert(bundleId)
        denied.remove(bundleId)
        storage?.saveApprovedBundles(Array(persistentApproved))
    }

    public func deny(_ bundleId: String) {
        denied.insert(bundleId)
    }

    public func clearSessionApprovals() {
        sessionApproved.removeAll()
    }
}

// MARK: - Session lifecycle (ports lifecycle.py)

/// Per-turn state tracking. Mirrors `app/_lib/lifecycle.TurnMetadata`.
/// `startedAt` is injected (no clock call here — keeps Server Linux-pure/testable).
public struct TurnMetadata {
    public let turnId: String
    public let startedAt: Double
    public var stepCount: Int = 0
    public var appsUsed: Set<String> = []

    public init(turnId: String, startedAt: Double = 0) {
        self.turnId = turnId
        self.startedAt = startedAt
    }
}

/// Tracks per-session activity, the loop step limit, and optional per-turn
/// metadata. Mirrors `app/_lib/lifecycle.SessionLifecycle`.
public final class SessionLifecycle {
    public let stepLimit: Int
    private(set) public var stepCount: Int = 0
    private(set) public var usedApps: [String] = []
    private(set) public var currentTurn: TurnMetadata?

    public init(stepLimit: Int) {
        self.stepLimit = stepLimit
    }

    public func startTurn(_ turnId: String, startedAt: Double = 0) {
        currentTurn = TurnMetadata(turnId: turnId, startedAt: startedAt)
    }

    public func endTurn() {
        currentTurn = nil
    }

    public func trackAppUsed(_ bundleId: String) {
        if !usedApps.contains(bundleId) {
            usedApps.append(bundleId)
        }
        currentTurn?.appsUsed.insert(bundleId)
    }

    public func incrementStep() {
        stepCount += 1
        currentTurn?.stepCount += 1
    }

    /// True once the limit is reached. `stepLimit <= 0` disables the limit.
    public func checkStepLimit() -> Bool {
        stepLimit > 0 && stepCount >= stepLimit
    }
}

// MARK: - Analytics (ports analytics.py call sites)

/// Analytics sink. Real builds emit events; tests inject a no-op (the default).
/// Mirrors the call sites of `app/_lib/analytics.analytics`. New event hooks ship
/// with default no-op extensions so existing conformers keep compiling.
public protocol Analytics: AnyObject {
    func serviceLaunched()
    func mcpToolCalled(_ tool: String)
    func mcpAppApprovalResolved(_ bundleId: String, approved: Bool)
    func serviceResult(_ tool: String, success: Bool, durationMs: Double)
    func serviceIdleTimeoutReached()
    func sessionStarted(_ bundleId: String)
    func sessionEnded(_ bundleId: String)
    func mcpAppApprovalRequested(_ bundleId: String)
}

public extension Analytics {
    func serviceIdleTimeoutReached() {}
    func sessionStarted(_ bundleId: String) {}
    func sessionEnded(_ bundleId: String) {}
    func mcpAppApprovalRequested(_ bundleId: String) {}
}

public final class NoopAnalytics: Analytics {
    public init() {}
    public func serviceLaunched() {}
    public func mcpToolCalled(_ tool: String) {}
    public func mcpAppApprovalResolved(_ bundleId: String, approved: Bool) {}
    public func serviceResult(_ tool: String, success: Bool, durationMs: Double) {}
}

/// Captures structured events in memory. Mirrors `analytics.AnalyticsLogger`
/// (`events` buffer + `flush`). Useful for tests and a future audit sink.
public final class BufferingAnalytics: Analytics {
    public struct Event: Equatable {
        public let name: String
        public let fields: [String: String]
    }

    public private(set) var events: [Event] = []

    public init() {}

    private func log(_ name: String, _ fields: [String: String] = [:]) {
        events.append(Event(name: name, fields: fields))
    }

    /// Drains and returns the buffered events. Mirrors `AnalyticsLogger.flush`.
    public func flush() -> [Event] {
        let drained = events
        events = []
        return drained
    }

    public func serviceLaunched() { log("service_launched") }
    public func mcpToolCalled(_ tool: String) { log("mcp_tool_called", ["mcp_tool_name": tool]) }
    public func mcpAppApprovalResolved(_ bundleId: String, approved: Bool) {
        log("mcp_app_approval_resolved",
            ["bundle_id": bundleId, "mcp_approval_result": approved ? "approved" : "denied"])
    }
    public func serviceResult(_ tool: String, success: Bool, durationMs: Double) {
        log("service_result",
            ["tool": tool, "success": String(success), "duration_ms": String(durationMs)])
    }
    public func serviceIdleTimeoutReached() { log("service_idle_timeout_reached") }
    public func sessionStarted(_ bundleId: String) { log("session_started", ["bundle_id": bundleId]) }
    public func sessionEnded(_ bundleId: String) { log("session_ended", ["bundle_id": bundleId]) }
    public func mcpAppApprovalRequested(_ bundleId: String) {
        log("mcp_app_approval_requested", ["bundle_id": bundleId])
    }
}
