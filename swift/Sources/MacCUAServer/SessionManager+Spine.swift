import Foundation
import MacCUACore

// ORCHESTRATION SPINE — faithful port of the integration spine in
// `app/session.py` (the `SessionManager` class). Every macOS effect routes
// through `providers.*` and the per-session monitors created via the provider
// factories; nothing here touches a framework directly, so the whole spine
// builds and unit-tests on Linux (SWIFT_PORT_DESIGN.md §4.2).
//
// Two deliberate divergences from Python, mandated by §5.3:
//   - Settle is by POLLING (`SettleMonitor`), not AX notifications. The Python
//     `AXNotificationObserver` / `TreeInvalidationMonitor` / `wait_for_settle`
//     correctness path is NOT ported; the settle monitor doubles as the
//     `InvalidationMonitor` for `RefetchableTree` via `SettleInvalidationAdapter`.
//   - Stale detection is liveness-check + re-walk + locator match inside
//     `RefetchableTree`, not the invalidation flag (supersedes Invariant 10's
//     notification implication).

// MARK: - Settle → InvalidationMonitor adapter

/// Bridges a `SettleMonitor` (polling) to the `InvalidationMonitor` seam that
/// `RefetchableTree` consumes. Both expose `isInvalidated`/`reset`, but they are
/// distinct protocols, so this thin wrapper lets the spine feed the session's
/// settle monitor into the refetchable tree without naming a concrete type.
final class SettleInvalidationAdapter: InvalidationMonitor {
    private let settle: SettleMonitor
    init(_ settle: SettleMonitor) { self.settle = settle }
    var isInvalidated: Bool { settle.isInvalidated }
    func reset() { settle.reset() }
}

extension SessionManager {

    // MARK: Public entry — the 12-step pipeline (session.py:614)

    /// Execute a tool call following the action pipeline. Ports `execute`
    /// (session.py:614). NEVER throws to the caller — every error becomes a
    /// snapshot+hint (the "Failproof" goal). Honors every `feature_flags` gate
    /// via `self.flags`, the get_app_state/list_apps special-casing, the
    /// transient-probe fast path, the polling settle step, the user-interruption
    /// check, snapshot capture, and previous-frontmost restore (Invariant 15).
    public func execute(_ tool: String, _ params: [String: Any]) -> ToolResponse {
        providers.analytics.mcpToolCalled(tool)

        if tool == "list_apps" {
            return handleListApps()
        }

        if tool == "batch" {
            return executeBatch(params)
        }

        if tool == "wait" {
            return executeWait(params)
        }

        var session: AppSession?
        var previousFrontmost: AppInfo?

        do {
            // Step 1: resolve target session.
            ensureTrackersStarted()
            let resolved = try resolveSession(tool, params)
            session = resolved
            let isStateOnly = (tool == "get_app_state" || tool == "list_apps")

            // Save the user's frontmost so we can restore it (Invariant 15).
            if !isStateOnly {
                previousFrontmost = providers.apps.getFrontmostApp()
            }

            // Steps 2-3: safety + approval + lifecycle.
            try checkSafety(resolved.target.bundleId)
            checkApproval(resolved.target.bundleId)
            lifecycle.trackAppUsed(resolved.target.bundleId)
            lifecycle.incrementStep()
            if lifecycle.checkStepLimit() {
                throw AutomationError.stepLimit(
                    "Step limit reached (\(workarounds.loopStepLimit)). "
                    + "End your current loop and summarize progress.")
            }

            // Step 6c: start user-interaction monitoring (listen-only tap).
            if flags.userInterruptionDetection && !isStateOnly {
                providers.userInteractionMonitor.startMonitoring(pid: resolved.target.pid)
            }

            // Steps 5-7: element resolution + execute action.
            let result = try dispatch(tool, resolved, params)

            // Transient-probe fast path: a menu/popover just opened — capture a
            // transient-only snapshot, skip the heavyweight persistent walk.
            let transientProbeActive =
                flags.transientGraphs
                && !isStateOnly
                && activeTransientSurface(resolved) != nil
            if transientProbeActive {
                let response = takeSnapshot(resolved, skipRefresh: true)
                if flags.userInterruptionDetection {
                    if let msg = providers.userInteractionMonitor.checkInterruption(
                        bundleId: resolved.target.bundleId) {
                        invalidateSessionForUserChange(resolved, msg)
                        providers.userInteractionMonitor.stopMonitoring()
                        throw AutomationError.userInterruption(msg)
                    }
                    providers.userInteractionMonitor.stopMonitoring()
                }
                var r = response
                r.result = result
                providers.analytics.serviceResult(tool, success: true, durationMs: 0.0)
                restorePreviousFrontmostApp(resolved, previousFrontmost)
                return r
            }

            // Step 8: settle (event-driven via polling — §5.3).
            var settleTimeout = settleTimeouts[tool] ?? 1.0
            let menuOpen = flags.menuTracking
                && (resolved.menuTracker?.menusOpen ?? false)
            let transientOpen = flags.transientGraphs
                && activeTransientSurface(resolved) != nil
            if (menuOpen || transientOpen) && !isStateOnly {
                // Short settle (not zero) so popovers don't persist as artifacts.
                settleTimeout = min(settleTimeout, 0.15)
            }
            if settleTimeout > 0, let settle = resolved.settleMonitor {
                _ = settle.waitForSettle(
                    context: tool, timeout: settleTimeout, quietPeriod: settleQuietPeriod)
            }

            // Step 9: user-interruption check.
            if flags.userInterruptionDetection {
                if let msg = providers.userInteractionMonitor.checkInterruption(
                    bundleId: resolved.target.bundleId) {
                    invalidateSessionForUserChange(resolved, msg)
                    providers.userInteractionMonitor.stopMonitoring()
                    throw AutomationError.userInterruption(msg)
                }
                providers.userInteractionMonitor.stopMonitoring()
            }

            // Step 10: capture snapshot (session already validated in resolve).
            var response = takeSnapshot(resolved, skipRefresh: true)
            response.result = result
            providers.analytics.serviceResult(tool, success: true, durationMs: 0.0)

            // get_app_state: clear yield state + deliver once-per-session guidance.
            if tool == "get_app_state" {
                clearUserInvalidatedState(resolved)
                if !resolved.guidanceDelivered {
                    var guidance = loadGuidance(resolved.target.bundleId)
                    let interactive = response.treeNodes.reduce(into: 0) { acc, n in
                        if pointerPreferredRoles.contains(n.role) { acc += 1 }
                    }
                    if interactive < SpineConst.axPoorThreshold {
                        guidance = guidance.map { "\($0)\n\n\(axPoorGuidance)" } ?? axPoorGuidance
                    }
                    response.guidance = guidance
                    resolved.guidanceDelivered = true
                }
            }

            // Step 11-12: restore frontmost + return.
            restorePreviousFrontmostApp(resolved, previousFrontmost)
            return response
        } catch let e as AutomationError where e.kind == .staleReference {
            cleanupAfterAction(session, previousFrontmost)
            if let session {
                var response = takeSnapshot(session)
                response.error = "Element reference became stale: \(e.message). Tree refreshed."
                return response
            }
            return errorOnly(e.message)
        } catch let e as AutomationError where e.kind == .userInterruption {
            cleanupAfterAction(session, previousFrontmost)
            if let session {
                return ToolResponse(
                    app: session.target.bundleId,
                    pid: session.target.pid,
                    snapshotId: session.snapshotId,
                    error: e.message)
            }
            return errorOnly(e.message)
        } catch let e as AutomationError {
            cleanupAfterAction(session, previousFrontmost)
            if let session {
                return trySnapshotOrError(session, e)
            }
            return errorOnly(e.message)
        } catch {
            // Failproof: any non-AutomationError still yields a useful response.
            cleanupAfterAction(session, previousFrontmost)
            if let session {
                return trySnapshotOrError(session, error)
            }
            return errorOnly("\(error)")
        }
    }

