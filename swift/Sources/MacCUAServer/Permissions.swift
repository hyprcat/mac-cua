import Foundation
import MacCUACore

// Port of the permission-retry gate from `main.py`
// (`check_permissions_with_retry_guidance` + `PERMISSIONS_PENDING_MESSAGE`).
//
// Behavior carried over verbatim:
//   - First call PROMPTS for both Accessibility and Screen Recording (the system
//     dialogs are non-blocking).
//   - Subsequent calls just CHECK, without re-prompting.
//   - Returns the pending message until BOTH are granted, then nil.
//
// In Python the prompt-once latch is a module global (`_permissions_prompted`).
// Here it is instance state on `PermissionsGate`, owned by the server layer.
//
// Effects are driven through the Core provider seams so this stays pure and
// Linux-testable: `AppResolver.checkAccessibilityPermission(prompt:)` for AX and
// `CaptureProvider.checkScreenRecordingPermission()` /
// `promptScreenRecordingPermission()` for screen recording.

/// Returned to the model while permissions are still being granted. Verbatim
/// from `main.PERMISSIONS_PENDING_MESSAGE`.
public let permissionsPendingMessage =
    "Permissions are still pending. Accessibility and Screen Recording "
    + "permissions have not been granted yet. Call this tool again — the user "
    + "may still be granting permissions. Do not end your turn."

/// Gate run before every tool call. Prompts once, then re-checks each call until
/// both Accessibility and Screen Recording are granted.
public final class PermissionsGate {
    private let apps: AppResolver
    private let capture: CaptureProvider
    private var prompted = false

    public init(apps: AppResolver, capture: CaptureProvider) {
        self.apps = apps
        self.capture = capture
    }

    /// Mirrors `check_permissions_with_retry_guidance()`. Returns the pending
    /// message if either permission is missing, otherwise nil.
    public func checkWithRetryGuidance() -> String? {
        let axOk: Bool
        let screenOk: Bool

        if !prompted {
            prompted = true
            // First call: trigger the system permission dialogs (non-blocking).
            axOk = apps.checkAccessibilityPermission(prompt: true)
            screenOk = capture.promptScreenRecordingPermission()
        } else {
            // Subsequent calls: check without prompting.
            axOk = apps.checkAccessibilityPermission(prompt: false)
            screenOk = capture.checkScreenRecordingPermission()
        }

        if !axOk || !screenOk {
            return permissionsPendingMessage
        }
        return nil
    }

    /// Explicit Accessibility preflight (the check the Python lacks per §6):
    /// AX is required for essentially every tool, so a caller can short-circuit
    /// to a clear pending message the moment AX is missing — without waiting on
    /// the screen-recording leg. Does not prompt and does not consume the
    /// prompt-once latch.
    public func accessibilityPreflight() -> Bool {
        apps.checkAccessibilityPermission(prompt: false)
    }
}
