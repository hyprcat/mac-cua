// KitClipboardProvider.swift — real macOS clipboard access (US-041, design D2).
//
// Background-safe `NSPasteboard` read/write/clear. The general pasteboard is a
// system-wide service: get/set/clear require no app target, no session, no
// window, and NEVER focus, raise or activate anything (the Prime Invariant holds
// trivially — there is nothing to foreground). Plain-text only (mirrors the
// Python `NSPasteboardTypeString` usage in selection.py's pasteboard path).

#if os(macOS)
import Foundation
import AppKit
import MacCUACore

public final class KitClipboardProvider: ClipboardProvider {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Current plain-text clipboard contents, or nil when empty/non-text.
    public func get() throws -> String? {
        pasteboard.string(forType: .string)
    }

    /// Replace the clipboard with `text` (clears prior contents first, per the
    /// NSPasteboard ownership contract).
    public func set(_ text: String) throws {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Clear the clipboard.
    public func clear() throws {
        pasteboard.clearContents()
    }
}
#endif
