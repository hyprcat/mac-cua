// CaptureFilterCache.swift — pure capture-filter cache bookkeeping (B2, US-024).
//
// Linux-green: NO ScreenCaptureKit / CoreGraphics. This is the cache *policy*
// only — the macOS `SCContentFilter` (the expensive ~80–200 ms cold artifact)
// is stored as the generic `Value` by the Kit `KitCaptureProvider`.
//
// Two invalidation triggers, both ported from CODEX_PARITY §B2:
//   1. display-config change  -> `invalidateAll()` (the whole window-server layout
//      moved, so every cached filter is suspect; bumps `generation`).
//   2. window-replace         -> a cached entry is only returned when the window's
//      live signature (owner pid + bounds + title) still matches; CGWindowIDs are
//      recycled, so a same-id-different-window must miss and re-resolve.

import Foundation

/// Identity fingerprint of a window used to detect window-replace under a recycled
/// `CGWindowID`. Two windows sharing an id but differing in owner/bounds/title are
/// NOT the same window, so a cached filter for the old one must not be reused.
public struct CapturedWindowSignature: Equatable, Sendable {
    public let ownerPid: Int
    public let bounds: Rect
    public let title: String?

    public init(ownerPid: Int, bounds: Rect, title: String?) {
        self.ownerPid = ownerPid
        self.bounds = bounds
        self.title = title
    }
}

/// Per-window cache of the resolved capture filter (generic so Core stays free of
/// any SCK type). Reference type — reuse within/across calls IS the point (B2).
public final class CaptureFilterCache<Value> {
    private struct Entry {
        let value: Value
        let signature: CapturedWindowSignature
    }

    private var entries: [Int: Entry] = [:]
    /// Bumped on every display-config invalidation. Exposed so the Kit layer can
    /// cheaply detect "did the layout change since I last cached" if it wants.
    public private(set) var generation: Int = 0

    public init() {}

    /// Number of live cached entries (test/observability hook).
    public var count: Int { entries.count }

    /// Cached filter for `windowId`, but ONLY if the live signature still matches
    /// the one captured at store time (window-replace guard). A mismatch evicts
    /// the stale entry and returns nil so the caller re-resolves.
    public func value(forWindowId windowId: Int, signature: CapturedWindowSignature) -> Value? {
        guard let entry = entries[windowId] else { return nil }
        if entry.signature == signature { return entry.value }
        entries[windowId] = nil
        return nil
    }

    /// Store/replace the resolved filter for `windowId` keyed to its signature.
    public func store(_ value: Value, forWindowId windowId: Int, signature: CapturedWindowSignature) {
        entries[windowId] = Entry(value: value, signature: signature)
    }

    /// Drop a single window's cached filter (e.g. capture failed against it).
    public func invalidate(windowId: Int) {
        entries[windowId] = nil
    }

    /// Display-config change: every cached filter is suspect (a display was added/
    /// removed/reconfigured, so window↔display mapping and backing scale may differ).
    /// Clears all entries and advances `generation`.
    public func invalidateAll() {
        entries.removeAll()
        generation += 1
    }
}
