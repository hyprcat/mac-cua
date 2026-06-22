import Foundation

// Port of app/_lib/virtual_cursor.py — the PURE parts only.
//
// What is ported here (no macOS dependency):
//   - AppType                    : framework heuristic used for strategy selection
//   - DeliveryMethod             : primary event-delivery pipeline enum
//   - ActivationPolicy           : when to micro-activate
//   - KeyPressError / KeyPress   : validated key-press value type
//   - InputStrategy              : the per-app-type strategy / policy matrix
//   - detectAppType(...)         : the bundle-ID classification, with the lsof
//                                  process sniff factored out behind a seam
//   - BackgroundCursor           : the logical-position model (move_to only
//                                  updates an internal coordinate; the real
//                                  cursor never moves). Actual click/drag
//                                  delivery is delegated to a protocol seam.
//
// What is NOT ported (lives in the macOS adapter layer, MacCUAKit):
//   - The concrete CGEvent / SkyLight delivery (`app/_lib/input.py`):
//     see `protocol PointerEventDelivering`.
//   - The `lsof -p <pid>` framework sniff: see `protocol ProcessLibraryProbing`.
//   - WindowUIElement (pure AX attribute plumbing — entirely macOS).
//   - VirtualKeyPress.from_combo's call into app._lib.keys.parse_key_combo,
//     which is the KeyParser module's job (KeyParser ports keys.py). Here the
//     value type is kept but parsing is left to that module.

// ---------------------------------------------------------------------------
// KeyPress — validated key press value type
// ---------------------------------------------------------------------------

// Key validation reason codes live in Errors.swift as `KeyPressError`
// (the faithful port of the Python `KeyPressError` class attributes). The
// KeyParser module throws `KeyParseError` for actual parse failures.

/// Validated key press. Mirrors `VirtualKeyPress`.
///
/// The Python `from_combo` classmethod delegates parsing to
/// `app._lib.keys.parse_key_combo`, which is the KeyParser module's
/// responsibility in the Swift port. This struct stays a pure value type;
/// callers construct it from a `(keycode, modifierMask)` pair produced by the
/// KeyParser.
public struct KeyPress: Equatable, Sendable {
    public let keycode: Int
    public let modifierMask: Int
    public let description: String

    public init(keycode: Int, modifierMask: Int, description: String) {
        self.keycode = keycode
        self.modifierMask = modifierMask
        self.description = description
    }
}

// ---------------------------------------------------------------------------
// AppType / DeliveryMethod / ActivationPolicy
// ---------------------------------------------------------------------------

/// Application framework type, used for input strategy selection.
/// Mirrors `AppType`.
public enum AppType: String, Sendable, CaseIterable {
    case nativeCocoa = "cocoa"
    case electron = "electron"
    case browser = "browser"
    case java = "java"
    case qt = "qt"
    case unknown = "unknown"
}

/// Primary event delivery pipeline. Mirrors `DeliveryMethod`.
public enum DeliveryMethod: String, Sendable {
    /// CGEventPostToPid — works for native Cocoa.
    case cgeventPid = "cgevent_pid"
    /// CGSPostKeyboardEventToProcess — works for Electron/browser/Java/Qt.
    case skylightSpi = "skylight_spi"
}

/// When to use invisible micro-activation. Mirrors `ActivationPolicy`.
public enum ActivationPolicy: String, Sendable {
    /// Never micro-activate (AX actions, native Cocoa CGEvent).
    case never = "never"
    /// Only on retry after background delivery failed.
    case retryOnly = "retry_only"
}

// ---------------------------------------------------------------------------
// App-type detection
// ---------------------------------------------------------------------------

/// Known browser bundle IDs. Mirrors `_BROWSER_BUNDLES`.
public let browserBundles: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
    "com.microsoft.edgemac",
    "com.microsoft.edgemac.Dev",
    "com.brave.Browser",
    "com.vivaldi.Vivaldi",
    "org.mozilla.firefox",
    "org.mozilla.nightly",
    "com.operasoftware.Opera",
    "company.thebrowser.Browser",  // Arc
]

/// Known Electron apps. Mirrors `_ELECTRON_BUNDLES`.
public let electronBundles: Set<String> = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.hnc.Discord",
    "com.tinyspeck.slackmacgap",
    "com.spotify.client",
    "com.github.GitHubClient",
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "notion.id",
    "com.figma.Desktop",
    "com.linear",
    "com.obsproject.obs-studio",
]

/// SEAM for the macOS layer: probes a process's loaded libraries (the Python
/// `lsof -p <pid> -Fn` sniff in `detect_app_type`). A conforming implementation
/// lives in MacCUAKit. Returns the concatenated library listing, or `nil` if
/// the probe failed/timed out (Python swallows the exception and falls through
/// to NATIVE_COCOA).
public protocol ProcessLibraryProbing: Sendable {
    func loadedLibraries(pid: Int) -> String?
}

