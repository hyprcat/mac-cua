import Foundation

// Port of app/_lib/flags.py.
//
// Feature flags control capabilities; workaround flags are for known issues.
// Both load from an optional JSON config file with environment-variable overrides.
//
// Framework dependency abstracted: Python reads `os.environ` directly. Here the
// env lookup is injected as a `(String) -> String?` closure, defaulting to
// `ProcessInfo.processInfo.environment[key]`. File reading is kept out of the
// pure-logic layer: `load` accepts an already-decoded `[String: Any]` config (or
// nil), so parse/override logic is fully testable on Linux without touching disk.

/// Default config path, mirroring `_DEFAULT_CONFIG_PATH`. Resolution/expansion of
/// `~` and actual disk reads are the adapter layer's job.
public let defaultFlagsConfigPath = "~/.config/mac-cua/flags.json"

/// Default environment lookup, used when no override is supplied.
public func processInfoEnv(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key]
}

/// Parse a Python-style truthy string: `"1" | "true" | "yes"` (case-insensitive).
/// Mirrors `env_val.lower() in ("1", "true", "yes")`.
@inline(__always)
func parseFlagBool(_ value: String) -> Bool {
    switch value.lowercased() {
    case "1", "true", "yes": return true
    default: return false
    }
}

/// Runtime feature toggles. Mirrors `FeatureFlags`.
///
/// Env var override: `MAC_CUA_FLAG_<UPPER_SNAKE_NAME>=1|0|true|false`.
/// Field names use lowerCamelCase; the env key uses the original UPPER_SNAKE form.
public struct FeatureFlags: Equatable, Sendable {
    public var alwaysSimulateClick: Bool
    public var screenshotClassifier: Bool
    public var treePruning: Bool
    public var codexTreeStyle: Bool
    public var richTextMarkdown: Bool
    public var webContentExtraction: Bool
    public var userInterruptionDetection: Bool
    public var focusEnforcement: Bool
    public var screenCaptureKit: Bool
    public var menuTracking: Bool
    public var transientGraphs: Bool
    public var axActionVerification: Bool
    public var cgeventActionVerification: Bool
    public var transientGraphDebug: Bool
    public var systemSelection: Bool
    public var pipPreview: Bool
    public var personalInstructionsOverridesBuiltin: Bool
    public var advancedPruning: Bool
    public var allowForbiddenTargets: Bool
    public var confirmedDelivery: Bool
    /// Vision OCR fallback for tree-less surfaces (A2, US-046). Off by default —
    /// OCR is opt-in and strictly gated to near-empty/AX-unavailable surfaces.
    public var ocrFallback: Bool
    /// Chromium user-activation primer click (US-057). On by default — a
    /// kill-switch. Scoped at the call site to web-content pixel clicks only;
    /// off-screen + pid-scoped, so it never foregrounds (Inv 18).
    public var clickPrimer: Bool
    /// Remote-aware AX observer registration for occluded Electron (US-059). On by
    /// default — a kill-switch. Optional/dlsym-gated (Inv 17); absence degrades to
    /// the public `AXObserverAddNotification`. Correctness is unaffected either way.
    public var electronRemoteObserver: Bool

