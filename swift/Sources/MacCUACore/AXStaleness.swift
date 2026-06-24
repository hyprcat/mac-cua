import Foundation

// Pure staleness classification for the act path (US-038 / Invariant 10).
//
// Per §5.3, the source of truth for "this cached element reference is dead" is a
// liveness probe + full re-walk + GraphLocator rebind — NOT an AXObserver flag.
// Before acting on a cached AX ref, the Kit layer copies one cheap attribute
// (AXRole). If that probe fails with any of the codes below, the ref is stale
// and the spine forces a re-walk + locator rebind (never reuses the same
// preorder index, never acts on the dead ref).
//
// This is intentionally BROADER than `axError`'s general stale mapping
// (-25205/-25212 only, which mirrors `app/_lib/errors.py` for ordinary AX
// reads/writes). The extra codes here — -25202 ("cannot complete", returned when
// the owning process can no longer service the element) and -25204 ("attribute
// unsupported", which a live element never returns for AXRole) — are reliable
// death signals *for a liveness probe specifically*, so widening them here does
// not change error semantics on the ordinary read/write paths.
public enum AXStaleness {
    /// AX status codes that mean "this cached reference is dead → re-walk +
    /// rebind via GraphLocator" when seen by a liveness probe.
    public static let staleActCodes: Set<Int> = [-25202, -25204, -25205, -25212]

    /// True when `code` (a raw `AXError` rawValue) indicates the probed element
    /// is stale and the caller must re-walk + rebind rather than act.
    public static func isStaleActCode(_ code: Int) -> Bool {
        staleActCodes.contains(code)
    }

    /// Classify the result of a liveness probe that copies AXRole.
    /// - Parameters:
    ///   - status: the raw `AXError` rawValue from the copy (0 == success).
    ///   - role: the role string read on success (nil/empty == not a live element).
    /// - Returns: true when the element is alive and safe to act on.
    public static func isAlive(status: Int, role: String?) -> Bool {
        guard status == 0 else { return false }
        guard let role, !role.isEmpty else { return false }
        return true
    }
}