/// Classify the loaded-library listing into an `AppType`, or `nil` if no
/// framework matched. Pure: this is the framework-string matching the Python
/// performs on the `lsof` output, split out so it is unit-testable without a
/// real process. Mirrors the framework checks inside `detect_app_type`.
public func classifyLibraries(_ libs: String) -> AppType? {
    let lower = libs.lowercased()
    if libs.contains("Electron Framework") || lower.contains("electron") {
        return .electron
    }
    if libs.contains("libjvm") || libs.contains("JavaNativeFoundation") {
        return .java
    }
    if libs.contains("QtCore") || libs.contains("QtWidgets") {
        return .qt
    }
    return nil
}

/// Heuristic app type detection. Mirrors `detect_app_type`.
///
/// Detection order:
///   1. Known browser bundle IDs
///   2. Known Electron bundle IDs
///   3. Framework detection from the process's loaded libraries (via the
///      `probe` seam; on macOS this is the `lsof` sniff)
///   4. Default to NATIVE_COCOA
///
/// `probe` is optional so the pure/Linux path (and tests covering bundle-ID
/// classification) can run without a process probe; passing `nil` is the same
/// as the Python `try/except` swallowing the subprocess error and falling
/// through to NATIVE_COCOA.
public func detectAppType(
    bundleId: String,
    pid: Int,
    probe: ProcessLibraryProbing? = nil
) -> AppType {
    if browserBundles.contains(bundleId) {
        return .browser
    }
    if electronBundles.contains(bundleId) {
        return .electron
    }
    if let probe, let libs = probe.loadedLibraries(pid: pid),
       let matched = classifyLibraries(libs) {
        return matched
    }
    return .nativeCocoa
}

// ---------------------------------------------------------------------------
// InputStrategy — per-app-type input strategy selection
// ---------------------------------------------------------------------------

/// Per-app-type input strategy selection. Mirrors `InputStrategy`.
///
/// Strategy matrix (from spec):
///
///     | App Type      | Click          | Type        | Scroll      | Focus    |
///     |---------------|----------------|-------------|-------------|----------|
///     | Native Cocoa  | AX preferred   | AX set value| AX scroll   | AX focus |
///     | Electron      | CGEvent pref   | CGEvent keys| CGEvent whl | CGEvent  |
///     | Browser (web) | CGEvent always | CGEvent keys| CGEvent whl | CGEvent  |
///     | Browser (UI)  | AX preferred   | AX set value| AX scroll   | AX focus |
///     | Java/Qt       | CGEvent always | CGEvent keys| CGEvent whl | CGEvent  |
///
/// Reference type to mirror Python's mutable instance (`_ax_failure_count`
/// escalation is stateful across calls).
public final class InputStrategy {
    private let _appType: AppType
    private let forceSimulate: Bool
    private var axFailureCount: Int = 0

    public init(appType: AppType, forceSimulate: Bool = false) {
        self._appType = appType
        self.forceSimulate = forceSimulate
    }

    public var appType: AppType { _appType }

    /// Action category for `shouldUseAXAction`. Mirrors the Python string
    /// `action` argument ("click", "type", "scroll", "focus").
    public enum Action: String, Sendable {
        case click
        case type
        case scroll
        case focus
    }

    /// Whether to prefer AX action or CGEvent for this action type.
    /// Mirrors `should_use_ax_action`.
    public func shouldUseAXAction(_ action: Action, isWebArea: Bool = false) -> Bool {
        if forceSimulate {
            return false
        }

        if axFailureCount >= 2 {
            return false  // Auto-escalate after repeated failures
        }

        // Browser web content always uses CGEvent
        if _appType == .browser && isWebArea {
            return false
        }

        // Java/Qt/unknown always use CGEvent
        if _appType == .java || _appType == .qt || _appType == .unknown {
            return false
        }

        // Electron prefers CGEvent for most operations
        if _appType == .electron {
            // Electron AX click is unreliable — prefer CGEvent.
            // Only AX focus works well in Electron.
            return action == .focus
        }

        // Native Cocoa and browser chrome: AX preferred
        return true
    }

    /// Record an AX action failure for auto-escalation.
    /// Mirrors `record_ax_failure`.
    public func recordAXFailure() {
        axFailureCount += 1
    }

    /// Reset failure count (e.g., on new session). Mirrors `reset_failures`.
    public func resetFailures() {
        axFailureCount = 0
    }

    /// Primary delivery pipeline for this app type. Mirrors `delivery_method`.
    public var deliveryMethod: DeliveryMethod {
        if _appType == .nativeCocoa || _appType == .unknown {
            return .cgeventPid
        }
        return .skylightSpi
    }

    /// Fallback delivery pipeline. Mirrors `alternate_delivery_method`.
    public var alternateDeliveryMethod: DeliveryMethod {
        deliveryMethod == .cgeventPid ? .skylightSpi : .cgeventPid
    }

