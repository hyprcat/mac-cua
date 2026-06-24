// KitAccessibilityProvider.swift — real macOS AX read path (US-017).
//
// Backs the Core `AXTreeReader` seam with `AXUIElement*` framework calls and
// drives the pure preorder reverse-push DFS in `MacCUACore.AXWalk`. Reads only:
// no method here focuses, raises or activates (Invariant 7). Element refs are
// compared with `CFEqual` (Invariant: identity, not pointer ===). `-25205` /
// `-25212` surface as `AutomationError(.staleReference)` (Invariant 10).
//
// US-018 enriches the per-node attributes; US-020/021 add window-id binding and
// text geometry; the write path (perform/set) lands in US-036.

#if os(macOS)
import Foundation
import MacCUACore
import ApplicationServices
import CoreGraphics

// MARK: - Ref helpers

@inline(__always)
private func axElement(_ ref: AXElementRef?) -> AXUIElement? {
    (ref as? KitAXElementRef)?.element
}

// MARK: - Private ApplicationServices SPI (per-symbol-optional, dlsym-resolved)

/// `AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out)` — private,
/// returns the window id of an AX window/element directly (A4). Resolved once at
/// load via `dlsym(RTLD_DEFAULT,…)`; nil when the symbol is unavailable (e.g. a
/// future macOS SPI-removal), in which case callers fall back to bounds/title
/// matching. Resolving it does not call it — no side effects, never foregrounds.
enum AXPrivateSPI {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    static let getWindow: GetWindowFn? = {
        // RTLD_DEFAULT searches all loaded images (ApplicationServices is linked).
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}

// MARK: - CFType -> AXScalar normalization

private func axScalar(from value: CFTypeRef) -> AXScalar? {
    let typeID = CFGetTypeID(value)
    if typeID == CFStringGetTypeID() {
        return .string(value as! String)
    }
    if typeID == CFBooleanGetTypeID() {
        return .bool(CFBooleanGetValue((value as! CFBoolean)))
    }
    if typeID == CFNumberGetTypeID() {
        let num = value as! CFNumber
        if CFNumberIsFloatType(num) {
            var d = 0.0
            CFNumberGetValue(num, .doubleType, &d)
            return .double(d)
        }
        var i = 0
        CFNumberGetValue(num, .longType, &i)
        return .int(i)
    }
    // AXValue (geometry/range), AXUIElement, arrays, AX error values, etc. are
    // not scalar attributes — the walk reads children/geometry via dedicated
    // paths, so skip them here.
    return nil
}

/// Detect a batch AX-error entry via the proper SPI `AXValueGetType(v) == .axError`
/// instead of Python's string-sniffing hack (SWIFT_PORT_DESIGN §A3 / line 251).
private func isAXErrorValue(_ value: CFTypeRef) -> Bool {
    guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
    return AXValueGetType((value as! AXValue)) == .axError
}

private func urlString(_ value: CFTypeRef?) -> String? {
    guard let value else { return nil }
    if CFGetTypeID(value) == CFURLGetTypeID() {
        return (value as! URL).absoluteString
    }
    if CFGetTypeID(value) == CFStringGetTypeID() {
        return (value as! String)
    }
    return nil
}

// MARK: - The reader

/// AX-framework-backed `AXTreeReader`. One per walk; cheap to construct.
private final class KitAXTreeReader: AXTreeReader {
    func readAttributes(_ element: AXElementRef) -> AXAttributes {
        guard let el = axElement(element) else { return AXAttributes() }
        var out: [String: AXScalar] = [:]
        var rawValues: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, AXAttr.batch as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &rawValues)
        guard err == .success, let values = rawValues as? [CFTypeRef] else {
            return AXAttributes()
        }
        for (i, attr) in AXAttr.batch.enumerated() where i < values.count {
            // `AXChildren` is read on the dedicated child path, not as a scalar.
            if attr == AXAttr.children { continue }
            // Skip batch AX-error entries (detected via AXValueGetType, Inv/§A3).
            if isAXErrorValue(values[i]) { continue }
            if let scalar = axScalar(from: values[i]) { out[attr] = scalar }
        }
        return AXAttributes(out)
    }