    // MARK: Pipeline gates

    /// Lazy global-tracker start. Ports `_ensure_trackers_started` (session.py:281).
    func ensureTrackersStarted() {
        if trackersStarted { return }
        if flags.focusEnforcement {
            providers.frontmostTracker.start()
        }
        // User-interaction monitor starts per-session via startMonitoring().
        trackersStarted = true
    }

    /// Ports `_check_safety` (session.py:293). Uses `self.safety.checkApp`.
    func checkSafety(_ bundleId: String) throws {
        if safety.checkApp(bundleId) != nil {
            throw AutomationError.appBlocked(
                "Automation is not allowed to use the app '\(bundleId)' for safety reasons.")
        }
    }

    /// Ports `_check_approval` (session.py:302). Auto-approves for the session.
    func checkApproval(_ bundleId: String) {
        if !approvalStore.isApproved(bundleId) {
            approvalStore.approveForSession(bundleId)
            providers.analytics.mcpAppApprovalResolved(bundleId, approved: true)
        }
    }

    // MARK: Session lifecycle

    /// Ports `_drop_session` (session.py:309). Tears down monitors + clears caches.
    func dropSession(windowId: Int) {
        guard let session = sessions.removeValue(forKey: windowId) else { return }
        teardownSessionMonitors(session)
        let bundleId = session.target.bundleId
        if bundleToWindow[bundleId] == windowId {
            bundleToWindow.removeValue(forKey: bundleId)
        }
    }

    /// Ports `_track_session` (session.py:572). Drops a displaced session,
    /// records the new one, and sets up its per-session monitors.
    func trackSession(_ session: AppSession, previousWindowId: Int? = nil) {
        if let prev = previousWindowId, prev != session.target.windowId {
            dropSession(windowId: prev)
        }
        if let displaced = sessions[session.target.windowId], displaced !== session {
            teardownSessionMonitors(displaced)
            let displacedBundle = displaced.target.bundleId
            if bundleToWindow[displacedBundle] == session.target.windowId {
                bundleToWindow.removeValue(forKey: displacedBundle)
            }
        }
        sessions[session.target.windowId] = session
        bundleToWindow[session.target.bundleId] = session.target.windowId
        setupSessionMonitors(session)
    }

    /// Ports `_cleanup_after_action` (session.py:554). Stops the interaction
    /// monitor and restores the user's previous frontmost (Invariant 15).
    func cleanupAfterAction(_ session: AppSession?, _ previousFrontmost: AppInfo?) {
        guard let session else { return }
        if flags.userInterruptionDetection {
            providers.userInteractionMonitor.stopMonitoring()
        }
        restorePreviousFrontmostApp(session, previousFrontmost)
    }

    /// Ports `_restore_previous_frontmost_app` (session.py:533). The ONLY allowed
    /// activation: restore the USER's previous frontmost — never the target
    /// (Invariant 15). Only restores if the target actually became frontmost.
    func restorePreviousFrontmostApp(_ session: AppSession, _ previousFrontmost: AppInfo?) {
        guard let previousFrontmost else { return }
        guard let previousPid = previousFrontmost.pid, previousPid != session.target.pid else {
            return
        }
        let current = providers.apps.getFrontmostApp()
        if current?.pid == session.target.pid {
            providers.apps.restoreFrontmostApp(previousFrontmost)
        }
    }

    /// Create the per-session polling monitors + delivery state. Replaces the
    /// AX-observer-based `_setup_observer` (session.py:321) with the polling model
    /// from §5.3: no AXObserver, no notification bridge.
    private func setupSessionMonitors(_ session: AppSession) {
        if session.settleMonitor == nil {
            session.settleMonitor = providers.makeSettleMonitor(session)
        }
        if flags.cgeventActionVerification && session.cgeventOutcomeMonitor == nil {
            session.cgeventOutcomeMonitor = providers.makeCGEventOutcomeMonitor(session)
        }
        if session.axOutcomeMonitor == nil {
            session.axOutcomeMonitor = providers.makeAXOutcomeMonitor(session)
        }
        if flags.menuTracking && session.menuTracker == nil {
            let tracker = providers.makeMenuTracker(session)
            tracker.start(pid: session.target.pid)
            session.menuTracker = tracker
        }
        if flags.systemSelection && session.selectionClient == nil {
            let client = providers.makeSelectionClient(session)
            client.startObserving(pid: session.target.pid)
            session.selectionClient = client
        }
        if session.inputStrategy == nil {
            session.appType = detectAppType(
                bundleId: session.target.bundleId, pid: session.target.pid)
            session.inputStrategy = InputStrategy(
                appType: session.appType, forceSimulate: flags.alwaysSimulateClick)
        }
        if flags.confirmedDelivery && session.eventSource == nil {
            session.eventSource = providers.input.createEventSource()
        }
    }

    /// Stop and clear a session's monitors. Replaces `_teardown_observer`
    /// (session.py:473).
    private func teardownSessionMonitors(_ session: AppSession) {
        session.settleMonitor?.cancel()
        session.settleMonitor = nil
        if let menu = session.menuTracker {
            menu.stop()
            session.menuTracker = nil
        }
        if let sel = session.selectionClient {
            sel.stopObserving()
            session.selectionClient = nil
        }
        session.axOutcomeMonitor = nil
        session.cgeventOutcomeMonitor = nil
        session.eventSource = nil
    }

    /// Ports `_ensure_session_observer_ready` (session.py:586). Re-binds the
    /// session + graph refetchable trees to the (possibly recreated) settle
    /// monitor so staleness detection stays consistent.
    func ensureSessionObserverReady(_ session: AppSession) {
        if !session.windowAvailable { return }
        if session.settleMonitor == nil {
            teardownSessionMonitors(session)
            setupSessionMonitors(session)
        }
        guard let settle = session.settleMonitor else { return }
        let adapter = SettleInvalidationAdapter(settle)
        session.refetchableTree?.update(
            session.refetchableTree?.nodes ?? [], monitor: adapter)
        var graphs: [GraphRecord] = []
        if let p = session.graphs.persistentGraph { graphs.append(p) }
        graphs.append(contentsOf: session.graphs.transientStack)
        for graph in graphs {
            if let tree = graph.refetchableTree as? RefetchableTree {
                tree.update(tree.nodes, monitor: adapter)
            }
        }
    }

    // MARK: Session resolution

