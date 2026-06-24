import Foundation

// Port of the module-level cache logic in app/_lib/apps.py (`_pid_cache`,
// `_ax_app_cache`, `invalidate_caches_for_pid`) into an explicit, request/turn
// scoped (L1) cache.
//
// Python keeps two process-global dicts: bundle_id -> pid and pid -> ax_app,
// validated for liveness before reuse. Here we make the lifetime explicit (one
// instance per request/turn/batch) so a batch or a sequence of repeated lookups
// reuses the resolved pid, the per-pid AppState, AND the pre-action tree instead
// of re-walking. The AX application element itself lives in the Kit layer (it is
// a macOS handle), so this Core cache stores only pure, Sendable values.
//
// This is DISTINCT from the SCContentFilter capture cache (Phase 3, US-024),
// which is keyed by window/display and invalidated on display-config changes.
// This one is keyed by app identity and torn down at turn end.
//
// All reuse goes through an injected liveness predicate so the "validate the PID
// is still alive before reusing" rule from apps.py is preserved without any
// macOS dependency in Core.

/// A request/turn-scoped cache for app resolution and the pre-action tree.
///
/// Lifetime is one MCP request / batch / turn. Create one at the start of a
/// turn, thread it through the lookups in that turn, and discard it (or call
/// `clear()`) at the end. It is a reference type because reuse within a turn is
/// the whole point — multiple lookups share one instance.
public final class TurnCache {
    /// name (bundle id / app name) -> resolved pid.
    private var pidByName: [String: Int] = [:]
    /// pid -> last-resolved AppState for this turn.
    private var appStateByPid: [Int: AppState] = [:]
    /// pid -> pre-action flat node tree captured this turn (batch reuse).
    private var treeByPid: [Int: [Node]] = [:]

    /// Liveness predicate, injected so Core stays pure. Returns true if the pid
    /// still names a live process. A cached entry whose pid is not alive is
    /// invalidated on access (mirrors `_is_pid_alive` gating in apps.py).
    private let isPidAlive: (Int) -> Bool

    /// - Parameter isPidAlive: liveness check for a pid. Defaults to
    ///   always-alive, which is appropriate for tests and for callers that do
    ///   their own liveness checking; production wires the real check from Kit.
    public init(isPidAlive: @escaping (Int) -> Bool = { _ in true }) {
        self.isPidAlive = isPidAlive
    }

    // MARK: - name -> pid

    /// Cache a resolved name -> pid binding.
    public func setPid(forName name: String, pid: Int) {
        pidByName[name] = pid
    }

    /// Return the cached pid for a name, or nil on miss. A cached pid whose
    /// process is no longer alive is treated as a miss and evicted (along with
    /// everything keyed on that pid), matching apps.py's validate-before-reuse.
    public func pid(forName name: String) -> Int? {
        guard let pid = pidByName[name] else { return nil }
        guard isPidAlive(pid) else {
            invalidate(pid: pid)
            return nil
        }
        return pid
    }

    // MARK: - pid -> AppState

    /// Cache the AppState resolved for a pid this turn.
    public func setAppState(_ state: AppState, forPid pid: Int) {
        appStateByPid[pid] = state
    }

    /// Return the cached AppState for a pid, or nil on miss / dead pid.
    public func appState(forPid pid: Int) -> AppState? {
        guard let state = appStateByPid[pid] else { return nil }
        guard isPidAlive(pid) else {
            invalidate(pid: pid)
            return nil
        }
        return state
    }

    // MARK: - pid -> pre-action tree (batch reuse)

    /// Cache the pre-action flat node tree for a pid so a batch can reuse it
    /// instead of re-walking before each step.
    public func setTree(_ tree: [Node], forPid pid: Int) {
        treeByPid[pid] = tree
    }

    /// Return the cached pre-action tree for a pid, or nil on miss / dead pid.
    public func tree(forPid pid: Int) -> [Node]? {
        guard let tree = treeByPid[pid] else { return nil }
        guard isPidAlive(pid) else {
            invalidate(pid: pid)
            return nil
        }
        return tree
    }

    // MARK: - Invalidation

    /// Drop everything cached for a pid: its AppState, its tree, and every name
    /// that resolved to it. Mirrors `invalidate_caches_for_pid` in apps.py.
    /// Call after an action that mutates the tree (so the next read re-walks).
    public func invalidate(pid: Int) {
        appStateByPid[pid] = nil
        treeByPid[pid] = nil
        for (name, p) in pidByName where p == pid {
            pidByName[name] = nil
        }
    }

    /// Drop only the cached pre-action tree for a pid, keeping the resolved pid
    /// and AppState. Use this after an action so the next read re-walks the tree
    /// but does not re-resolve the app.
    public func invalidateTree(pid: Int) {
        treeByPid[pid] = nil
    }

    /// Tear down the whole turn cache.
    public func clear() {
        pidByName.removeAll()
        appStateByPid.removeAll()
        treeByPid.removeAll()
    }
}