    func rawActionNames(_ element: AXElementRef) -> [String] {
        guard let el = axElement(element) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let arr = names as? [String] else { return [] }
        return arr
    }

    func isValueSettable(_ element: AXElementRef) -> Bool {
        isSettable(element, kAXValueAttribute as String)
    }

    func isSelectedSettable(_ element: AXElementRef) -> Bool {
        isSettable(element, kAXSelectedAttribute as String)
    }

    private func isSettable(_ element: AXElementRef, _ attr: String) -> Bool {
        guard let el = axElement(element) else { return false }
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(el, attr as CFString, &settable)
        return err == .success && settable.boolValue
    }

    func childrenForWalk(_ element: AXElementRef, attrs: AXAttributes, role: String) -> [AXElementRef] {
        guard let el = axElement(element) else { return [] }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &value)
        guard err == .success, let raw = value, CFGetTypeID(raw) == CFArrayGetTypeID(),
              let arr = raw as? [AXUIElement] else { return [] }
        return arr.map { KitAXElementRef($0) }
    }

    func elementPid(_ element: AXElementRef) -> Int? {
        guard let el = axElement(element) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? Int(pid) : nil
    }

    func linkURL(_ element: AXElementRef) -> String? {
        guard let el = axElement(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &value) == .success
        else { return nil }
        return urlString(value)
    }
}

// MARK: - Provider

public final class KitAccessibilityProvider: AccessibilityProvider {
    private let reader = KitAXTreeReader()
    private let assertions = AssertionTracker()
    /// Per-app remembered/reversible enhanced-UI state (A1, US-019).
    private let enhancedUI = EnhancedUITracker()

    public init() {}

    // MARK: Enhanced UI (A1) — Chromium/Electron tree enablement

    private static let enhancedUIAttr = "AXEnhancedUserInterface"
    private static let manualAccessibilityAttr = "AXManualAccessibility"

    /// Set `AXEnhancedUserInterface` + `AXManualAccessibility` = true on the
    /// AXApplication element so Chromium/Electron expose their tree. Remembered
    /// per-app (set at most once), reversible (prior values captured), logged. A
    /// sanctioned app-config write — it never focuses/raises/activates (Inv 7).
    @discardableResult
    public func enableEnhancedUI(axApp: AXElementRef, pid: Int) throws -> Bool {
        if enhancedUI.isEnabled(pid: pid) { return false }
        guard let app = axElement(axApp) else { return false }

        // Capture prior values so a teardown can restore them (reversible).
        let prior = EnhancedUITracker.PriorState(
            enhancedUI: readBool(app, Self.enhancedUIAttr),
            manualAccessibility: readBool(app, Self.manualAccessibilityAttr))

        AXUIElementSetAttributeValue(app, Self.enhancedUIAttr as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, Self.manualAccessibilityAttr as CFString, kCFBooleanTrue)

        enhancedUI.markEnabled(pid: pid, prior: prior)
        FileHandle.standardError.write(Data(
            "[mac-cua] enabled enhanced UI for pid \(pid) (prior: \(prior))\n".utf8))
        return true
    }

