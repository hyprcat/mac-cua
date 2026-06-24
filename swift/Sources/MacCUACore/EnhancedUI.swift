// EnhancedUI.swift — Chromium/Electron AX-tree enablement (A1), pure tier.
//
// Modern Chromium/Electron apps ship an empty AX tree until the host sets
// `AXEnhancedUserInterface` + `AXManualAccessibility` = true on the AXApplication
// element. After setting them the tree is populated lazily, so the FIRST walk is
// expected empty and the read path must re-walk a few times (a few hundred ms)
// until it is non-empty or settles.
//
// This file holds the Linux-pure decision logic: which app types warrant it
// (`EnhancedUIPolicy`), the re-walk poll loop's stop condition
// (`EnhancedUIRewalkPolicy`), and the per-app remembered/reversible state
// (`EnhancedUITracker`). The macOS attribute writes live in MacCUAKit behind the
// `AccessibilityProvider.enableEnhancedUI` seam. There is no Python reference —
// this is a Codex-parity feature (docs/CODEX_PARITY_CHANGES.md §A1).

// MARK: - Which app types warrant enhanced UI

public enum EnhancedUIPolicy {
    /// Enhanced UI is only needed for Chromium-backed surfaces: Electron apps and
    /// browsers. Native Cocoa / Java / Qt expose their tree without it, so we do
    /// not perturb them (enhanced-UI can change layout/perf).
    public static func shouldEnable(for appType: AppType) -> Bool {
        switch appType {
        case .electron, .browser:
            return true
        case .nativeCocoa, .java, .qt, .unknown:
            return false
        }
    }
}

// MARK: - Re-walk poll stop condition

/// Pure stop condition for the post-enable re-walk loop. The macOS layer drives
/// the actual timed poll (it owns the clock/sleep); this only decides whether to
/// keep going. The first walk after enabling is expected empty, so an empty tree
/// is NOT a terminal failure until the attempts are exhausted.
public struct EnhancedUIRewalkPolicy: Sendable {
    public let maxAttempts: Int
    public let pollIntervalMs: Int

    public init(maxAttempts: Int = 5, pollIntervalMs: Int = 80) {
        self.maxAttempts = max(1, maxAttempts)
        self.pollIntervalMs = max(0, pollIntervalMs)
    }

    /// Whether to perform another walk. `attempt` is the number of walks already
    /// performed (0 before the first). Stop once we have a non-empty tree or we
    /// have used up every attempt.
    public func shouldContinue(attempt: Int, nodeCount: Int) -> Bool {
        if nodeCount > 0 { return false }
        return attempt < maxAttempts
    }

    /// Total worst-case wait budget for the poll loop, in milliseconds.
    public var totalBudgetMs: Int { maxAttempts * pollIntervalMs }
}

// MARK: - Per-app remembered / reversible state

/// Tracks which processes have had enhanced UI enabled so we set it at most once
/// per app (remembered) and can restore the prior attribute values (reversible).
/// Reference type: the live enablement state IS shared session-wide. Pure —
/// holds only the captured booleans, no AX refs, so it is Linux-testable.
public final class EnhancedUITracker {
    /// The attribute values that were present before we enabled, so a teardown can
    /// restore them. `nil` means the attribute was absent/unreadable.
    public struct PriorState: Equatable, Sendable {
        public var enhancedUI: Bool?
        public var manualAccessibility: Bool?
        public init(enhancedUI: Bool? = nil, manualAccessibility: Bool? = nil) {
            self.enhancedUI = enhancedUI
            self.manualAccessibility = manualAccessibility
        }
    }

    private var enabled: [Int: PriorState] = [:]

    public init() {}

    /// True once `markEnabled` has run for this pid — the caller skips the write.
    public func isEnabled(pid: Int) -> Bool { enabled[pid] != nil }

    /// Record that enhanced UI was enabled for `pid`, capturing the prior values.
    public func markEnabled(pid: Int, prior: PriorState) {
        enabled[pid] = prior
    }

    /// The captured prior state for a pid (for reversible teardown), or nil.
    public func priorState(pid: Int) -> PriorState? { enabled[pid] }

    /// Forget a pid (process gone / explicitly disabled). Returns the prior state
    /// so the caller can restore it if the app is still alive.
    @discardableResult
    public func markDisabled(pid: Int) -> PriorState? {
        enabled.removeValue(forKey: pid)
    }

    public func reset() { enabled.removeAll() }
}
