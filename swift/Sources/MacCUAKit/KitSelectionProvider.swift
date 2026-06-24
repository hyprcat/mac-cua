// KitSelectionProvider.swift — real macOS text selection (US-040, design D1).
//
// `select_text` resolves a content/prefix/suffix request to a UTF-16 range with
// the pure `SelectTextResolver` (US-005); this provider applies that range to the
// target element through one of two macOS mechanisms, chosen by the pure
// `SelectTextTierDecider` (SelectTextTier.swift):
//
//   * Tier 1 (CFRange) — simple fields (`NSTextField`/`NSTextView`): set
//     `AXSelectedTextRange` via `AXValueCreate(.cfRange, …)`.
//   * Tier 2 (text markers) — web/rich content (Safari/Chrome/Mail/Pages): CFRange
//     selection does not work; build an `AXTextMarkerRange` from the resolved
//     offsets and set `AXSelectedTextMarkerRange`.
//
// Background-only: every call here reads/writes the app's own AX tree and NEVER
// focuses, raises or activates the window (Invariant 7 / Prime Invariant). When a
// mechanism is unavailable (e.g. the private text-marker symbols are absent on a
// future macOS), the apply fails honestly by throwing — there is no foregrounding
// fallback.

#if os(macOS)
import Foundation
import MacCUACore
import ApplicationServices
import CoreGraphics

@inline(__always)
private func axElement(_ ref: AXElementRef?) -> AXUIElement? {
    (ref as? KitAXElementRef)?.element
}

// MARK: - Private text-marker SPI (per-symbol-optional, dlsym-resolved)

/// The HIServices text-marker functions are private. Each is resolved once via
/// `dlsym(RTLD_DEFAULT, …)`; a nil result means the symbol is absent and the
/// Tier-2 path falls through to an honest throw (never a foregrounding fallback).
private enum AXTextMarkerSPI {
    // AXTextMarkerRangeRef AXTextMarkerRangeCreate(CFAllocatorRef, AXTextMarkerRef start, AXTextMarkerRef end)
    typealias RangeCreateFn = @convention(c)
        (CFAllocator?, CFTypeRef, CFTypeRef) -> Unmanaged<CFTypeRef>?

    static let rangeCreate: RangeCreateFn? = resolve("AXTextMarkerRangeCreate")

    private static func resolve<T>(_ name: String) -> T? {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}

// MARK: - Provider

public final class KitSelectionProvider: SelectionProvider {
    public init() {}

    // The system-selection observation seam is not used by `select_text`; it is
    // the `currentSelection()` path (kept inert until a future story needs it).
    public func startObserving(pid: Int) {}
    public func stopObserving() {}
    public func currentSelection() -> String? { nil }

    // MARK: selectableText

    /// Full text of the selection target. When `axRef` is supplied, read that
    /// element; otherwise the system-wide focused element. Tier-1 simple fields
    /// expose the whole text as `AXValue`; Tier-2 web/rich content exposes it via
    /// the document text-marker range (`AXStringForTextMarkerRange`). Throws when
    /// no selectable text can be read — read-only, never foregrounds (Inv 7).
    public func selectableText(axRef: AXElementRef?) throws -> String {
        guard let el = axElement(axRef) ?? focusedElement() else {
            throw AutomationError.ax("select_text: no target element and nothing focused.")
        }

        // Tier 1: the element's whole text is its AXValue string.
        if let value = copyStringAttribute(el, kAXValueAttribute as String), !value.isEmpty {
            return value
        }
        // Tier 2: the document text via its full marker range.
        if let text = fullTextViaMarkers(el), !text.isEmpty {
            return text
        }
        // A genuinely empty field still has selectable text ("" → caret at 0).
        if copyStringAttribute(el, kAXValueAttribute as String) != nil {
            return ""
        }
        throw AutomationError.ax("select_text: target element exposes no selectable text.")
    }

    // MARK: applySelection