    /// Restore the captured prior enhanced-UI attribute values for a pid, if any
    /// (reversible teardown). No-op if never enabled or the app is gone.
    public func disableEnhancedUI(axApp: AXElementRef, pid: Int) {
        guard let prior = enhancedUI.markDisabled(pid: pid),
              let app = axElement(axApp) else { return }
        if let v = prior.enhancedUI {
            AXUIElementSetAttributeValue(app, Self.enhancedUIAttr as CFString,
                                         v ? kCFBooleanTrue : kCFBooleanFalse)
        }
        if let v = prior.manualAccessibility {
            AXUIElementSetAttributeValue(app, Self.manualAccessibilityAttr as CFString,
                                         v ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    private func readBool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((raw as! CFBoolean))
    }

    // MARK: Tree (reads)

    public func walkTree(
        axElement root: AXElementRef, targetPid: Int?, maxDepth: Int, maxNodes: Int,
        includeActions: Bool, includeStates: Bool
    ) throws -> [Node] {
        guard axElement(root) != nil else { return [] }
        let body: () -> [Node] = {
            AXWalk.walk(
                root: root, reader: self.reader, targetPid: targetPid,
                maxDepth: maxDepth, maxNodes: maxNodes,
                includeActions: includeActions, includeStates: includeStates)
        }
        // Ref-counted READ assertion, balanced even on throw (Invariant 11).
        if let pid = targetPid {
            return assertions.withAssertion(pid: pid, kind: .readAttributes, body)
        }
        return body()
    }

    public func getKeyWindow(axApp: AXElementRef) -> AXElementRef? {
        guard let app = axElement(axApp) else { return nil }
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = copyRef(app, attr as String) { return w }
        }
        if let windows = copyRefArray(app, kAXWindowsAttribute as String), let first = windows.first {
            return first
        }
        return nil
    }

    public func getWindows(axApp: AXElementRef) -> [AXElementRef] {
        guard let app = axElement(axApp) else { return [] }
        var windows = copyRefArray(app, kAXWindowsAttribute as String) ?? []
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let w = copyRef(app, attr as String) else { continue }
            if windows.contains(where: { refsEqual($0, w) }) { continue }
            windows.insert(w, at: 0)
        }
        return windows
    }

    public func getMenuBar(axApp: AXElementRef) -> AXElementRef? {
        guard let app = axElement(axApp) else { return nil }
        return copyRef(app, "AXMenuBar")
    }

    public func getWindowTitle(axWindow: AXElementRef) -> String? {
        getAttributeValue(axWindow, kAXTitleAttribute as String)
    }

    // MARK: Element queries (reads)

    /// Direct AX-element → CGWindowID via the private `_AXUIElementGetWindow`
    /// SPI (A4). Resolved per-symbol-optional at runtime: when absent, returns
    /// nil and the caller falls back to bounds/title matching. Read-only.
    public func windowIdForElement(_ axRef: AXElementRef) -> Int? {
        guard let el = axElement(axRef) else { return nil }
        guard let fn = AXPrivateSPI.getWindow else { return nil }
        var wid: CGWindowID = 0
        let err = fn(el, &wid)
        guard err == .success, wid != 0 else { return nil }
        return Int(wid)
    }

    public func getFocusedElement(axApp: AXElementRef, tree: [Node]) -> Int? {
        guard let app = axElement(axApp),
              let focused = copyRef(app, kAXFocusedUIElementAttribute as String) else { return nil }
        for node in tree where node.axRef != nil {
            if refsEqual(node.axRef, focused) { return node.index }
        }
        return nil
    }

    public func getElementFrame(node: Node) -> Rect? {
        guard let el = axElement(node.axRef) else { return nil }
        guard let pos = copyAXPoint(el, kAXPositionAttribute as String),
              let size = copyAXSize(el, kAXSizeAttribute as String) else { return nil }
        return Rect(x: pos.0, y: pos.1, w: size.0, h: size.1)
    }

    public func elementAtPosition(axApp: AXElementRef, x: Double, y: Double) -> AXElementRef? {
        guard let app = axElement(axApp) else { return nil }
        var out: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(app, Float(x), Float(y), &out)
        guard err == .success, let el = out else { return nil }
        return KitAXElementRef(el)
    }

    public func getPid(axElement ref: AXElementRef) -> Int? {
        reader.elementPid(ref)
    }

    public func refsEqual(_ a: AXElementRef?, _ b: AXElementRef?) -> Bool {
        switch (axElement(a), axElement(b)) {
        case let (l?, r?): return CFEqual(l, r)
        case (nil, nil): return a === b
        default: return false
        }
    }

    public func nodeFromRef(_ element: AXElementRef, depth: Int, index: Int) throws -> Node {
        // Walk a single element (no descent) and re-stamp index/depth.
        let nodes = AXWalk.walk(
            root: element, reader: reader, targetPid: nil,
            maxDepth: 0, maxNodes: 1, includeActions: true, includeStates: true)
        guard let node = nodes.first else {
            throw AutomationError.staleReference("nodeFromRef: element produced no node")
        }
        node.index = index
        node.depth = depth
        return node
    }

