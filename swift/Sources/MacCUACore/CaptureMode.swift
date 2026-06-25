/// Capture modes (US-058), mirroring the upstream cua-driver `som`/`ax`/`vision`.
///
/// These select *what* a snapshot produces, independent of how it is rendered:
///
/// - ``som`` (set-of-mark, the default): AX tree **and** screenshot. This is the
///   historical behavior and the only mode that yields both element indices (for
///   `element_index` addressing) and pixels.
/// - ``ax``: AX tree only, **no** screenshot. Because nothing is captured off the
///   screen, this mode can run with **no Screen Recording permission**.
/// - ``vision``: screenshot only, **no** AX tree. Note that `vision` yields **no
///   element indices**, so `element_index`-style addressing is unavailable in this
///   mode (callers must address by coordinates).
public enum CaptureMode: String, Sendable, CaseIterable, Equatable {
    case som      // default: AX tree + screenshot
    case ax       // AX tree only (no screenshot → no Screen Recording permission needed)
    case vision   // screenshot only (no AX tree → no element_index addressing)

    /// The mode used when none is specified by the caller.
    public static let `default`: CaptureMode = .som

    /// Parse from a tool-input string; nil/unknown → nil so the caller can decide
    /// (callers should fall back to ``default``). Case-insensitive.
    public static func parse(_ raw: String?) -> CaptureMode? {
        guard let raw else { return nil }
        return CaptureMode(rawValue: raw.lowercased())
    }

    /// What a snapshot should actually produce in this mode.
    public var plan: CapturePlan {
        switch self {
        case .som:
            return CapturePlan(captureTree: true, captureScreenshot: true)
        case .ax:
            return CapturePlan(captureTree: true, captureScreenshot: false)
        case .vision:
            return CapturePlan(captureTree: false, captureScreenshot: true)
        }
    }
}

/// The concrete "what to capture" decision derived from a ``CaptureMode``.
///
/// - `captureTree`: whether to walk/serialize the accessibility (AX) tree.
/// - `captureScreenshot`: whether to capture screen pixels (requires Screen
///   Recording permission at the platform layer).
public struct CapturePlan: Sendable, Equatable {
    public let captureTree: Bool
    public let captureScreenshot: Bool

    public init(captureTree: Bool, captureScreenshot: Bool) {
        self.captureTree = captureTree
        self.captureScreenshot = captureScreenshot
    }
}
