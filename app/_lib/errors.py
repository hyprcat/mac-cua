class AutomationError(Exception):
    def __init__(self, message: str, code: int | None = None):
        super().__init__(message)
        self.code = code


class AXError(AutomationError):
    pass


class StaleReferenceError(AXError):
    pass


class ScreenshotError(AutomationError):
    pass


class InputError(AutomationError):
    pass


class BadIndexError(AutomationError):
    pass


class KeyPressError(InputError):
    """Key press validation errors."""
    MULTIPLE_NON_MODIFIER_KEYS = "multiple_non_modifier_keys"
    NO_NON_MODIFIER_KEYS = "no_non_modifier_keys"
    FAILED_TO_TRANSLATE = "unknown_key"


class CGEventError(InputError):
    """CGEvent creation/posting errors."""
    FAILED_TO_CREATE = "cg_event_creation_failed"


class RefetchError(AutomationError):
    """Element refetch errors."""
    NO_INVALIDATION_MONITOR = "no_monitor"
    AMBIGUOUS_BEFORE = "ambiguous_before_refetch"
    AMBIGUOUS_AFTER = "ambiguous_after_refetch"
    NOT_FOUND = "not_found_after_refetch"


class FocusError(AutomationError):
    """Focus management errors."""
    pass


class SafetyError(AutomationError):
    """Safety blocklist violations."""
    APP_BLOCKED = "app_blocked_for_safety"
    URL_BLOCKED = "url_blocked_for_safety"
    PRIVATE_IP_BLOCKED = "private_ip_address_blocked"


class UserInterruptionError(AutomationError):
    """User interrupted automation operation."""
    pass


class PermissionsPendingError(AutomationError):
    """Permissions not yet granted — caller should retry."""
    pass


class AppBlockedError(SafetyError):
    """App is blocked for safety reasons."""
    pass


class StepLimitError(AutomationError):
    """Step limit reached for the current turn."""
    pass


AX_ERROR_MESSAGES = {
    -25200: "invalid argument",
    -25201: "invalid element",
    -25202: "cannot complete",
    -25203: "not implemented",
    -25204: "attribute unsupported",
    -25205: "invalid UI element",
    -25206: "action unsupported",
    -25207: "notification unsupported",
    -25210: "API disabled",
    -25211: "parameter error",
    -25212: "cannot complete",
    -10005: "noWindowsAvailable / cannotClickOffscreenElement",
}


def ax_error(code: int, context: str = "") -> AXError:
    message = AX_ERROR_MESSAGES.get(code, f"unknown AX error {code}")
    if context:
        message = f"{context}: {message}"
    if code in (-25205, -25212):
        return StaleReferenceError(message, code=code)
    return AXError(message, code=code)