    /// Ports `_resolve_session` (session.py:792). Requires window_id OR app
    /// (window_id preferred). Honors the user-yield gate (Invariant 16).
    func resolveSession(_ tool: String, _ params: [String: Any]) throws -> AppSession {
        let session: AppSession
        if let windowId = intArg(params, "window_id") {
            session = try getOrCreateSessionForWindow(windowId)
        } else if let app = stringArg(params, "app") {
            session = try getOrCreateSession(app)
        } else {
            throw AutomationError.automation(
                "\(tool) requires window_id or app. "
                + "Prefer window_id from the latest get_app_state.")
        }

        if tool != "get_app_state" && session.userStateInvalidated {
            throw AutomationError.userInterruption(
                session.userStateInvalidatedMessage
                ?? "The user changed the target app. Re-query the latest state with "
                + "`get_app_state` before sending more actions.")
        }

        ensureSessionObserverReady(session)
        return session
    }

    /// Ports `_app_hint_matches_bundle` (session.py:814).
    private func appHintMatchesBundle(_ appHint: String, _ bundleId: String) -> Bool {
        let hint = appHint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hint.isEmpty { return false }
        let normalized = bundleId.lowercased()
        if hint == normalized { return true }
        let last = normalized.components(separatedBy: ".").last ?? normalized
        return hint == last
    }

    /// Ports `_find_cached_session_for_app` (session.py:823).
    private func findCachedSessionForApp(_ appHint: String) -> AppSession? {
        for (bundleId, windowId) in bundleToWindow {
            if !appHintMatchesBundle(appHint, bundleId) { continue }
            if let session = sessions[windowId] { return session }
            bundleToWindow.removeValue(forKey: bundleId)
        }
        for session in sessions.values {
            if appHintMatchesBundle(appHint, session.target.bundleId) { return session }
        }
        return nil
    }

    /// Ports `_fallback_window_id_for_pid` (session.py:838). Picks the best
    /// window for a pid: titled, onscreen, largest area.
    private func fallbackWindowIdForPid(_ pid: Int) -> Int? {
        let candidates = providers.capture.listWindows(ownerPid: pid)
        if candidates.isEmpty { return nil }
        let best = candidates.max { a, b in
            let ka = (titleScore(a.title), a.onscreen, a.width * a.height)
            let kb = (titleScore(b.title), b.onscreen, b.width * b.height)
            if ka.0 != kb.0 { return ka.0 == false }
            if ka.1 != kb.1 { return ka.1 == false }
            return ka.2 < kb.2
        }
        return best?.windowId
    }