    public init(
        alwaysSimulateClick: Bool = false,
        screenshotClassifier: Bool = false,
        treePruning: Bool = true,
        codexTreeStyle: Bool = true,
        richTextMarkdown: Bool = true,
        webContentExtraction: Bool = true,
        userInterruptionDetection: Bool = true,
        focusEnforcement: Bool = true,
        screenCaptureKit: Bool = true,
        menuTracking: Bool = true,
        transientGraphs: Bool = true,
        axActionVerification: Bool = true,
        cgeventActionVerification: Bool = true,
        transientGraphDebug: Bool = false,
        systemSelection: Bool = true,
        pipPreview: Bool = false,
        personalInstructionsOverridesBuiltin: Bool = false,
        advancedPruning: Bool = true,
        allowForbiddenTargets: Bool = false,
        confirmedDelivery: Bool = true,
        ocrFallback: Bool = false,
        clickPrimer: Bool = true,
        electronRemoteObserver: Bool = true
    ) {
        self.alwaysSimulateClick = alwaysSimulateClick
        self.screenshotClassifier = screenshotClassifier
        self.treePruning = treePruning
        self.codexTreeStyle = codexTreeStyle
        self.richTextMarkdown = richTextMarkdown
        self.webContentExtraction = webContentExtraction
        self.userInterruptionDetection = userInterruptionDetection
        self.focusEnforcement = focusEnforcement
        self.screenCaptureKit = screenCaptureKit
        self.menuTracking = menuTracking
        self.transientGraphs = transientGraphs
        self.axActionVerification = axActionVerification
        self.cgeventActionVerification = cgeventActionVerification
        self.transientGraphDebug = transientGraphDebug
        self.systemSelection = systemSelection
        self.pipPreview = pipPreview
        self.personalInstructionsOverridesBuiltin = personalInstructionsOverridesBuiltin
        self.advancedPruning = advancedPruning
        self.allowForbiddenTargets = allowForbiddenTargets
        self.confirmedDelivery = confirmedDelivery
        self.ocrFallback = ocrFallback
        self.clickPrimer = clickPrimer
        self.electronRemoteObserver = electronRemoteObserver
    }

    /// All flag snake_case (config + env) names, in `dataclasses.fields(cls)` order.
    /// Used for config/env iteration and `isEnabled`.
    public static let fieldNames: [String] = [
        "always_simulate_click",
        "screenshot_classifier",
        "tree_pruning",
        "codex_tree_style",
        "rich_text_markdown",
        "web_content_extraction",
        "user_interruption_detection",
        "focus_enforcement",
        "screen_capture_kit",
        "menu_tracking",
        "transient_graphs",
        "ax_action_verification",
        "cgevent_action_verification",
        "transient_graph_debug",
        "system_selection",
        "pip_preview",
        "personal_instructions_overrides_builtin",
        "advanced_pruning",
        "allow_forbidden_targets",
        "confirmed_delivery",
        "ocr_fallback",
        "click_primer",
        "electron_remote_observer",
    ]

    /// Read a flag by its snake_case name. Returns nil for unknown names.
    func get(_ name: String) -> Bool? {
        switch name {
        case "always_simulate_click": return alwaysSimulateClick
        case "screenshot_classifier": return screenshotClassifier
        case "tree_pruning": return treePruning
        case "codex_tree_style": return codexTreeStyle
        case "rich_text_markdown": return richTextMarkdown
        case "web_content_extraction": return webContentExtraction
        case "user_interruption_detection": return userInterruptionDetection
        case "focus_enforcement": return focusEnforcement
        case "screen_capture_kit": return screenCaptureKit
        case "menu_tracking": return menuTracking
        case "transient_graphs": return transientGraphs
        case "ax_action_verification": return axActionVerification
        case "cgevent_action_verification": return cgeventActionVerification
        case "transient_graph_debug": return transientGraphDebug
        case "system_selection": return systemSelection
        case "pip_preview": return pipPreview
        case "personal_instructions_overrides_builtin": return personalInstructionsOverridesBuiltin
        case "advanced_pruning": return advancedPruning
        case "allow_forbidden_targets": return allowForbiddenTargets
        case "confirmed_delivery": return confirmedDelivery
        case "ocr_fallback": return ocrFallback
        case "click_primer": return clickPrimer
        case "electron_remote_observer": return electronRemoteObserver
        default: return nil
        }
    }

    /// Set a flag by its snake_case name. No-op for unknown names.
    mutating func set(_ name: String, _ value: Bool) {
        switch name {
        case "always_simulate_click": alwaysSimulateClick = value
        case "screenshot_classifier": screenshotClassifier = value
        case "tree_pruning": treePruning = value
        case "codex_tree_style": codexTreeStyle = value
        case "rich_text_markdown": richTextMarkdown = value
        case "web_content_extraction": webContentExtraction = value
        case "user_interruption_detection": userInterruptionDetection = value
        case "focus_enforcement": focusEnforcement = value
        case "screen_capture_kit": screenCaptureKit = value
        case "menu_tracking": menuTracking = value
        case "transient_graphs": transientGraphs = value
        case "ax_action_verification": axActionVerification = value
        case "cgevent_action_verification": cgeventActionVerification = value
        case "transient_graph_debug": transientGraphDebug = value
        case "system_selection": systemSelection = value
        case "pip_preview": pipPreview = value
        case "personal_instructions_overrides_builtin": personalInstructionsOverridesBuiltin = value
        case "advanced_pruning": advancedPruning = value
        case "allow_forbidden_targets": allowForbiddenTargets = value
        case "confirmed_delivery": confirmedDelivery = value
        case "ocr_fallback": ocrFallback = value
        case "click_primer": clickPrimer = value
        case "electron_remote_observer": electronRemoteObserver = value
        default: break
        }
    }