    /// When to use micro-activation for regular actions.
    /// Mirrors `activation_policy`.
    public var activationPolicy: ActivationPolicy {
        if _appType == .nativeCocoa || _appType == .unknown {
            return .never
        }
        return .retryOnly
    }

    /// Popups always qualify for micro-activation retry.
    /// Mirrors `activation_policy_for_popup`.
    public var activationPolicyForPopup: ActivationPolicy {
        .retryOnly
    }
}

// ---------------------------------------------------------------------------
// VirtualCursor protocol + BackgroundCursor
// ---------------------------------------------------------------------------

/// Abstract cursor operations. Mirrors the `VirtualCursor` Protocol.
public protocol VirtualCursor: AnyObject {
    /// Current cursor position in screen coordinates.
    var position: Point { get }
    /// Current position in scaled (screenshot) coordinates.
    var positionInScaledCoordinates: Point { get }

    func moveTo(_ position: Point, animated: Bool)
    func clickAt(_ position: Point)
    func doubleClickAt(_ position: Point)
    func rightClickAt(_ position: Point)
    func drag(from: Point, to: Point)
}

/// SEAM for the macOS layer: actual pointer-event delivery. Mirrors the calls
/// into `app/_lib/input.py` (`click_at` / `drag` via CGEventPostToPid) that
/// `BackgroundCursor` makes. A conforming implementation lives in MacCUAKit;
/// the pure `BackgroundCursor` below only updates its logical coordinate and
/// forwards to this delegate when one is supplied.
public protocol PointerEventDelivering: AnyObject {
    func clickAt(pid: Int, windowId: Int, x: Double, y: Double,
                 button: PointerButton, count: Int, screenshotSize: Size?)
    func drag(pid: Int, windowId: Int, fromX: Double, fromY: Double,
              toX: Double, toY: Double, screenshotSize: Size?)
}

/// Mouse button selector for delivery. Mirrors the Python `button=` string.
public enum PointerButton: String, Sendable {
    case left
    case right
}

/// Invisible cursor for headless MCP operation. Mirrors `BackgroundCursor`.
///
/// The logical-position model is pure: `moveTo` only updates an internal
/// coordinate; the real cursor never moves. Click/drag delivery is delegated
/// to an optional `PointerEventDelivering` seam (the CGEventPostToPid layer in
/// Python). When no delivery is wired (the Linux/pure path), the methods still
/// faithfully update the logical position exactly as Python does before it
/// calls into `cg_input`.
public final class BackgroundCursor: VirtualCursor {
    private let pid: Int
    private let windowId: Int
    private var _position: Point = Point(x: 0.0, y: 0.0)
    private var scaleFactor: Double = 1.0
    private var screenshotSize: Size?
    private let delivery: PointerEventDelivering?

    public init(pid: Int, windowId: Int, delivery: PointerEventDelivering? = nil) {
        self.pid = pid
        self.windowId = windowId
        self.delivery = delivery
    }

    public var position: Point { _position }

    public var positionInScaledCoordinates: Point {
        Point(x: _position.x / scaleFactor, y: _position.y / scaleFactor)
    }

    /// Set screenshot dimensions for coordinate conversion.
    /// Mirrors `set_screenshot_size`.
    public func setScreenshotSize(_ size: Size) {
        self.screenshotSize = size
    }

    /// Move cursor position (no visual, just track internally).
    /// Mirrors `move_to`.
    public func moveTo(_ position: Point, animated: Bool = false) {
        _position = position
    }

    /// Click via the delivery seam. Mirrors `click_at`.
    public func clickAt(_ position: Point) {
        _position = position
        delivery?.clickAt(pid: pid, windowId: windowId,
                          x: position.x, y: position.y,
                          button: .left, count: 1,
                          screenshotSize: screenshotSize)
    }

    /// Double-click via the delivery seam. Mirrors `double_click_at`.
    public func doubleClickAt(_ position: Point) {
        _position = position
        delivery?.clickAt(pid: pid, windowId: windowId,
                          x: position.x, y: position.y,
                          button: .left, count: 2,
                          screenshotSize: screenshotSize)
    }

    /// Right-click via the delivery seam. Mirrors `right_click_at`.
    public func rightClickAt(_ position: Point) {
        _position = position
        delivery?.clickAt(pid: pid, windowId: windowId,
                          x: position.x, y: position.y,
                          button: .right, count: 1,
                          screenshotSize: screenshotSize)
    }

    /// Drag via the delivery seam. Mirrors `drag`.
    public func drag(from: Point, to: Point) {
        _position = to
        delivery?.drag(pid: pid, windowId: windowId,
                       fromX: from.x, fromY: from.y,
                       toX: to.x, toY: to.y,
                       screenshotSize: screenshotSize)
    }
}