    private func titleScore(_ title: String?) -> Bool {
        guard let title else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ports `get_or_create_session` (session.py:852). Resolves a name/bundle to
    /// a concrete window-backed session, launching (non-activating) if needed.
    func getOrCreateSession(_ app: String) throws -> AppSession {
        if let cached = findCachedSessionForApp(app) {
            // Fast path: PID still alive → reuse, skip AX re-matching.
            if let windowPid = providers.capture.getWindowPid(windowId: cached.target.windowId) {
                cached.target.windowPid = windowPid
                trackSession(cached)
                return cached
            }
            refreshWindow(cached)
            if cached.windowAvailable {
                trackSession(cached)
                return cached
            }
            dropSession(windowId: cached.target.windowId)
        }

        let info = try providers.apps.resolveApp(app)
        let bundleId = info.bundleId

        let previousWindowId = bundleToWindow[bundleId]
        if let prev = previousWindowId {
            if let existing = sessions[prev] {
                if let infoPid = info.pid, existing.target.pid != infoPid {
                    dropSession(windowId: prev)
                } else if info.pid != nil {
                    do {
                        let (axApp, pid) = try providers.apps.getAXApp(
                            bundleId: bundleId, knownPid: info.pid)
                        existing.target.axApp = axApp
                        existing.target.pid = pid
                        refreshWindow(existing)
                        if existing.windowAvailable {
                            trackSession(existing, previousWindowId: prev)
                            return existing
                        }
                        dropSession(windowId: prev)
                    } catch {
                        dropSession(windowId: prev)
                    }
                } else {
                    dropSession(windowId: prev)
                }
            } else {
                bundleToWindow.removeValue(forKey: bundleId)
            }
        }

        // Save frontmost so we can restore if the target self-activates.
        let previousFrontmost = providers.apps.getFrontmostApp()

        let launchPid: Int
        if let pid = info.pid {
            launchPid = pid
        } else {
            launchPid = try providers.apps.launchApp(bundleId: bundleId)
        }

        let (axApp, pid) = try providers.apps.getAXApp(bundleId: bundleId, knownPid: launchPid)
        var axWindow = providers.accessibility.getKeyWindow(axApp: axApp)

        // Restore focus if the target stole it during launch/reopen.
        providers.apps.restoreFrontmostApp(previousFrontmost)

        var windowId = providers.capture.findWindowIdForAXWindow(pid: pid, axWindow: axWindow ?? axApp)
        if windowId == nil, let win = axWindow {
            windowId = providers.capture.findWindowIdForAXWindow(pid: pid, axWindow: win)
        }
        if windowId == nil {
            windowId = fallbackWindowIdForPid(pid)
        }
        guard let resolvedWindowId = windowId else {
            throw AutomationError.screenshot("Cannot resolve window ID for \(bundleId)")
        }
        if axWindow == nil {
            // No key window resolved but we found a window id — best effort: keep
            // the app element as the read root (Invariant 7, never raise).
            axWindow = providers.accessibility.getKeyWindow(axApp: axApp)
        }

        let windowPid = providers.capture.getWindowPid(windowId: resolvedWindowId) ?? pid

        if let existing = sessions[resolvedWindowId],
           existing.target.bundleId == bundleId, existing.target.pid == pid {
            existing.target.axApp = axApp
            if let win = axWindow { existing.target.axWindow = win }
            existing.target.windowPid = windowPid
            existing.windowAvailable = (axWindow != nil)
            trackSession(existing, previousWindowId: previousWindowId)
            return existing
        }

        let target = AppTarget(
            bundleId: bundleId, pid: pid, windowId: resolvedWindowId,
            windowPid: windowPid, axApp: axApp, axWindow: axWindow ?? axApp)
        let session = AppSession(target: target)
        session.windowAvailable = (axWindow != nil)
        trackSession(session, previousWindowId: previousWindowId)
        return session
    }

    /// Ports `get_or_create_session_for_window` (session.py:957). Resolves a
    /// concrete window id to its owning app + AX window.
    func getOrCreateSessionForWindow(_ windowId: Int) throws -> AppSession {
        guard let windowPid = providers.capture.getWindowPid(windowId: windowId) else {
            dropSession(windowId: windowId)
            throw AutomationError.automation(
                "Window \(windowId) is not available. "
                + "Call list_apps or get_app_state to refresh.")
        }

        if let existing = sessions[windowId] {
            existing.target.windowPid = windowPid
            return existing
        }

        let info = providers.apps.resolveRunningAppByPid(windowPid)
        let bundleId = info?.bundleId ?? "pid.\(windowPid)"
        var (axApp, pid) = try providers.apps.getAXAppForPid(windowPid, bundleId: info?.bundleId)
        var resolvedBundle = bundleId
        var axWindow = findAXWindowForWindowId(axApp: axApp, pid: pid, windowId: windowId)
        if axWindow == nil {
            guard let fallback = findWindowAcrossRunningApps(windowId, skipPids: [pid]) else {
                throw AutomationError.screenshot(
                    "Cannot resolve accessibility window for window_id=\(windowId) (pid \(windowPid))")
            }
            resolvedBundle = fallback.bundleId
            pid = fallback.pid
            axApp = fallback.axApp
            axWindow = fallback.axWindow
        }

        let target = AppTarget(
            bundleId: resolvedBundle, pid: pid, windowId: windowId,
            windowPid: windowPid, axApp: axApp, axWindow: axWindow ?? axApp)
        let session = AppSession(target: target)
        trackSession(session)
        return session
    }

    /// Ports `_find_ax_window_for_window_id` (session.py:995).
    private func findAXWindowForWindowId(
        axApp: AXElementRef, pid: Int, windowId: Int
    ) -> AXElementRef? {
        for axWindow in providers.accessibility.getWindows(axApp: axApp) {
            if providers.capture.findWindowIdForAXWindow(pid: pid, axWindow: axWindow) == windowId {
                return axWindow
            }
        }
        return nil
    }

    private struct ResolvedWindow {
        let bundleId: String
        let pid: Int
        let axApp: AXElementRef
        let axWindow: AXElementRef
    }

    /// Ports `_find_window_across_running_apps` (session.py:1002).
    private func findWindowAcrossRunningApps(
        _ windowId: Int, skipPids: Set<Int> = []
    ) -> ResolvedWindow? {
        for app in providers.apps.listRunningApps() {
            guard let appPid = app.pid, !skipPids.contains(appPid) else { continue }
            guard let (axApp, pid) =
                try? providers.apps.getAXAppForPid(appPid, bundleId: app.bundleId)
            else { continue }
            if let axWindow = findAXWindowForWindowId(axApp: axApp, pid: pid, windowId: windowId) {
                return ResolvedWindow(
                    bundleId: app.bundleId, pid: pid, axApp: axApp, axWindow: axWindow)
            }
        }
        return nil
    }

    /// Ports `_refresh_window` (session.py:1021). Re-validates the window's pid
    /// and re-binds the AX window, recovering across pid/app changes.
    func refreshWindow(_ session: AppSession) {
        let windowId = session.target.windowId
        guard let windowPid = providers.capture.getWindowPid(windowId: windowId) else {
            dropSession(windowId: windowId)
            session.windowAvailable = false
            session.target.axWindow = session.target.axApp  // best-effort root
            return
        }
        session.target.windowPid = windowPid

        if let axWindow = findAXWindowForWindowId(
            axApp: session.target.axApp, pid: session.target.pid, windowId: windowId) {
            session.target.axWindow = axWindow
            session.windowAvailable = true
            return
        }

        if windowPid != session.target.pid {
            let info = providers.apps.resolveRunningAppByPid(windowPid)
            if let (axApp, pid) =
                try? providers.apps.getAXAppForPid(windowPid, bundleId: info?.bundleId) {
                if let axWindow = findAXWindowForWindowId(axApp: axApp, pid: pid, windowId: windowId) {
                    session.target.axApp = axApp
                    session.target.axWindow = axWindow
                    session.target.pid = pid
                    if let bundleId = info?.bundleId { session.target.bundleId = bundleId }
                    session.windowAvailable = true
                    trackSession(session)
                    return
                }
            }
        }

        if let fallback = findWindowAcrossRunningApps(
            windowId, skipPids: [session.target.pid, windowPid]) {
            session.target.bundleId = fallback.bundleId
            session.target.pid = fallback.pid
            session.target.axApp = fallback.axApp
            session.target.axWindow = fallback.axWindow
            session.windowAvailable = true
            trackSession(session)
            return
        }

        session.windowAvailable = false
        session.target.axWindow = session.target.axApp
    }

    // MARK: Dispatch

    /// Route a resolved tool to its handler (handlers live in the +Handlers
    /// file). Ports `_dispatch` (session.py:2689).
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

    // MARK: Snapshot — ports take_snapshot (session.py:2315)

    /// Walk AX → prune → screenshot → serialize, with stable indices and
    /// graph/refetchable-tree wiring. Honors the transient-surface fast path and
    /// the stale-window retry. Indices are assigned only at the end of pruning
    /// (Invariant 22).
    func takeSnapshot(_ session: AppSession, skipRefresh: Bool = false) -> ToolResponse {
        let transientSurface = activeTransientSurface(session)

        if !skipRefresh && transientSurface == nil {
            refreshWindow(session)
        }
        var t = session.target

        if !session.windowAvailable && transientSurface == nil {
            refreshWindow(session)
            t = session.target
            if !session.windowAvailable {
                return errorOnly(
                    "Target window \(t.windowId) in \(t.bundleId) is no longer available.")
            }
        }

        if let surface = transientSurface {
            return takeTransientSnapshot(session, surface)
        }

        updateApplicationWindow(session)

        // Persistent graph only in the main snapshot path; transient surfaces go
        // through `takeTransientSnapshot` above (session.py:2339).
        let rootRef = t.axWindow

        // Step 2: walk AX tree (cache if not invalidated).
        var nodes: [Node]
        if let tree = session.refetchableTree, !tree.isInvalidated {
            nodes = tree.nodes
        } else {
            nodes = collectTreeNodes(rootRef, axApp: t.axApp, targetPid: t.pid, appType: session.appType)
        }

        // Step 3: capture screenshot (best-effort; nil → degrade gracefully).
        var img = captureScreenshot(session, t)
        if img == nil {
            refreshWindow(session)
            t = session.target
            if !session.windowAvailable {
                return errorOnly(
                    "Target window \(t.windowId) in \(t.bundleId) disappeared while capturing a snapshot.")
            }
            nodes = collectTreeNodes(
                t.axWindow, axApp: t.axApp, targetPid: t.pid, appType: session.appType)
            img = captureScreenshot(session, t)
        }

        // Step 4: focused element.
        var focused = normalizeFocusedIndex(
            nodes, providers.accessibility.getFocusedElement(axApp: t.axApp, tree: nodes))
        session.screenshotSize = img.map { (width: $0.width, height: $0.height) }

        // Step 5: geometry + web/selection enrichment.
        let windowTitle = getWindowTitle(t.axWindow)
        let appState = buildAppState(t, windowTitle: windowTitle)
        if flags.webContentExtraction {
            enrichNodesWithWebContent(nodes, targetPid: t.pid)
        }
        var selectionText: String?
        if flags.systemSelection, let f = focused {
            selectionText = extractSystemSelection(session, nodes, focusedIndex: f, targetPid: t.pid)
        }

        // Step 6: prune (re-indexes nodes in place — use the pruned list).
        nodes = pruneTreeNodes(
            nodes, bundleId: t.bundleId, appType: session.appType,
            axApp: t.axApp, targetPid: t.pid)
        focused = normalizeFocusedIndex(
            nodes, providers.accessibility.getFocusedElement(axApp: t.axApp, tree: nodes))
        annotateNodeGeometry(nodes, appState: appState, screenshotSize: session.screenshotSize)

        // Graph bookkeeping (transient_graphs gate).
        var activeGraph: GraphRecord?
        if flags.transientGraphs {
            if !session.graphs.transientStack.isEmpty {
                session.graphRegistry.markTransientsClosed(session.graphs)
            }
            let graph = session.graphRegistry.setPersistent(
                session.graphs, rootRef: rootRef, nodes: nodes, rootLocator: nil)
            annotateGraphNodes(nodes, graphId: graph.graphId, generation: graph.generation)
            graph.nodes = nodes
            graph.rootLocator = nodes.first?.graphLocator
            activeGraph = graph
        }

        // Step 6 serialize (pruning already applied → enable_pruning=false).
        let treeText = serialize(
            nodes, focusedIndex: focused, enablePruning: false, codexStyle: flags.codexTreeStyle)

        // Step 7: header.
        let header = makeHeader(
            app: t.bundleId, pid: t.pid, windowTitle: windowTitle,
            windowId: t.windowId, windowPid: t.windowPid,
            screenshotSize: session.screenshotSize, appState: appState,
            codexStyle: flags.codexTreeStyle)

        // Steps 8-9: snapshot id + store nodes for index resolution.
        session.snapshotId += 1
        session.treeNodes = nodes

        // Step 9b: wire RefetchableTree.
        wireRefetchableTree(session, nodes: nodes, rootRef: rootRef, activeGraph: activeGraph, t: t)

        return ToolResponse(
            app: t.bundleId,
            pid: t.pid,
            snapshotId: session.snapshotId,
            windowTitle: windowTitle,
            treeText: "\(header)\n\n\(treeText)",
            treeNodes: nodes,
            focusedElement: focused,
            screenshot: img?.pngBase64(),
            appState: appState,
            systemSelection: selectionText)
    }

    /// Re-walk closure shared by `take_snapshot` / `_take_transient_snapshot`
    /// (the `refetch_walk` lambda at session.py:2467).
    private func makeRefetchWalk(_ t: AppTarget, appType: AppType) -> WalkFn {
        { [self] axWindow, targetPid in
            walkInteractionTree(
                axWindow, axApp: t.axApp, targetPid: targetPid,
                bundleId: t.bundleId, appType: appType)
        }
    }

    private func wireRefetchableTree(
        _ session: AppSession, nodes: [Node], rootRef: AXElementRef,
        activeGraph: GraphRecord?, t: AppTarget
    ) {
        let walk = makeRefetchWalk(t, appType: session.appType)
        let monitor: InvalidationMonitor? = session.settleMonitor.map { SettleInvalidationAdapter($0) }

        if flags.transientGraphs, let graph = activeGraph {
            let stateGetter = graphStateGetter(session, graphId: graph.graphId)
            if let tree = graph.refetchableTree as? RefetchableTree {
                tree.update(
                    nodes, axWindow: rootRef, monitor: monitor, targetPid: t.pid,
                    walkFn: walk, graphId: graph.graphId, generation: graph.generation,
                    graphStateGetter: stateGetter, reopenFn: nil)
                session.refetchableTree = tree
            } else {
                let tree = RefetchableTree(
                    nodes: nodes, monitor: monitor, axWindow: rootRef, targetPid: t.pid,
                    walkFn: walk, graphId: graph.graphId, generation: graph.generation,
                    graphStateGetter: stateGetter, reopenFn: nil)
                graph.refetchableTree = tree
                session.refetchableTree = tree
            }
        } else if let tree = session.refetchableTree {
            tree.update(
                nodes, axWindow: t.axWindow, monitor: monitor, targetPid: t.pid, walkFn: walk)
        } else {
            session.refetchableTree = RefetchableTree(
                nodes: nodes, monitor: monitor, axWindow: t.axWindow,
                targetPid: t.pid, walkFn: walk)
        }
    }

    // MARK: Tree assembly helpers

    /// Ports `_collect_tree_nodes` (session.py:1748). Pure walk; focused
    /// collection-child expansion is approximated via the provider's walk (the
    /// macOS-only live-children read is not available on Linux).
    func collectTreeNodes(
        _ axWindow: AXElementRef, axApp: AXElementRef?, targetPid: Int?, appType: AppType?
    ) -> [Node] {
        let nodes = (try? providers.accessibility.walkTree(
            axElement: axWindow, targetPid: targetPid, maxDepth: defaultMaxDepth,
            maxNodes: defaultMaxNodes, includeActions: true, includeStates: true)) ?? []
        return expandFocusedCollectionChildren(nodes)
    }

    /// Ports `_expand_focused_collection_children` (session.py:1813). Re-indexes
    /// after any expansion. The live-children fetch is best-effort via
    /// `getChildren` (depth-stamped), preserving pre-order.
    private func expandFocusedCollectionChildren(_ nodes: [Node]) -> [Node] {
        if nodes.isEmpty { return nodes }
        var expanded: [Node] = []
        for (index, node) in nodes.enumerated() {
            expanded.append(node)
            if !node.states.contains("focused") { continue }
            let roleOk = node.role == "collection" || node.role == "list"
            let axRoleOk = node.axRole == "AXCollection" || node.axRole == "AXList"
                || node.axRole == "AXOpaqueProviderGroup"
            if !roleOk && !axRoleOk { continue }
            if nodeHasMeaningfulDirectChildren(nodes, index) { continue }
            let children = liveCollectionChildren(node)
            if children.isEmpty { continue }
            expanded.append(contentsOf: children)
        }
        for (newIndex, node) in expanded.enumerated() { node.index = newIndex }
        return expanded
    }

    private func nodeHasMeaningfulDirectChildren(_ nodes: [Node], _ index: Int) -> Bool {
        guard index >= 0 && index < nodes.count else { return false }
        let depth = nodes[index].depth
        var direct: [Node] = []
        var i = index + 1
        while i < nodes.count {
            let n = nodes[i]
            if n.depth <= depth { break }
            if n.depth == depth + 1 { direct.append(n) }
            i += 1
        }
        if direct.isEmpty { return false }
        return direct.contains { $0.axRole != "AXScrollBar" }
    }

    private func liveCollectionChildren(_ node: Node) -> [Node] {
        guard let ref = node.axRef else { return [] }
        let childRefs = providers.accessibility.getChildren(ref)
        var children: [Node] = []
        for childRef in childRefs.prefix(100) {
            if let child = try? providers.accessibility.nodeFromRef(
                childRef, depth: node.depth + 1, index: -1) {
                children.append(child)
            }
        }
        return children
    }

    /// Ports `_walk_interaction_tree` (session.py:1835): collect + prune.
    private func walkInteractionTree(
        _ axWindow: AXElementRef, axApp: AXElementRef?, targetPid: Int?,
        bundleId: String?, appType: AppType?
    ) -> [Node] {
        let nodes = collectTreeNodes(axWindow, axApp: axApp, targetPid: targetPid, appType: appType)
        return pruneTreeNodes(
            nodes, bundleId: bundleId, appType: appType, axApp: axApp, targetPid: targetPid)
    }

    /// Ports `_prune_tree_nodes` (session.py:1897). Uses Core `prune` /
    /// `pruneForCodexTree` behind the `tree_pruning` gate (Invariant 23).
    func pruneTreeNodes(
        _ nodes: [Node], bundleId: String?, appType: AppType?,
        axApp: AXElementRef?, targetPid: Int?
    ) -> [Node] {
        if !flags.treePruning || nodes.isEmpty { return nodes }

        if flags.codexTreeStyle {
            var working = nodes
            if let axApp, let menuBar = providers.accessibility.getMenuBar(axApp: axApp) {
                if let menuNodes = try? providers.accessibility.walkTree(
                    axElement: menuBar, targetPid: targetPid, maxDepth: defaultMaxDepth,
                    maxNodes: defaultMaxNodes, includeActions: true, includeStates: true),
                   !menuNodes.isEmpty {
                    var filtered: [Node] = []
                    for node in menuNodes {
                        if node.depth > 1 { continue }
                        if node.depth == 1 && (node.label ?? node.description) == "Apple" { continue }
                        node.depth += 1
                        filtered.append(node)
                    }
                    working = nodes + filtered
                }
            }
            return pruneForCodexTree(working, bundleId: bundleId)
        }

        return prune(nodes, advanced: flags.advancedPruning, bundleId: bundleId).nodes
    }

    /// Ports `_normalize_focused_index` (session.py:1858).
    private func normalizeFocusedIndex(_ nodes: [Node], _ focusedIndex: Int?) -> Int? {
        var index = focusedIndex
        if index == nil || !(index! >= 0 && index! < nodes.count) {
            index = focusedIndexFromStates(nodes)
            if index == nil { return nil }
        }
        guard var idx = index else { return nil }

        let node = nodes[idx]
        if node.axRole == "AXList" && node.subrole == "AXCollectionList" {
            idx = nodes.isEmpty ? idx : 0
        }
        if flags.codexTreeStyle {
            if let ancestor = preferredFocusAncestor(nodes, idx) { return ancestor }
        }
        return idx
    }

    private func focusedIndexFromStates(_ nodes: [Node]) -> Int? {
        for (position, node) in nodes.enumerated() {
            if node.states.contains(where: { $0.lowercased() == "focused" }) { return position }
        }
        return nil
    }

    private func preferredFocusAncestor(_ nodes: [Node], _ focusedIndex: Int) -> Int? {
        guard focusedIndex >= 0 && focusedIndex < nodes.count else { return nil }
        let focusedNode = nodes[focusedIndex]
        if focusedNode.role != "text area" && focusedNode.role != "text field" { return nil }
        var targetDepth = focusedNode.depth
        var position = focusedIndex - 1
        while position >= 0 {
            let candidate = nodes[position]
            if candidate.depth >= targetDepth { position -= 1; continue }
            if webContainerRoles.contains(candidate.role) { return position }
            targetDepth = candidate.depth
            position -= 1
        }
        return nil
    }

    // MARK: AppState / geometry — ports _build_app_state (session.py:1606)

    /// Build geometry metadata. The macOS NSScreen/Quartz reads (scaling factor,
    /// scaled screen size, cursor position) are not available behind the current
    /// provider seams, so they fall back to the Python defaults (scalingFactor
    /// 2.0); `visibleRect` comes from the capture provider.
    func buildAppState(_ target: AppTarget, windowTitle: String?) -> AppState {
        let visibleRect = providers.capture.getWindowBounds(windowId: target.windowId)
        return AppState(
            bundleId: target.bundleId,
            isActive: true,
            isRunning: true,
            windowTitle: windowTitle,
            visibleRect: visibleRect,
            scalingFactor: 2.0,
            scaledScreenSize: nil,
            cursorPosition: nil)
    }

    /// Ports `_should_annotate_geometry` (session.py:1673).
    private func shouldAnnotateGeometry(_ node: Node) -> Bool {
        if geometryHintRoles.contains(node.role) { return true }
        if textGroundingRoles.contains(node.role) && node.label != nil { return true }
        if !node.secondaryActions.isEmpty { return true }
        return node.states.contains("settable")
    }

    /// Ports `_screen_frame_to_screenshot_frame` (session.py:1682).
    private func screenFrameToScreenshotFrame(
        _ frame: Rect, _ visibleRect: Rect, _ screenshotSize: (width: Int, height: Int)
    ) -> Rect? {
        if frame.w <= 0 || frame.h <= 0 || visibleRect.w <= 0 || visibleRect.h <= 0 { return nil }
        let ix = max(frame.x, visibleRect.x)
        let iy = max(frame.y, visibleRect.y)
        let iw = min(frame.x + frame.w, visibleRect.x + visibleRect.w) - ix
        let ih = min(frame.y + frame.h, visibleRect.y + visibleRect.h) - iy
        if iw <= 0 || ih <= 0 { return nil }
        let scaleX = Double(screenshotSize.width) / visibleRect.w
        let scaleY = Double(screenshotSize.height) / visibleRect.h
        return Rect(
            x: (ix - visibleRect.x) * scaleX, y: (iy - visibleRect.y) * scaleY,
            w: iw * scaleX, h: ih * scaleY)
    }

    /// Ports `_annotate_node_geometry` (session.py:1709). Caps hints at
    /// GEOMETRY_HINT_LIMIT (Invariant 23).
    private func annotateNodeGeometry(
        _ nodes: [Node], appState: AppState?, screenshotSize: (width: Int, height: Int)?
    ) {
        for node in nodes { node.position = nil; node.size = nil }
        guard let appState, let visibleRect = appState.visibleRect, let screenshotSize else { return }

        var annotated = 0
        for node in nodes {
            if annotated >= SpineConst.geometryHintLimit { break }
            if !shouldAnnotateGeometry(node) { continue }
            guard let frame = providers.accessibility.getElementFrame(node: node) else { continue }
            guard let shot = screenFrameToScreenshotFrame(frame, visibleRect, screenshotSize)
            else { continue }
            node.position = Point(x: shot.x, y: shot.y)
            node.size = Size(w: shot.w, h: shot.h)
            annotated += 1
        }
    }

    // MARK: Web content + selection extraction

    /// Ports `_enrich_nodes_with_web_content` (session.py:2544).
    private func enrichNodesWithWebContent(_ nodes: [Node], targetPid: Int) {
        for node in nodes {
            guard let ref = node.axRef else { continue }
            if node.isWebArea {
                if let content = providers.accessibility.extractWebAreaText(ref, targetPid: targetPid) {
                    node.webContent = content
                }
                if let url = providers.accessibility.getWebURL(ref) {
                    node.webAreaUrl = url
                }
            } else if node.axRole == "AXTextArea" && flags.richTextMarkdown {
                if let content = providers.accessibility.extractTextAreaContent(ref, targetPid: targetPid),
                   content != node.value {
                    node.webContent = content
                }
            }
        }
    }

    /// Ports `_extract_system_selection` (session.py:2571). Selection is read
    /// from the session's selection client (the macOS `SelectionExtractor`'s
    /// 4-method priority order lives behind the `SelectionProvider` seam).
    private func extractSystemSelection(
        _ session: AppSession, _ nodes: [Node], focusedIndex: Int, targetPid: Int
    ) -> String? {
        guard focusedIndex >= 0 && focusedIndex < nodes.count else { return nil }
        guard nodes[focusedIndex].axRef != nil else { return nil }
        return session.selectionClient?.currentSelection()
    }

    // MARK: Screenshot — ports _capture_screenshot (session.py:2596)

    /// Capture the target window's backing store by id (Invariant 13). Returns
    /// nil on permission/invalid-window failure (caller degrades gracefully).
    private func captureScreenshot(_ session: AppSession, _ target: AppTarget) -> CapturedImage? {
        (try? providers.capture.captureWindow(windowId: target.windowId, includeCursor: false)) ?? nil
    }

    /// Ports `_update_application_window` (session.py:2661). No-op in the Server
    /// layer: the ApplicationWindow CG+AX bridge is a Kit concern; session
    /// resolution already validated the window id.
    private func updateApplicationWindow(_ session: AppSession) {}

    /// Ports `_get_window_title` (session.py:2682).
    func getWindowTitle(_ axWindow: AXElementRef?) -> String? {
        guard let axWindow else { return nil }
        return providers.accessibility.getWindowTitle(axWindow: axWindow)
    }

    // MARK: Graph / transient helpers

    /// Ports `_active_graph` (session.py:1939).
    func activeGraph(_ session: AppSession) -> GraphRecord? {
        session.graphRegistry.activeGraph(session.graphs)
    }

    /// Ports `_active_transient_surface` (session.py:1942). With no AX-notification
    /// menu tracker, a transient surface is detected via the menu tracker's open
    /// state mapped to the active transient graph's root.
    func activeTransientSurface(_ session: AppSession) -> TransientSurface? {
        guard flags.transientGraphs else { return nil }
        guard let menu = session.menuTracker, menu.menusOpen else { return nil }
        guard let graph = activeGraph(session), graph.kind == .transient,
              let rootRef = graph.rootRef else { return nil }
        return TransientSurface(rootRef: rootRef, kind: graph.transientKind)
    }

    /// Ports `_graph_state_getter` (session.py:1947).
    func graphStateGetter(_ session: AppSession, graphId: String) -> GraphStateGetter {
        { [weak session] in
            guard let session else { return .closed }
            guard let graph = session.graphRegistry.find(session.graphs, graphId: graphId) else {
                return .closed
            }
            if let settle = session.settleMonitor, settle.isInvalidated {
                graph.state = .invalidated
                return graph.state
            }
            return graph.state
        }
    }

    /// Ports `_resolve_locator_in_graph` (session.py:1963).
    func resolveLocatorInGraph(
        _ session: AppSession, _ locator: GraphLocator?, kind: GraphKind = .persistent
    ) -> Node? {
        guard let locator else { return nil }
        let graph: GraphRecord?
        if kind == .persistent { graph = session.graphs.persistentGraph }
        else { graph = activeGraph(session) }
        guard let graph else { return nil }
        return matchNodeByLocator(graph.nodes, locator: locator)
    }

    /// Ports `_take_transient_snapshot` (session.py:2202). Fast path for
    /// menus/popovers: walk only the transient root, keep the persistent graph
    /// cached, skip screenshot/geometry/enrichment.
    private func takeTransientSnapshot(
        _ session: AppSession, _ surface: TransientSurface
    ) -> ToolResponse {
        let t = session.target
        let rootRef = surface.rootRef
        var nodes = collectTreeNodes(rootRef, axApp: t.axApp, targetPid: t.pid, appType: session.appType)
        nodes = pruneTreeNodes(
            nodes, bundleId: t.bundleId, appType: session.appType, axApp: nil, targetPid: t.pid)

        let graph = session.graphRegistry.pushTransient(
            session.graphs, rootRef: rootRef, nodes: nodes, rootLocator: nil,
            source: session.pendingTransientSource, transientKind: surface.kind)
        session.pendingTransientSource = nil
        annotateGraphNodes(nodes, graphId: graph.graphId, generation: graph.generation)
        graph.nodes = nodes
        graph.rootLocator = nodes.first?.graphLocator

        let treeText = serialize(
            nodes, focusedIndex: nil, enablePruning: false, codexStyle: flags.codexTreeStyle)
        let windowTitle = getWindowTitle(t.axWindow)
        let header = makeHeader(
            app: t.bundleId, pid: t.pid, windowTitle: windowTitle,
            windowId: t.windowId, windowPid: t.windowPid, screenshotSize: nil,
            appState: nil, codexStyle: flags.codexTreeStyle)

        session.snapshotId += 1
        session.treeNodes = nodes
        session.screenshotSize = nil

        let walk = makeRefetchWalk(t, appType: session.appType)
        let monitor: InvalidationMonitor? = session.settleMonitor.map { SettleInvalidationAdapter($0) }
        let stateGetter = graphStateGetter(session, graphId: graph.graphId)
        let reopen: ReopenFn = { [weak self, weak session] in
            guard let self, let session else { return nil }
            return self.reopenActiveTransientGraph(session)
        }
        if let tree = graph.refetchableTree as? RefetchableTree {
            tree.update(
                nodes, axWindow: rootRef, monitor: monitor, graphId: graph.graphId,
                generation: graph.generation, graphStateGetter: stateGetter, reopenFn: reopen)
        } else {
            graph.refetchableTree = RefetchableTree(
                nodes: nodes, monitor: monitor, axWindow: rootRef, targetPid: t.pid,
                walkFn: walk, graphId: graph.graphId, generation: graph.generation,
                graphStateGetter: stateGetter, reopenFn: reopen)
        }
        session.refetchableTree = graph.refetchableTree as? RefetchableTree

        dismissTransientSurface(session, graph)

        return ToolResponse(
            app: t.bundleId, pid: t.pid, snapshotId: session.snapshotId,
            windowTitle: windowTitle, treeText: "\(header)\n\n\(treeText)",
            treeNodes: nodes, focusedElement: nil, screenshot: nil,
            appState: nil, systemSelection: nil)
    }

    /// Ports `_reopen_active_transient_graph` (session.py:1980).
    func reopenActiveTransientGraph(_ session: AppSession) -> [Node]? {
        guard let graph = activeGraph(session), graph.kind == .transient else { return nil }
        guard let source = graph.source, let reopen = source.reopen else { return nil }
        graph.state = .reopening
        if !reopen() {
            graph.state = .closed
            return nil
        }
        return takeSnapshot(session, skipRefresh: true).treeNodes
    }

    /// Ports `_dismiss_transient_surface` (session.py:2007). Best-effort AX
    /// dismiss; never raises the window (Invariant 7/15).
    private func dismissTransientSurface(_ session: AppSession, _ graph: GraphRecord) {
        guard graph.kind == .transient, let rootRef = graph.rootRef else {
            graph.state = .closed
            return
        }
        let actions = Set(providers.accessibility.getActionNamesForRef(rootRef))
        for action in ["AXCancel", "AXPress"] where actions.contains(action) {
            try? providers.accessibility.performActionOnRef(rootRef, action: action)
        }
        graph.state = .closed
    }

    /// Ports `_make_transient_source` (session.py:2040).
    func makeTransientSource(
        _ session: AppSession, _ node: Node, actionName: String,
        reopenFn: @escaping (Node) -> Bool, graphKind: GraphKind = .persistent
    ) -> TransientSource {
        let locator = node.graphLocator
        let reopen: () -> Bool = { [weak self, weak session] in
            guard let self, let session else { return false }
            guard let resolved = self.resolveLocatorInGraph(session, locator, kind: graphKind) else {
                return false
            }
            return reopenFn(resolved)
        }
        return TransientSource(
            actionName: actionName, nodeLocator: locator, graphKind: graphKind,
            description: node.label ?? node.description ?? node.role, reopen: reopen)
    }

    // MARK: User-invalidation (Invariant 16)

    /// Ports `_invalidate_session_for_user_change` (session.py:1994).
    func invalidateSessionForUserChange(_ session: AppSession, _ message: String) {
        session.userStateInvalidated = true
        session.userStateInvalidatedMessage = message
        session.graphs.persistentGraph?.state = .invalidated
        for graph in session.graphs.transientStack { graph.state = .closed }
        session.pendingTransientSource = nil
    }

    /// Ports `_clear_user_invalidated_state` (session.py:2003).
    func clearUserInvalidatedState(_ session: AppSession) {
        session.userStateInvalidated = false
        session.userStateInvalidatedMessage = nil
    }

    // MARK: list_apps + index resolution

    /// Ports `_handle_list_apps` (session.py:3714).
    func handleListApps() -> ToolResponse {
        let running = providers.apps.listRunningApps()
        let recent = providers.apps.listRecentApps()
        let windows = providers.capture.listWindows(ownerPid: nil)
        var windowsByPid: [Int: [WindowInfo]] = [:]
        for window in windows { windowsByPid[window.ownerPid, default: []].append(window) }

        var lines: [String] = []
        var seenPids: Set<Int> = []

        for a in running {
            var parts = ["\(a.name) \u{2014} \(a.bundleId) [running"]
            if let pid = a.pid { parts.append(", pid=\(pid)") }
            if let last = a.lastUsed { parts.append(", last-used=\(last)") }
            if let count = a.useCount, count != 0 { parts.append(", uses=\(count)") }
            parts.append("]")
            lines.append(parts.joined())
            if let pid = a.pid {
                seenPids.insert(pid)
                for window in (windowsByPid[pid] ?? []).sorted(by: { $0.windowId < $1.windowId }) {
                    lines.append(windowLine(window))
                }
            }
        }

        for pid in windowsByPid.keys.sorted() {
            if seenPids.contains(pid) { continue }
            let owned = windowsByPid[pid] ?? []
            if let info = providers.apps.resolveRunningAppByPid(pid) {
                lines.append("\(info.name) \u{2014} \(info.bundleId) [running, pid=\(pid)]")
            } else {
                let ownerName = owned.first?.ownerName ?? "Unknown"
                lines.append("\(ownerName) \u{2014} pid.\(pid) [running, pid=\(pid)]")
            }
            for window in owned.sorted(by: { $0.windowId < $1.windowId }) {
                lines.append(windowLine(window))
            }
        }

        for a in recent {
            if running.contains(where: { $0.bundleId == a.bundleId }) { continue }
            var parts = ["\(a.name) \u{2014} \(a.bundleId) ["]
            if let last = a.lastUsed { parts.append("last-used=\(last)") }
            if let count = a.useCount, count != 0 { parts.append(", uses=\(count)") }
            parts.append("]")
            lines.append(parts.joined())
        }

        return ToolResponse(app: "system", pid: 0, snapshotId: 0, result: lines.joined(separator: "\n"))
    }

    private func windowLine(_ window: WindowInfo) -> String {
        let title = window.title.map { "'\($0)'" } ?? "\"(untitled)\""
        return "  window_id=\(window.windowId), window_pid=\(window.ownerPid), "
            + "title=\(title), bounds=(\(Int(window.x)), \(Int(window.y)), "
            + "\(Int(window.width))x\(Int(window.height)))"
    }

    /// Resolve a model-facing element index to a live `Node`. Ports
    /// `_resolve_index` (session.py:3673): RefetchableTree recovery first, then a
    /// bounded direct lookup.
    func resolveIndex(_ session: AppSession, _ idx: Int) throws -> Node {
        if flags.transientGraphs {
            if let graph = activeGraph(session), graph.kind == .transient {
                // Without a live root liveness check, leave the graph state to the
                // settle monitor; mark closed only if explicitly invalidated.
                if let settle = session.settleMonitor, settle.isInvalidated {
                    graph.state = .invalidated
                }
            }
        }

        if let tree = session.refetchableTree {
            let result = tree.element(idx)
            if result.success, let node = result.node { return node }
            switch result.errorCode {
            case .notFound:
                throw AutomationError.staleReference(
                    result.errorMessage
                    ?? "Element \(idx) no longer valid after refetch. Call get_app_state to refresh.")
            case .ambiguousBefore, .ambiguousAfter:
                throw AutomationError.refetch(
                    result.errorMessage
                    ?? "Element \(idx) is ambiguous. Call get_app_state to refresh.")
            case .noInvalidationMonitor, .none:
                break  // fall through to direct lookup
            }
        }

        if idx < 0 || idx >= session.treeNodes.count {
            throw AutomationError.badIndex(
                "Index \(idx) out of bounds (tree has \(session.treeNodes.count) elements). "
                + "Call get_app_state to refresh.")
        }
        return session.treeNodes[idx]
    }

    // MARK: Error helpers

    /// Ports `_error_only` (session.py:3789).
    func errorOnly(_ message: String) -> ToolResponse {
        ToolResponse(app: "unknown", pid: 0, snapshotId: 0, error: message)
    }

    /// Ports `_try_snapshot_or_error` (session.py:3797). Failproof: a snapshot
    /// with the error attached, or a bare error if even the snapshot fails.
    func trySnapshotOrError(_ session: AppSession, _ error: Error) -> ToolResponse {
        var response = takeSnapshot(session)
        let message = (error as? AutomationError)?.message ?? "\(error)"
        response.error = message
        return response
    }

    /// Ports `_load_guidance` (session.py:3779). The Server layer has no bundled
    /// guidance directory; returns the per-process cache (empty by default).
    func loadGuidance(_ bundleId: String) -> String? {
        if let cached = guidanceCache[bundleId] { return cached }
        guidanceCache[bundleId] = nil
        return nil
    }
}

// MARK: - Parameter parsing (params is [String: Any], JSON-variant tolerant)

/// Coerce a JSON-variant value (Int/String/Double/NSNumber) to Int.
func intArg(_ params: [String: Any], _ key: String) -> Int? {
    guard let raw = params[key] else { return nil }
    return anyToInt(raw)
}

func anyToInt(_ raw: Any) -> Int? {
    switch raw {
    case let i as Int: return i
    case let d as Double: return Int(d)
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s) ?? Double(s).map { Int($0) }
    default: return nil
    }
}

/// Coerce a JSON-variant value to String.
func stringArg(_ params: [String: Any], _ key: String) -> String? {
    guard let raw = params[key] else { return nil }
    if let s = raw as? String { return s }
    return nil
}

// MARK: - TransientSurface (server-local view of an open transient root)

/// Minimal stand-in for the macOS `TransientSurface` (graphs.py): the AX root of
/// an open menu/popover/sheet plus its kind. The Kit layer will own real surface
/// detection; here it is derived from the menu tracker + active transient graph.
public struct TransientSurface {
    public var rootRef: AXElementRef
    public var kind: String?
    public init(rootRef: AXElementRef, kind: String? = nil) {
        self.rootRef = rootRef
        self.kind = kind
    }
}
