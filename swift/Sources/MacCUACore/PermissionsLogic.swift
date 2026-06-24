import Foundation

/// Pure, Linux-testable permission helpers.
///
/// The macOS framework calls (`AXIsProcessTrusted`,
/// `AXIsProcessTrustedWithOptions`, `CGPreflightScreenCaptureAccess`,
/// `CGRequestScreenCaptureAccess`) live in `MacCUAKit`; the only branchy
/// logic — the Screen-Recording window-name *fallback* used when
/// `CGPreflightScreenCaptureAccess` is unavailable — is extracted here so it
/// can be tested without a screen.
///
/// Ported from `screenshot.check_screen_recording_permission`'s fallback:
/// without Screen-Recording permission, `CGWindowListCopyWindowInfo` still
/// returns windows but their `kCGWindowName` values are stripped, so a single
/// window with a non-empty name proves access is granted.
public enum PermissionsLogic {
    /// Decide Screen-Recording grant from the window names visible to this
    /// process. `nil` models a nil window list (no access / query failed).
    /// Returns true iff at least one window carries a non-empty name.
    public static func screenRecordingGrantedFromWindowNames(_ names: [String?]?) -> Bool {
        guard let names else { return false }
        for case let name? in names where !name.isEmpty {
            return true
        }
        return false
    }
}
