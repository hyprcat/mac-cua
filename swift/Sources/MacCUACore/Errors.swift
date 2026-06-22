import Foundation

// Port of app/_lib/errors.py.
//
// Python models these as a class hierarchy rooted at `AutomationError(Exception)`,
// each carrying a `message` and optional `code`. Several leaf classes also expose
// string *reason codes* as class attributes (e.g. `KeyPressError.NO_NON_MODIFIER_KEYS`).
//
// Swift has no single-rooted exception hierarchy, so we mirror this as one
// `AutomationError` struct that carries a `kind` discriminator (preserving the
// Python class name) plus `message` and optional `code`. The reason-code class
// attributes are preserved as `static let` constants grouped in caseless enums,
// keeping the exact string values. A `isStaleReference` / `isAppBlocked` style of
// subtype check is available via `kind`.

/// The single error type flowing through the Core pipeline, mirroring the
/// `AutomationError` hierarchy in `app/_lib/errors.py`.
///
/// `kind` preserves which Python subclass would have been raised so callers can
/// branch on it the way Python `except` clauses would.
public struct AutomationError: Error, Equatable, CustomStringConvertible {
    /// Discriminator preserving the Python exception class name.
    public enum Kind: String, Equatable, Sendable {
        case automation = "AutomationError"
        case ax = "AXError"
        case staleReference = "StaleReferenceError"
        case screenshot = "ScreenshotError"
        case input = "InputError"
        case badIndex = "BadIndexError"
        case keyPress = "KeyPressError"
        case cgEvent = "CGEventError"
        case refetch = "RefetchError"
        case focus = "FocusError"
        case safety = "SafetyError"
        case userInterruption = "UserInterruptionError"
        case permissionsPending = "PermissionsPendingError"
        case appBlocked = "AppBlockedError"
        case stepLimit = "StepLimitError"
    }

    public var kind: Kind
    public var message: String
    public var code: Int?

    public init(kind: Kind = .automation, _ message: String, code: Int? = nil) {
        self.kind = kind
        self.message = message
        self.code = code
    }

    public var description: String { message }

    // MARK: - Subclass relationships (mirrors Python `isinstance` checks)

    /// `True` for the AX family: `AXError` and its subclass `StaleReferenceError`.
    public var isAXError: Bool { kind == .ax || kind == .staleReference }

    /// `True` for the input family: `InputError`, `KeyPressError`, `CGEventError`.
    public var isInputError: Bool { kind == .input || kind == .keyPress || kind == .cgEvent }

    /// `True` for the safety family: `SafetyError` and its subclass `AppBlockedError`.
    public var isSafetyError: Bool { kind == .safety || kind == .appBlocked }

    // MARK: - Convenience constructors mirroring the Python subclasses

    public static func automation(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .automation, message, code: code)
    }
    public static func ax(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .ax, message, code: code)
    }
    public static func staleReference(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .staleReference, message, code: code)
    }
    public static func screenshot(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .screenshot, message, code: code)
    }
    public static func input(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .input, message, code: code)
    }
    public static func badIndex(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .badIndex, message, code: code)
    }
    public static func keyPress(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .keyPress, message, code: code)
    }
    public static func cgEvent(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .cgEvent, message, code: code)
    }
    public static func refetch(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .refetch, message, code: code)
    }
    public static func focus(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .focus, message, code: code)
    }
    public static func safety(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .safety, message, code: code)
    }
    public static func userInterruption(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .userInterruption, message, code: code)
    }
    public static func permissionsPending(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .permissionsPending, message, code: code)
    }
    public static func appBlocked(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .appBlocked, message, code: code)
    }
    public static func stepLimit(_ message: String, code: Int? = nil) -> AutomationError {
        AutomationError(kind: .stepLimit, message, code: code)
    }
}

// MARK: - Reason-code constants (mirror Python class attributes)

/// Key press validation reason codes (`KeyPressError` class attributes).
public enum KeyPressError {
    public static let multipleNonModifierKeys = "multiple_non_modifier_keys"
    public static let noNonModifierKeys = "no_non_modifier_keys"
    public static let failedToTranslate = "unknown_key"
}

/// CGEvent creation/posting reason codes (`CGEventError` class attributes).
public enum CGEventError {
    public static let failedToCreate = "cg_event_creation_failed"
}

/// Element refetch reason codes (`RefetchError` class attributes).
public enum RefetchError {
    public static let noInvalidationMonitor = "no_monitor"
    public static let ambiguousBefore = "ambiguous_before_refetch"
    public static let ambiguousAfter = "ambiguous_after_refetch"
    public static let notFound = "not_found_after_refetch"
}

/// Safety blocklist reason codes (`SafetyError` class attributes).
public enum SafetyError {
    public static let appBlocked = "app_blocked_for_safety"
    public static let urlBlocked = "url_blocked_for_safety"
    public static let privateIPBlocked = "private_ip_address_blocked"
}

// MARK: - AX error code mapping

/// Maps Apple AX framework status codes to human-readable messages.
/// Mirrors `AX_ERROR_MESSAGES` in `app/_lib/errors.py`.
public let axErrorMessages: [Int: String] = [
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
]

/// Build an `AXError` (or `StaleReferenceError`) from a raw AX status code.
/// Mirrors `ax_error()` in `app/_lib/errors.py`.
public func axError(_ code: Int, context: String = "") -> AutomationError {
    var message = axErrorMessages[code] ?? "unknown AX error \(code)"
    if !context.isEmpty {
        message = "\(context): \(message)"
    }
    if code == -25205 || code == -25212 {
        return AutomationError(kind: .staleReference, message, code: code)
    }
    return AutomationError(kind: .ax, message, code: code)
}