    public func getActionNamesForRef(_ element: AXElementRef) -> [String] {
        reader.rawActionNames(element)
    }

    public func getParentRef(_ element: AXElementRef) -> AXElementRef? {
        guard let el = axElement(element) else { return nil }
        return copyRef(el, kAXParentAttribute as String)
    }

    public func getChildren(_ element: AXElementRef) -> [AXElementRef] {
        reader.childrenForWalk(element, attrs: AXAttributes(), role: "")
    }

    public func hasScrollbarRef(_ element: AXElementRef) -> Bool {
        guard let el = axElement(element) else { return false }
        for attr in ["AXVerticalScrollBar", "AXHorizontalScrollBar"] {
            if copyRef(el, attr) != nil { return true }
        }
        return false
    }

    public func getAttributeValue(_ element: AXElementRef, _ attr: String) -> String? {
        guard let el = axElement(element) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let raw = value else { return nil }
        if let scalar = axScalar(from: raw) { return AXWalkLogic.cleanText(scalar) }
        if CFGetTypeID(raw) == CFURLGetTypeID() { return urlString(raw) }
        return nil
    }

    public func isAttributeSettable(node: Node, _ attr: String) -> Bool {
        guard let el = axElement(node.axRef) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success
            && settable.boolValue
    }

    // MARK: Text geometry (A5, US-021) — parameterized attributes

