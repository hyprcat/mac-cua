import Foundation
import MacCUACore

// ORCHESTRATION SPINE — execute() pipeline, session resolution, snapshot
// assembly, tree collection/pruning, graph/transient handling, list_apps.
//
// STATUS: STUB. Bodies are placeholders so the package compiles; the spine
// sub-agent replaces this whole file with the faithful port of `app/session.py`
// (the 12-step pipeline + helpers). Method signatures here are the contract the
// handler file and server layer compile against — keep them stable.

extension SessionManager {

    // MARK: Public entry

    /// The 12-step action pipeline. Always returns a `ToolResponse` (never throws
    /// to the caller — errors become a snapshot+hint, Invariant "Failproof").
    public func execute(_ tool: String, _ params: [String: Any]) -> ToolResponse {
        // TODO(spine): port execute() (session.py:614).
        return errorOnly("unimplemented: execute(\(tool))")
    }

    // MARK: Pipeline gates

    func ensureTrackersStarted() { /* TODO(spine) */ }
    func checkSafety(_ bundleId: String) throws { /* TODO(spine) */ }
    func checkApproval(_ bundleId: String) { /* TODO(spine) */ }

    // MARK: Session lifecycle

    func dropSession(windowId: Int) { /* TODO(spine) */ }
    func trackSession(_ session: AppSession, previousWindowId: Int? = nil) { /* TODO(spine) */ }
    func cleanupAfterAction(_ session: AppSession?, _ previousFrontmost: AppInfo?) { /* TODO(spine) */ }
    func restorePreviousFrontmostApp(_ session: AppSession, _ previousFrontmost: AppInfo?) { /* TODO(spine) */ }

    // MARK: Session resolution

    func resolveSession(_ tool: String, _ params: [String: Any]) throws -> AppSession {
        fatalError("unimplemented: resolveSession")
    }
    func getOrCreateSession(_ app: String) throws -> AppSession {
        fatalError("unimplemented: getOrCreateSession")
    }
    func getOrCreateSessionForWindow(_ windowId: Int) throws -> AppSession {
        fatalError("unimplemented: getOrCreateSessionForWindow")
    }
    func ensureSessionObserverReady(_ session: AppSession) { /* TODO(spine) */ }
    func refreshWindow(_ session: AppSession) { /* TODO(spine) */ }

    // MARK: Dispatch

    /// Route a resolved tool to its handler (handlers live in the +Handlers file).
    func dispatch(_ tool: String, _ session: AppSession, _ params: [String: Any]) throws -> String {
        switch tool {
        case "get_app_state": return "App state retrieved."
        case "click": return try handleClick(session, params)
        case "type_text": return try handleTypeText(session, params)
        case "set_value": return try handleSetValue(session, params)
        case "press_key": return try handlePressKey(session, params)
        case "scroll": return try handleScroll(session, params)
        case "drag": return try handleDrag(session, params)
        case "perform_secondary_action": return try handleSecondaryAction(session, params)
        default: throw AutomationError.automation("Unknown tool: \(tool)")
        }
    }

    // MARK: Snapshot

    func takeSnapshot(_ session: AppSession, skipRefresh: Bool = false) -> ToolResponse {
        // TODO(spine): port take_snapshot() (session.py:2315).
        return errorOnly("unimplemented: takeSnapshot")
    }

    func buildAppState(_ target: AppTarget, windowTitle: String?) -> AppState {
        AppState(bundleId: target.bundleId, isActive: false, isRunning: true, windowTitle: windowTitle)
    }

    // MARK: list_apps + index resolution

    func handleListApps() -> ToolResponse {
        // TODO(spine): port _handle_list_apps() (session.py:3714).
        return errorOnly("unimplemented: handleListApps")
    }

    /// Resolve a model-facing element index to a live `Node` (used by handlers).
    func resolveIndex(_ session: AppSession, _ idx: Int) throws -> Node {
        fatalError("unimplemented: resolveIndex")
    }

    // MARK: Transient / user-invalidation

    func invalidateSessionForUserChange(_ session: AppSession, _ message: String) { /* TODO(spine) */ }
    func clearUserInvalidatedState(_ session: AppSession) { /* TODO(spine) */ }

    // MARK: Error helpers

    func errorOnly(_ message: String) -> ToolResponse {
        ToolResponse(app: "", pid: 0, snapshotId: 0, error: message)
    }

    func trySnapshotOrError(_ session: AppSession, _ error: Error) -> ToolResponse {
        errorOnly("\(error)")
    }

    func loadGuidance(_ bundleId: String) -> String? { nil }
}