    /// Load from an optional decoded config map plus env overrides.
    ///
    /// - Parameters:
    ///   - config: The decoded top-level config object (or nil if no file). The
    ///     `"features"` sub-object is preferred, falling back to the top level —
    ///     mirroring `data.get("features", data)`.
    ///   - env: Environment lookup closure (defaults to `ProcessInfo`).
    public static func load(
        config: [String: Any]? = nil,
        env: (String) -> String? = processInfoEnv
    ) -> FeatureFlags {
        var instance = FeatureFlags()

        // Config file overrides (features sub-object, falling back to top level).
        if let config {
            let featureData = (config["features"] as? [String: Any]) ?? config
            for name in fieldNames {
                if let raw = featureData[name] {
                    instance.set(name, truthy(raw))
                }
            }
        }

        // Environment-variable overrides.
        for name in fieldNames {
            let envKey = "MAC_CUA_FLAG_\(name.uppercased())"
            if let envVal = env(envKey) {
                instance.set(name, parseFlagBool(envVal))
            }
        }

        return instance
    }

    /// Runtime flag check by snake_case name. Mirrors `is_enabled`; unknown names
    /// return `false` (Python `getattr(self, name, False)`).
    public func isEnabled(_ flagName: String) -> Bool {
        get(flagName) ?? false
    }
}

/// Runtime workaround flags for known issues. Mirrors `WorkaroundFlags`.
///
/// Env var override: `MAC_CUA_WORKAROUND_<UPPER_SNAKE_NAME>`.
public struct WorkaroundFlags: Equatable, Sendable {
    public var meetingNotesInCalendar: Bool
    public var shortenLinksForDemo: Bool

    public init(
        meetingNotesInCalendar: Bool = false,
        shortenLinksForDemo: Bool = false
    ) {
        self.meetingNotesInCalendar = meetingNotesInCalendar
        self.shortenLinksForDemo = shortenLinksForDemo
    }

    public static func load(
        config: [String: Any]? = nil,
        env: (String) -> String? = processInfoEnv
    ) -> WorkaroundFlags {
        var instance = WorkaroundFlags()

        if let config, let workaroundData = config["workarounds"] as? [String: Any] {
            if let raw = workaroundData["meeting_notes_in_calendar"] {
                instance.meetingNotesInCalendar = truthy(raw)
            }
            if let raw = workaroundData["shorten_links_for_demo"] {
                instance.shortenLinksForDemo = truthy(raw)
            }
        }

        // Env overrides: bools parse as truthy.
        if let v = env("MAC_CUA_WORKAROUND_MEETING_NOTES_IN_CALENDAR") {
            instance.meetingNotesInCalendar = parseFlagBool(v)
        }
        if let v = env("MAC_CUA_WORKAROUND_SHORTEN_LINKS_FOR_DEMO") {
            instance.shortenLinksForDemo = parseFlagBool(v)
        }

        return instance
    }
}

// MARK: - JSON value coercion helpers (mirror Python `bool(x)` / `int(x)`)

/// Mirror of Python `bool(value)` for JSON-decoded values: numbers/strings/bools.
func truthy(_ value: Any) -> Bool {
    switch value {
    case let b as Bool: return b
    case let i as Int: return i != 0
    case let d as Double: return d != 0
    case let s as String: return !s.isEmpty
    case let n as NSNumber: return n.intValue != 0
    default: return true  // any non-nil object is truthy in Python
    }
}

func coerceInt(_ value: Any) -> Int? {
    switch value {
    case let i as Int: return i
    case let d as Double: return Int(d)
    case let b as Bool: return b ? 1 : 0
    case let s as String: return Int(s)
    case let n as NSNumber: return n.intValue
    default: return nil
    }
}
