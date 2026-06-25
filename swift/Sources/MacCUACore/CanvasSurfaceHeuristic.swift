// CanvasSurfaceHeuristic.swift — best-effort canvas / foreground-only surface
// detection (US-060), pure tier.
//
// Some surfaces (Blender's GHOST windowing layer, Unity / common game engines,
// other GPU canvas apps) only accept synthetic input *after* a window activation.
// mac-cua never foregrounds, activates, or raises a window (Prime Invariant,
// Inv 18) — strictly stricter than upstream cua-driver, which falls back to
// activation and warps the cursor. So a coordinate click into such a surface
// silently lands nowhere. This file's job is to let those clicks FAIL LOUDLY
// (via `UnsupportedSurfaceError.canvasSurface`) or at least HINT, rather than
// drop silently.
//
// This is deliberately a MODEST heuristic, not a detection engine. The decision
// logic is pure/Linux-testable; the macOS layer supplies the `SurfaceDescriptor`
// from the live AX/window state and decides whether to raise the structured error
// up-front or attach `noEffectHint` after outcome verification. There is no Python
// reference — this is a Swift-port-only feature (see
// `docs/superpowers/specs/2026-06-25-background-input-learnings-design.md`,
// US-060, and `docs/KNOWN_LIMITATIONS.md`).

import Foundation

/// Pure, platform-free description of a surface (window) under the cursor, enough
/// for the canvas heuristic to make a best-effort call. The macOS layer fills this
/// from the live AX tree / window owner; Core never touches platform types.
public struct SurfaceDescriptor: Sendable, Equatable {
    /// The owning application's bundle identifier, when known
    /// (e.g. `"org.blender.blender"`). `nil` when the platform could not resolve it.
    public let bundleId: String?

    /// Number of *actionable* AX nodes the window exposed (buttons, fields, menus,
    /// links — the things a click could address). A genuine canvas surface tends to
    /// expose ~0; but so does a permission-blocked app, so `0` alone is only a weak
    /// signal (see `isLikelyCanvasSurface`).
    public let axRoleCount: Int

    public init(bundleId: String?, axRoleCount: Int) {
        self.bundleId = bundleId
        self.axRoleCount = axRoleCount
    }
}

/// Best-effort classifier for canvas / foreground-only surfaces that mac-cua
/// cannot click without violating Inv 18.
public enum CanvasSurfaceHeuristic {
    /// Known foreground-only / canvas bundle ids. **Not exhaustive** — extend as
    /// real surfaces are confirmed. Membership is an exact, case-sensitive match
    /// (bundle ids are canonically lowercase reverse-DNS).
    ///
    /// Included:
    /// - Blender (its GHOST windowing layer is the canonical case).
    /// - Unity-built apps and the Unity editor (`com.unity3d.*`, matched by the
    ///   game-engine prefix rule below; the editor id is listed explicitly too).
    public static let knownCanvasBundleIds: Set<String> = [
        "org.blender.blender",          // Blender (GHOST)
        "com.unity3d.UnityEditor",      // Unity editor
        "com.unity.UnityHub",           // Unity Hub launcher
        "com.epicgames.UnrealEditor",   // Unreal Engine editor
        "com.godotengine.godot",        // Godot editor
    ]

    /// Bundle-id *prefixes* that strongly indicate a game-engine / canvas surface.
    /// A prefix rule (rather than enumerating every shipped game) keeps the set
    /// small while still covering the engines that reuse a vendor prefix.
    /// Case-insensitive prefix match. Kept conservative — these are vendor
    /// namespaces dominated by full-screen canvas apps.
    public static let canvasBundleIdPrefixes: [String] = [
        "com.unity3d.",   // Unity-built players ship under the vendor's prefix
        "com.unity.",     // newer Unity tooling/editor namespace
    ]

    /// Best-effort: `true` when the surface is very likely a canvas / foreground-only
    /// surface that mac-cua cannot click without violating Inv 18.
    ///
    /// CONSERVATIVE BY DESIGN — a false positive blocks a legitimate app, which is
    /// worse than a false negative (the latter merely degrades to the existing
    /// silent no-op + `noEffectHint`). The rule is intentionally simple and is the
    /// *only* thing that gates the up-front structured error:
    ///
    ///   - `true` if `bundleId` is in `knownCanvasBundleIds`, OR
    ///   - `true` if `bundleId` is non-nil and starts with a `canvasBundleIdPrefixes`
    ///     game-engine prefix.
    ///
    /// LIMITS (documented on purpose):
    ///   - A near-empty AX tree (`axRoleCount == 0`) is **NOT** sufficient on its
    ///     own. Many ordinary apps expose an empty tree transiently — most notably
    ///     before Accessibility permission is granted, or Chromium/Electron before
    ///     enhanced-UI is enabled. Flagging those as "canvas" would wrongly block
    ///     them, so `axRoleCount` never *raises* this verdict by itself; it only
    ///     informs the softer `noEffectHint`.
    ///   - Unknown bundle ids are never flagged here, even with an empty tree. New
    ///     canvas surfaces must be added to the known set / prefixes to get the
    ///     up-front error; until then they degrade to the post-hoc hint.
    public static func isLikelyCanvasSurface(_ s: SurfaceDescriptor) -> Bool {
        guard let bundleId = s.bundleId, !bundleId.isEmpty else { return false }
        if knownCanvasBundleIds.contains(bundleId) { return true }
        let lower = bundleId.lowercased()
        for prefix in canvasBundleIdPrefixes where lower.hasPrefix(prefix.lowercased()) {
            return true
        }
        return false
    }

    /// Pure hint string for outcome verification to append when a *pixel* click on a
    /// non-AX surface verified as a no-op. It does **NOT** assert anything — it is a
    /// soft hint, deliberately phrased as a possibility, to point a stuck caller at
    /// the canvas/foreground limitation without falsely claiming detection.
    ///
    /// The hint is stronger when the bundle id is itself a known canvas surface, and
    /// otherwise mentions the empty AX tree as the (weak) reason it is suspected.
    public static func noEffectHint(_ s: SurfaceDescriptor) -> String {
        let base =
            "Click verified as no-op. This may be a canvas / foreground-only surface "
            + "(e.g. a game engine or GPU canvas) that only accepts input after window "
            + "activation, which mac-cua does not perform by design (Prime Invariant)."
        if isLikelyCanvasSurface(s) {
            let detail = s.bundleId.map { " Bundle id '\($0)' is a known canvas surface." } ?? ""
            return base + detail + " Such surfaces are unsupported; see KNOWN_LIMITATIONS.md."
        }
        if s.axRoleCount == 0 {
            return base
                + " The window also exposed no actionable accessibility nodes, a weak "
                + "signal consistent with (but not proof of) a canvas surface. See "
                + "KNOWN_LIMITATIONS.md."
        }
        return base + " See KNOWN_LIMITATIONS.md."
    }
}