    public func boundsForTextRange(node: Node, range: MacCUACore.TextRange) -> Rect? {
        guard let el = axElement(node.axRef) else { return nil }
        var cf = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cf) else { return nil }
        guard let v = copyParameterizedAXValue(
            el, "AXBoundsForRange" as CFString, param) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v, .cgRect, &rect) else { return nil }
        return Rect(x: Double(rect.origin.x), y: Double(rect.origin.y),
                    w: Double(rect.size.width), h: Double(rect.size.height))
    }

    public func rangeForTextPosition(node: Node, x: Double, y: Double) -> MacCUACore.TextRange? {
        guard let el = axElement(node.axRef) else { return nil }
        var pt = CGPoint(x: x, y: y)
        guard let param = AXValueCreate(.cgPoint, &pt) else { return nil }
        guard let v = copyParameterizedAXValue(
            el, "AXRangeForPosition" as CFString, param) else { return nil }
        var cf = CFRange(location: 0, length: 0)
        guard AXValueGetValue(v, .cfRange, &cf) else { return nil }
        return MacCUACore.TextRange(location: cf.location, length: cf.length)
    }

    public func visibleTextRange(node: Node) -> MacCUACore.TextRange? {
        guard let el = axElement(node.axRef),
              let v = copyAXValue(el, "AXVisibleCharacterRange") else { return nil }
        var cf = CFRange(location: 0, length: 0)
        guard AXValueGetValue(v, .cfRange, &cf) else { return nil }
        return MacCUACore.TextRange(location: cf.location, length: cf.length)
    }

    // MARK: Writes (US-036) — pure-AX actions + typed attribute sets

    /// Perform an AX action on a Node (ports `accessibility.perform_action`).
    /// Ref-counts a `performActions` assertion (balanced even on throw), maps
    /// `-25205`/`-25212` to a stale-reference error (Inv 10), and NEVER focuses,
    /// raises or activates — `AXUIElementPerformAction` acts on the app's own
    /// element tree without touching the window stack (Prime Invariant / Inv 7).
    public func performAction(node: Node, action: String) throws {
        guard let el = axElement(node.axRef) else {
            throw AutomationError.ax("Node has no AX reference")
        }
        let pid = node.elementPid
        try withWriteAssertion(pid: pid, kind: .performActions) {
            let err = AXUIElementPerformAction(el, action as CFString)
            if err != .success {
                throw axError(Int(err.rawValue), context: "perform action \(action)")
            }
        }
    }

    /// Perform an AX action on a raw element ref (no Node wrapper, no assertion —
    /// ports `accessibility.perform_action_on_ref`). Used by hit-test paths that
    /// already hold the element directly.
    public func performActionOnRef(_ axRef: AXElementRef, action: String) throws {
        guard let el = axElement(axRef) else {
            throw AutomationError.ax("No AX reference")
        }
        let err = AXUIElementPerformAction(el, action as CFString)
        if err != .success {
            throw axError(Int(err.rawValue), context: "perform action \(action)")
        }
    }

    /// Set an AX attribute on a Node (ports `accessibility.set_attribute`).
    /// Ref-counts a `writeAttributes` assertion, coerces the string value to the
    /// AX-typed CFTypeRef via the pure `AXAttributeWrite.classify` (booleans →
    /// CFBoolean, AXSelectedText/VisibleCharacterRange → AXValue `.cfRange`, else
    /// CFString — the "AXValue-typed ranges" of the story), and maps stale codes.
    /// Pure-AX: never focuses/raises (the optional focus step lives in the spine
    /// handler, gated, AFTER this throws).
    public func setAttribute(node: Node, _ attr: String, _ value: String) throws {
        guard let el = axElement(node.axRef) else {
            throw AutomationError.ax("Node has no AX reference")
        }
        let cfValue = Self.cfValue(for: AXAttributeWrite.classify(attr: attr, value: value))
        let pid = node.elementPid
        try withWriteAssertion(pid: pid, kind: .writeAttributes) {
            let err = AXUIElementSetAttributeValue(el, attr as CFString, cfValue)
            if err != .success {
                throw axError(Int(err.rawValue), context: "set attribute \(attr)")
            }
        }
    }

    /// Map the pure `AXWriteValue` classification onto the concrete CFTypeRef the
    /// AX framework expects.
    private static func cfValue(for v: AXWriteValue) -> CFTypeRef {
        switch v {
        case let .string(s):
            return s as CFString
        case let .boolean(b):
            return b ? kCFBooleanTrue : kCFBooleanFalse
        case let .range(location, length):
            var cf = CFRange(location: location, length: length)
            if let ax = AXValueCreate(.cfRange, &cf) { return ax }
            // Extremely unlikely; degrade to a string the framework will reject
            // honestly rather than crash.
            return "\(location),\(length)" as CFString
        }
    }

    /// Run `body` holding a PID-scoped write/action assertion, balanced even on
    /// throw. When the element has no resolvable pid we still perform the write
    /// (matches Python: the assertion is skipped, the AX call is not).
    private func withWriteAssertion(
        pid: Int?, kind: AXEnablementKind, _ body: () throws -> Void
    ) throws {
        guard let pid else { try body(); return }
        try assertions.withAssertion(pid: pid, kind: kind, body)
    }

    // MARK: Editable text + content extraction (US-033 / US-040 / US-046)

    public func makeEditableText(element: AXElementRef, pid: Int?) -> EditableText? { nil }
    public func extractWebAreaText(_ element: AXElementRef, targetPid: Int?) -> String? { nil }
    public func extractTextAreaContent(_ element: AXElementRef, targetPid: Int?) -> String? { nil }

    public func getWebURL(_ element: AXElementRef) -> String? {
        reader.linkURL(element)
    }

    // MARK: - Private CF helpers

    private func copyRef(_ el: AXUIElement, _ attr: String) -> AXElementRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return KitAXElementRef((raw as! AXUIElement))
    }

    private func copyRefArray(_ el: AXUIElement, _ attr: String) -> [AXElementRef]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == CFArrayGetTypeID(),
              let arr = raw as? [AXUIElement] else { return nil }
        return arr.map { KitAXElementRef($0) }
    }

    private func copyAXPoint(_ el: AXUIElement, _ attr: String) -> (Double, Double)? {
        guard let v = copyAXValue(el, attr) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? (Double(p.x), Double(p.y)) : nil
    }

    private func copyAXSize(_ el: AXUIElement, _ attr: String) -> (Double, Double)? {
        guard let v = copyAXValue(el, attr) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? (Double(s.width), Double(s.height)) : nil
    }

    private func copyAXValue(_ el: AXUIElement, _ attr: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }

    private func copyParameterizedAXValue(
        _ el: AXUIElement, _ attr: CFString, _ param: AXValue
    ) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, attr, param, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        return (raw as! AXValue)
    }
}
#endif