    /// Apply a resolved selection (or zero-length caret) range to the target.
    /// Chooses Tier 1 (CFRange) vs Tier 2 (text markers) via the pure decider over
    /// the element's observed AX facts. Background-only: never focuses/raises (Inv 7).
    public func applySelection(axRef: AXElementRef?, range: MacCUACore.TextRange) throws {
        guard let el = axElement(axRef) ?? focusedElement() else {
            throw AutomationError.ax("select_text: no target element and nothing focused.")
        }

        let facts = SelectTextElementFacts(
            selectedTextRangeSettable: isSettable(el, kAXSelectedTextRangeAttribute as String),
            supportsTextMarkers: supportsTextMarkers(el),
            isWebArea: SelectTextTierDecider.isWebAreaRole(copyStringAttribute(el, kAXRoleAttribute as String)))

        switch SelectTextTierDecider.decide(facts) {
        case .cfRange:
            try applyCFRange(el, range: range)
        case .textMarker:
            try applyTextMarker(el, range: range)
        }
    }

    // MARK: - Tier 1 (CFRange)

    private func applyCFRange(_ el: AXUIElement, range: MacCUACore.TextRange) throws {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf) else {
            throw AutomationError.ax("select_text: could not build CFRange selection.")
        }
        let err = AXUIElementSetAttributeValue(
            el, kAXSelectedTextRangeAttribute as CFString, value)
        if err != .success {
            throw axError(Int(err.rawValue), context: "set AXSelectedTextRange")
        }
    }

    // MARK: - Tier 2 (text markers)

    private func applyTextMarker(_ el: AXUIElement, range: MacCUACore.TextRange) throws {
        guard let create = AXTextMarkerSPI.rangeCreate else {
            throw AutomationError.ax(
                "select_text: text-marker selection unavailable on this system.")
        }
        let (start, end) = SelectTextTierDecider.markerEndpoints(for: range)
        guard let startMarker = textMarker(el, forIndex: start),
              let endMarker = textMarker(el, forIndex: end) else {
            throw AutomationError.ax("select_text: could not build text markers for the range.")
        }
        guard let markerRange = create(nil, startMarker, endMarker)?.takeRetainedValue() else {
            throw AutomationError.ax("select_text: could not build the text-marker range.")
        }
        let err = AXUIElementSetAttributeValue(
            el, "AXSelectedTextMarkerRange" as CFString, markerRange)
        if err != .success {
            throw axError(Int(err.rawValue), context: "set AXSelectedTextMarkerRange")
        }
    }

    /// The text marker at a UTF-16 character index, via the parameterized
    /// `AXTextMarkerForIndex` attribute. Returns nil when the element does not
    /// vend markers (caller throws honestly).
    private func textMarker(_ el: AXUIElement, forIndex index: Int) -> CFTypeRef? {
        var idx = index
        guard let number = CFNumberCreate(nil, .longType, &idx) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, "AXTextMarkerForIndex" as CFString, number, &out)
        guard err == .success else { return nil }
        return out
    }

    /// The full document text via the element's `AXStartTextMarker` /
    /// `AXEndTextMarker` bracketing a marker range, then `AXStringForTextMarkerRange`.
    private func fullTextViaMarkers(_ el: AXUIElement) -> String? {
        guard let create = AXTextMarkerSPI.rangeCreate,
              let startMarker = copyRawAttribute(el, "AXStartTextMarker"),
              let endMarker = copyRawAttribute(el, "AXEndTextMarker"),
              let markerRange = create(nil, startMarker, endMarker)?.takeRetainedValue()
        else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, "AXStringForTextMarkerRange" as CFString, markerRange, &out)
        guard err == .success, let raw = out, CFGetTypeID(raw) == CFStringGetTypeID() else {
            return nil
        }
        return (raw as! String)
    }

    /// Does the element vend the text-marker family? Probed via the presence of
    /// `AXStartTextMarker` — the entry point for the Tier-2 mechanism.
    private func supportsTextMarkers(_ el: AXUIElement) -> Bool {
        copyRawAttribute(el, "AXStartTextMarker") != nil
    }

    // MARK: - CF helpers

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func copyStringAttribute(_ el: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! String)
    }

    private func copyRawAttribute(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success
            && settable.boolValue
    }
}
#endif
