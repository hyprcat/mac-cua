import Foundation
import MacCUACore

// ACTION HANDLERS — the 8 tools' delivery logic + their click/scroll/input/
// verification helpers. Each handler returns a success string or throws an
// `AutomationError`; the spine's execute() turns that into a snapshot response.
//
// This is a faithful Swift port of the `_handle_*` methods and their helpers in
// `app/session.py` (~lines 1074-3672). All effects flow through `providers.input`
// / `providers.accessibility` and the per-session monitors on `AppSession`; this
// file never names a framework type, so it builds and unit-tests on Linux.
//
// Adaptations from the Python source (documented per-site below):
//   - The Python event-driven verification monitors (`begin_action()` returning a
//     tuple, `verify_transport(start_sequence:expectation:timeout:)`) collapse onto
//     the simplified Core `OutcomeMonitor` seam: `mark() -> Int`,
//     `verifyAX(contract:mark:timeout:)`, `verifyTransport(startSequence:timeout:)`.
//   - The `confirmed_delivery` / `delivery_tap` pipeline is not part of the Core
//     seam, so input always goes through the plain `providers.input` calls (same
//     effect: CGEventPostToPid per-pid, Invariant 1).
//   - The transient-graph registry (`_active_graph`, `_resolve_locator_in_graph`,
//     `pushTransient`) is spine-owned; the only spine method these helpers may call
//     is `resolveIndex`. `makeTransientSource` therefore builds a `TransientSource`
//     from the node's own `graphLocator` and stores it on
//     `session.pendingTransientSource` for the spine to consume.
//
// The only spine method called is `resolveIndex(_:_:)`. Every other helper is
// self-contained in this file.

extension SessionManager {

    // MARK: - click (session.py:2717)

    /// Click via background CGEvent, with AX fallbacks. Ports `_handle_click`.
    ///
    /// By element: InputStrategy decides AX-first vs pointer-first ordering. AX-first
    /// tries AX action then AX hit-test then CGEvent; pointer-first tries CGEvent then
    /// AX hit-test then AX action (Invariants 1, 9). By coords: AX hit-test → CGEvent
    /// → AX hit-test fallback. The OOP pid is resolved per-node (Invariant 9) and the
    /// click point is the visible intersection of the element with the window.
    func handleClick(_ session: AppSession, _ params: [String: Any]) throws -> String {
        let t = session.target
        let count = intParam(params["click_count"], default: 1)
        let button = stringParam(params["mouse_button"], default: "left")

        if let idx = elementIndex(params) {
            let node = try resolveIndex(session, idx)
            // Glide the decorative ghost to the element first, so it moves to the
            // target regardless of which delivery path (AX-press / hit-test /
            // background CGEvent) ultimately handles the click. The pointer shape
            // matches the element (hand over buttons/links, I-beam over text).
            if let p = clickPointForNode(session, node) {
                noteCursor(session, p, kind: cursorKind(for: node))
            }
            // Pre-click AX signature, so a delivered-but-unverified click can be
            // confirmed by re-walking and detecting a real UI change (Option A).
            let beforeSig = treeSignature(session.refetchableTree?.nodes ?? session.treeNodes)
            let preferPointer = shouldPreferPointerInput(session, node)
            if !preferPointer {
                if let r = tryAXClickNode(session, node, idx, button: button, count: count) { return r }
                if let r = tryAXHitTestClick(session, node, idx, button: button, count: count) { return r }
            }
            var bgDelivered = false
            if backgroundClickNode(session, node, button: button, count: count) {
                return "Clicked element \(idx) (CGEventPostToPid)"
            } else {
                // Captured immediately: later AX fallbacks below may overwrite the
                // shared verdict. `.noEffect` means the CGEvent was delivered but
                // its effect couldn't be observed by the verifier.
                bgDelivered = session.lastActionVerification == .noEffect
            }
            if preferPointer {
                if let r = tryAXHitTestClick(session, node, idx, button: button, count: count) { return r }
                if let r = tryAXClickNode(session, node, idx, button: button, count: count) { return r }
            }
            // Option A + AX re-walk: a click can be delivered while its verifier
            // can't observe the effect (AX-press on an action button like "New
            // Tab", or a background CGEvent). Cheap signal first — if the action
            // already invalidated the tree (the settle monitor saw AX changes),
            // the click had an effect, no extra walk needed. Only when the monitor
            // is quiet do we force ONE re-walk and compare signatures.
            let effected: Bool
            if session.refetchableTree?.isInvalidated == true {
                effected = true
            } else {
                let afterSig = treeSignature(session.refetchableTree?.forceRewalk() ?? session.treeNodes)
                session.didForceRewalkThisAction = true
                effected = afterSig != beforeSig
            }
            if effected {
                return "Clicked element \(idx) (effect confirmed via AX re-walk)"
            }
            // Delivered (transport confirmed) but no observable effect — report
            // honestly rather than as a hard failure.
            if bgDelivered {
                return "Clicked element \(idx) (delivered, effect unverified)"
            }
            throw AutomationError.automation(
                "Click failed for element \(idx). "
                + "Try a different element or use perform_secondary_action."
            )
        } else if let x = doubleParam(params["x"]), let y = doubleParam(params["y"]) {
            let (sx, sy) = toScreenCoords(session, t.windowId, x, y)
            noteCursor(session, Point(x: sx, y: sy))
            if let r = tryAXHitTestClickAtPoint(
                session, sx, sy, displayX: x, displayY: y, button: button, count: count
            ) { return r }

            // US-060: known canvas/foreground-only surfaces (Blender/Unity/games)
            // only accept events after a foreground activation — forbidden by the
            // Prime Invariant (Inv 18). AX had its chance above; refuse the doomed
            // pixel click loudly instead of dropping it silently. Conservative —
            // fires only on known-canvas bundle ids/engine prefixes.
            if CanvasSurfaceHeuristic.isLikelyCanvasSurface(
                SurfaceDescriptor(bundleId: t.bundleId, axRoleCount: session.treeNodes.count)) {
                throw UnsupportedSurfaceError.canvasSurface(detail: t.bundleId)
            }

            // US-057: Chromium user-activation primer, scoped to web-content pixel
            // clicks (browser/electron). Reaching here means the AX hit-test above
            // found no actionable target — a true coordinate/pixel click.
            let primeClick = ClickPrimerPolicy.shouldPrime(
                surface: session.appType, clickKind: .pixel, flagEnabled: flags.clickPrimer)

            do {
                try providers.input.clickAt(
                    pid: t.windowPid, windowId: t.windowId, x: x, y: y,
                    button: button, count: count,
                    screenshotSize: session.screenshotSize, source: session.eventSource,
                    prime: primeClick
                )
                return "Clicked at (\(fmt(x)), \(fmt(y))) (CGEventPostToPid)"
            } catch let exc as AutomationError where exc.isInputError {
                // Refresh window + retry once (matches Python InputError recovery).
                refreshWindow(session)
                let t2 = session.target
                let beforeCoord = captureElementSnapshot(session, nil)
                do {
                    let transportMark = session.cgeventOutcomeMonitor?.mark() ?? 0
                    try providers.input.clickAt(
                        pid: t2.windowPid, windowId: t2.windowId, x: x, y: y,
                        button: button, count: count,
                        screenshotSize: session.screenshotSize, source: session.eventSource,
                        prime: primeClick
                    )
                    let afterCoord = captureElementSnapshot(session, nil)
                    computeDeliveryVerdict(
                        session, before: beforeCoord, after: afterCoord,
                        transportConfirmed: verifyTransport(session, startSequence: transportMark),
                        fallbackUsed: false, expected: .focusOrLayout
                    )
                    return "Clicked at (\(fmt(x)), \(fmt(y))) (CGEventPostToPid, refreshed window)"
                } catch {
                    // fall through to AX hit-test
                }
            }

            if let r = tryAXHitTestClickAtPoint(
                session, sx, sy, displayX: x, displayY: y, button: button, count: count
            ) { return r }

            var failMsg = "Click failed at (\(fmt(x)), \(fmt(y))). "
                + "Use get_app_state and retry with a fresh screenshot or click by element_index."
            // US-060: a tree-less surface that drops a pixel click may be an
            // unsupported canvas/foreground-only surface — hint, don't assert.
            if session.treeNodes.isEmpty {
                failMsg += " " + CanvasSurfaceHeuristic.noEffectHint(
                    SurfaceDescriptor(bundleId: t.bundleId, axRoleCount: 0))
            }
            throw AutomationError.automation(failMsg)
        } else {
            throw AutomationError.automation(
                "click requires either element_index or both x and y coordinates"
            )
        }
    }

    // MARK: - type_text (session.py:2904)

    /// Type text via background key events, optionally targeting an element.
    /// Ports `_handle_type_text`. For text elements, tries `EditableText.insertText`
    /// (AX) first, then focuses the node for keyboard input and delivers via CGEvent
    /// `providers.input.typeText` (Invariants 1, 9).
    func handleTypeText(_ session: AppSession, _ params: [String: Any]) throws -> String {
        let text = stringParam(params["text"], default: "")
        let t = session.target
        let elIdx = elementIndex(params)
        var node: Node?

        if let elIdx {
            let n = try resolveIndex(session, elIdx)
            node = n
            // Glide the ghost (I-beam over text) to the field being typed into.
            if let p = clickPointForNode(session, n) {
                noteCursor(session, p, kind: cursorKind(for: n))
            }
            if n.axRole == "AXTextField" || n.axRole == "AXTextArea", let ref = n.axRef {
                let mark = session.axOutcomeMonitor?.mark()
                if let eto = providers.accessibility.makeEditableText(element: ref, pid: n.elementPid) {
                    do {
                        try eto.insertText(text)
                        let verification = verifyAXContract(
                            session,
                            contract: VerificationContract(directVerifier: sendableVerifier { [providers] in
                                providers.accessibility.makeEditableText(element: ref, pid: n.elementPid)?
                                    .text.contains(text) ?? false
                            }),
                            mark: mark
                        )
                        if verification == .confirmed || verification == .transientOpened {
                            return "Typed \(repr(text)) into element \(elIdx) (EditableTextObject.insertText)"
                        }
                    } catch {
                        // fall through to focus + CGEvent typing
                    }
                }
            }

            if !focusNodeForKeyboardInput(session, n) {
                throw AutomationError.automation(
                    "Cannot target element \(elIdx) for typing without activating the app. "
                    + "Try set_value instead."
                )
            }
        }

        let inputPid = backgroundPidForNode(session, node)
        try providers.input.typeText(pid: inputPid, text: text, source: session.eventSource)
        if elIdx == nil {
            _ = t
            return "Typed \(repr(text)) into the current focused element"
        }
        return "Typed \(repr(text)) into element \(elIdx!) (background key events)"
    }

    // MARK: - set_value (session.py:2993)

    /// Set value — pure AX. Ports `_handle_set_value`.
    /// `EditableText.setText` → `setAttribute AXValue` → background focus + retry.
    func handleSetValue(_ session: AppSession, _ params: [String: Any]) throws -> String {
        guard let idx = elementIndex(params) else {
            throw AutomationError.automation("set_value requires element_index")
        }
        let node = try resolveIndex(session, idx)
        let value = stringParam(params["value"], default: "")
        let insertMode = boolParam(params["insert"], default: false)

        // Read-back BEFORE any set attempt. The exact-equality verifiers below
        // can miss legitimate successes when the field augments/normalises the
        // value (e.g. Safari autocomplete completion, multi-line or em-dash
        // normalisation). Capturing the prior text lets the final verdict
        // recognise a "delivered + changed" outcome (Option A).
        let beforeText: String? = node.axRef.flatMap {
            providers.accessibility.makeEditableText(element: $0, pid: node.elementPid)?.text
        }

        // --- EditableText for text elements ---
        if node.axRole == "AXTextField" || node.axRole == "AXTextArea", let ref = node.axRef {
            let mark = session.axOutcomeMonitor?.mark()
            if let eto = providers.accessibility.makeEditableText(element: ref, pid: node.elementPid) {
                do {
                    if insertMode {
                        try eto.insertText(value)
                        let v = verifyAXContract(
                            session,
                            contract: VerificationContract(directVerifier: sendableVerifier { [providers] in
                                providers.accessibility.makeEditableText(element: ref, pid: node.elementPid)?
                                    .text.contains(value) ?? false
                            }),
                            mark: mark
                        )
                        if v == .confirmed || v == .transientOpened {
                            return "Inserted text into element \(idx) (EditableTextObject.insertText)"
                        }
                    } else {
                        try eto.setText(value)
                        let v = verifyAXContract(
                            session,
                            contract: VerificationContract(directVerifier: sendableVerifier { [providers] in
                                providers.accessibility.makeEditableText(element: ref, pid: node.elementPid)?
                                    .text == value
                            }),
                            mark: mark
                        )
                        if v == .confirmed || v == .transientOpened {
                            return "Set value of element \(idx) to \(repr(value)) (EditableTextObject.setText)"
                        }
                    }
                } catch {
                    // fall through to direct AX attribute set
                }
            }
        }

        // --- Primary: direct AX attribute set ---
        do {
            let mark = session.axOutcomeMonitor?.mark()
            try providers.accessibility.setAttribute(node: node, "AXValue", value)
            let v = verifyAXContract(
                session,
                contract: VerificationContract(directVerifier: sendableVerifier { [providers] in
                    guard let ref = node.axRef else { return false }
                    return providers.accessibility.makeEditableText(element: ref, pid: node.elementPid)?
                        .text == value
                }),
                mark: mark
            )
            if v == .confirmed || v == .transientOpened {
                return "Set value of element \(idx) to \(repr(value)) (AXValue)"
            }
        } catch {
            // fall through to focus + retry
        }

        // --- Background focus + retry ---
        if backgroundClickNode(session, node) {
            do {
                let mark = session.axOutcomeMonitor?.mark()
                try providers.accessibility.setAttribute(node: node, "AXValue", value)
                let v = verifyAXContract(
                    session,
                    contract: VerificationContract(directVerifier: sendableVerifier { [providers] in
                        guard let ref = node.axRef else { return false }
                        return providers.accessibility.makeEditableText(element: ref, pid: node.elementPid)?
                            .text == value
                    }),
                    mark: mark
                )
                if v == .confirmed || v == .transientOpened {
                    return "Set value of element \(idx) to \(repr(value)) (focus + AXValue)"
                }
            } catch {
                // fall through to error
            }
        }

        // Option A + AX re-walk: no exact-equality verifier confirmed, but the
        // value may still have been applied (the live read-back lags a programmatic
        // AXValue set — see RefetchableTree.forceRewalk). Force a fresh re-walk and
        // read the element's current value from it, then accept as success if the
        // field now equals the value OR changed from its pre-set content; otherwise
        // report UNVERIFIED (not a hard failure).
        let afterText = freshNodeText(session, node)
        if let afterText, afterText == value || afterText != (beforeText ?? "") {
            return "Set value of element \(idx) to \(repr(value)) "
                + "(verified via AX re-walk, read-back=\(repr(afterText)))"
        }
        return "set_value delivered to element \(idx) but the change could not be "
            + "verified after an AX re-walk (read-back unchanged). The element may "
            + "not expose its value via AX (e.g. some browser fields); the set may "
            + "still have applied."
    }

    /// Stable content signature of a node list, used to detect whether a mutating
    /// action actually changed the UI. Deliberately ignores volatile fields
    /// (focus/selection states, geometry, cursor) so a mere focus change does not
    /// read as an effect — only structural/value/label changes count.
    private func treeSignature(_ nodes: [Node]) -> Int {
        var hasher = Hasher()
        hasher.combine(nodes.count)
        for n in nodes {
            hasher.combine(n.role)
            hasher.combine(n.value ?? "")
            hasher.combine(n.label ?? "")
            hasher.combine(n.description ?? "")
        }
        return hasher.finalize()
    }

    /// Force a fresh AX re-walk and return the current text of `node` (matched by
    /// its AX handle in the rewalked tree, falling back to a live read). Used by
    /// set_value verification, where the cached/live read-back lags a programmatic
    /// AXValue set.
    private func freshNodeText(_ session: AppSession, _ node: Node) -> String? {
        let fresh = session.refetchableTree?.forceRewalk()
        session.didForceRewalkThisAction = true
        if let fresh, let ref = node.axRef {
            if let match = fresh.first(where: {
                providers.accessibility.refsEqual($0.axRef, ref)
            }) {
                return match.value ?? match.selectedText
            }
        }
        return node.axRef.flatMap {
            providers.accessibility.makeEditableText(element: $0, pid: node.elementPid)?.text
        }
    }

    // MARK: - press_key (session.py:3096)

    /// Press a key via background key events, optionally targeting an element.
    /// Ports `_handle_press_key`. Element-targeted Return/Enter/Escape map to AX
    /// actions (`keyToAXAction`) first; otherwise focus the element and deliver via
    /// CGEvent `providers.input.pressKey` (modifiers ride as flags — Invariant 3).
    func handlePressKey(_ session: AppSession, _ params: [String: Any]) throws -> String {
        let t = session.target
        guard let key = params["key"].flatMap({ $0 as? String }) else {
            throw AutomationError.automation("press_key requires a key")
        }
        let elIdx = elementIndex(params)
        var node: Node?

        if let elIdx {
            let n = try resolveIndex(session, elIdx)
            node = n

            if let axKeyAction = keyToAXAction[key.lowercased()] {
                do {
                    let mark = session.axOutcomeMonitor?.mark()
                    try providers.accessibility.performAction(node: n, action: axKeyAction)
                    let expectClose = key.lowercased() == "escape" && session.menuTracker?.menusOpen == true
                    let v = verifyAXContract(
                        session,
                        contract: VerificationContract(expectTransientClose: expectClose),
                        mark: mark
                    )
                    if v == .confirmed || v == .transientClosed {
                        return "Pressed \(key) on element \(elIdx) (\(axKeyAction))"
                    }
                } catch {
                    // fall through to focus + CGEvent
                }
            }

            if !focusNodeForKeyboardInput(session, n) {
                throw AutomationError.automation(
                    "Cannot target element \(elIdx) for key input without activating the app."
                )
            }
        }

        let inputPid = backgroundPidForNode(session, node)
        try providers.input.pressKey(pid: inputPid, key: key, source: session.eventSource)
        if elIdx == nil {
            return "Pressed \(key) in \(t.bundleId) (background key event)"
        }
        return "Pressed \(key) on element \(elIdx!) (background key event)"
    }

    // MARK: - drag (session.py:3185)

    /// Drag via background-targeted mouse events. Ports `_handle_drag`.
    /// Pure CGEvent `providers.input.drag`; on `InputError`, refresh window and
    /// retry once. No cursor warp (Invariant 2 — delivery is per-pid synthetic).
    func handleDrag(_ session: AppSession, _ params: [String: Any]) throws -> String {
        let t = session.target
        let fromX = doubleParam(params["from_x"]) ?? 0
        let fromY = doubleParam(params["from_y"]) ?? 0
        let toX = doubleParam(params["to_x"]) ?? 0
        let toY = doubleParam(params["to_y"]) ?? 0
        noteCursor(session, Point(x: toX, y: toY))

        do {
            try providers.input.drag(
                pid: t.windowPid, windowId: t.windowId,
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                screenshotSize: session.screenshotSize, source: session.eventSource
            )
        } catch let exc as AutomationError where exc.isInputError {
            refreshWindow(session)
            let t2 = session.target
            try providers.input.drag(
                pid: t2.windowPid, windowId: t2.windowId,
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                screenshotSize: session.screenshotSize, source: session.eventSource
            )
        }
        return "Dragged from (\(fmt(fromX)), \(fmt(fromY))) to (\(fmt(toX)), \(fmt(toY)))"
    }

    // MARK: - perform_secondary_action (session.py:3233)

    /// Perform a secondary action — pure AX. Ports `_handle_secondary_action`.
    /// Sets transient expectations (menu/popover open/close), then falls back to
    /// AXPress for non-strict actions (`strictSecondaryActions` is the exclusion set).
    func handleSecondaryAction(_ session: AppSession, _ params: [String: Any]) throws -> String {
        guard let idx = elementIndex(params) else {
            throw AutomationError.automation("perform_secondary_action requires element_index")
        }
        let node = try resolveIndex(session, idx)
        guard let action = params["action"].flatMap({ $0 as? String }) else {
            throw AutomationError.automation("perform_secondary_action requires an action")
        }

        let role = node.axRole ?? ""
        let menuButtonRoles: Set<String> = ["AXMenuBarItem", "AXMenuButton", "AXPopUpButton"]
        let expectTransientOpen =
            ["AXShowMenu", "AXShowDefaultUI", "AXShowAlternateUI"].contains(action)
            || (["AXPress", "AXPick"].contains(action) && menuButtonRoles.contains(role))
        let expectTransientClose =
            ["AXPick", "AXCancel"].contains(action) && (session.menuTracker?.menusOpen == true)

        var directVerifier: (@Sendable () -> Bool)?
        if action == "AXScrollToVisible" {
            let s = session
            let n = node
            directVerifier = sendableVerifier { [weak self] in
                guard let self else { return false }
                return self.nodeIsVisibleInWindow(s, self.refreshLiveNodeFromRef(n))
            }
        }
        let contract = VerificationContract(
            expectTransientOpen: expectTransientOpen,
            expectTransientClose: expectTransientClose,
            allowFocusChange: action != "AXScrollToVisible",
            allowValueChange: action != "AXScrollToVisible",
            directVerifier: directVerifier
        )

        // --- Primary: direct AX action ---
        do {
            let mark = session.axOutcomeMonitor?.mark()
            try providers.accessibility.performAction(node: node, action: action)
            var transientSource: TransientSource?
            if expectTransientOpen {
                transientSource = makeTransientSource(
                    session, node, actionName: action,
                    reopenFn: { [weak self] resolved in
                        self?.safePerformAction(session, resolved, action) ?? false
                    }
                )
            }
            let v = verifyAXContract(session, contract: contract, mark: mark, transientSource: transientSource)
            if v == .confirmed || v == .transientOpened || v == .transientClosed {
                return "Performed \(repr(action)) on element \(idx)"
            }
        } catch {
            // fall through to AXPress fallback
        }

        // --- AXPress as generic fallback ---
        if action != "AXPress" && action != "AXCancel" && !strictSecondaryActions.contains(action) {
            do {
                let mark = session.axOutcomeMonitor?.mark()
                try providers.accessibility.performAction(node: node, action: "AXPress")
                var transientSource: TransientSource?
                if menuButtonRoles.contains(role) {
                    transientSource = makeTransientSource(
                        session, node, actionName: "AXPress",
                        reopenFn: { [weak self] resolved in
                            self?.safePerformAction(session, resolved, "AXPress") ?? false
                        }
                    )
                }
                let v = verifyAXContract(
                    session,
                    contract: VerificationContract(
                        expectTransientOpen: transientSource != nil,
                        expectTransientClose: expectTransientClose
                    ),
                    mark: mark, transientSource: transientSource
                )
                if v == .confirmed || v == .transientOpened || v == .transientClosed {
                    return "Performed AXPress on element \(idx) (fallback for \(repr(action)))"
                }
            } catch {
                // fall through to error
            }
        }

        throw AutomationError.automation(
            "Action \(repr(action)) failed on element \(idx). "
            + "Try a different action from the element's secondary_actions list."
        )
    }

    // MARK: - scroll (session.py:3326)

    /// Scroll using background-only methods with per-session method caching.
    /// Ports `_handle_scroll`. Method order is chosen from InputStrategy
    /// (`scrollMethodOrder(preferAX:)`); the working method is cached on
    /// `session.scrollMethod`; change is verified via a child-witness position.
    func handleScroll(_ session: AppSession, _ params: [String: Any]) throws -> String {
        guard let direction = params["direction"].flatMap({ $0 as? String }) else {
            throw AutomationError.automation("scroll requires a direction")
        }
        let pages = intParam(params["pages"], default: 1)
        if pages < 1 {
            throw AutomationError.automation("pages must be >= 1")
        }

        var node: Node?
        var idx: Int?
        var scrollPoint: Point?

        if let i = elementIndex(params) {
            idx = i
            let resolved = resolveScrollNode(session, try resolveIndex(session, i))
            node = resolved
            scrollPoint = scrollPointForNode(resolved)
        } else if let x = doubleParam(params["x"]), let y = doubleParam(params["y"]) {
            if let p = providers.input.windowToScreenCoords(
                windowId: session.target.windowId, x: x, y: y, screenshotSize: session.screenshotSize
            ) {
                scrollPoint = Point(x: p.x, y: p.y)
            } else {
                scrollPoint = Point(x: x, y: y)
            }
        }

        if node == nil && scrollPoint == nil {
            throw AutomationError.automation("scroll requires either element_index or x/y coordinates")
        }
        if let p = scrollPoint { noteCursor(session, p) }

        let preferAX = session.inputStrategy?.shouldUseAXAction(
            .scroll, isWebArea: node?.isWebArea ?? false
        ) ?? true
        let orderedMethods = scrollMethodOrder(preferAX)

        for _ in 0..<pages {
            if let cached = session.scrollMethod {
                if tryScrollMethod(session, node, scrollPoint, direction, cached) {
                    continue
                }
                session.scrollMethod = nil
            }

            var performed = false
            for method in orderedMethods {
                if tryScrollMethod(session, node, scrollPoint, direction, method) {
                    session.scrollMethod = method
                    performed = true
                    break
                }
            }
            if performed { continue }
            throw AutomationError.automation("No scroll action was performed")
        }

        let targetDesc: String
        if let idx { targetDesc = "element \(idx)" }
        else if let p = scrollPoint { targetDesc = "(\(fmt(p.x)), \(fmt(p.y)))" }
        else { targetDesc = "the window" }
        return "Scrolled \(targetDesc) \(direction) (\(pages) page(s))"
    }

    // ======================================================================
    // MARK: - Click helpers
    // ======================================================================

    /// Ports `_background_click_node`. Resolves the click target node, computes the
    /// visible click point, and delivers a per-pid `clickAtScreenPoint` (Invariant 1).
    /// For non-activatable buttons, a selection-click verifier confirms the outcome.
    func backgroundClickNode(
        _ session: AppSession, _ node: Node, button: String = "left", count: Int = 1
    ) -> Bool {
        var targetNode = prepareNodeForPointerClick(session, node)
        targetNode = resolveClickTargetNode(session, targetNode)
        guard let point = clickPointForNode(session, targetNode) else { return false }
        noteCursor(session, point, kind: cursorKind(for: targetNode))
        do {
            let transportMark = session.cgeventOutcomeMonitor?.mark() ?? 0
            try providers.input.clickAtScreenPoint(
                pid: backgroundPidForNode(session, targetNode),
                x: point.x, y: point.y, button: button, count: count,
                windowId: session.target.windowId, source: session.eventSource
            )
            if flags.cgeventActionVerification, session.cgeventOutcomeMonitor != nil {
                let directVerifier = makeSelectionClickVerifier(session, targetNode)
                var transientSource: TransientSource?
                if button == "right" {
                    transientSource = makeTransientSource(
                        session, node, actionName: "CGEventClick",
                        reopenFn: { [weak self] resolved in
                            self?.backgroundClickNode(session, resolved, button: button, count: count) ?? false
                        }
                    )
                }
                let v = verifyCGEventContract(
                    session, transportMark: transportMark,
                    contract: VerificationContract(
                        expectTransientOpen: button == "right",
                        directVerifier: directVerifier
                    ),
                    transientSource: transientSource
                )
                // Record the CGEvent verdict (overriding the inner AX verdict) so
                // the caller can distinguish "delivered but effect unverified"
                // (.noEffect — e.g. an action button the selection verifier can't
                // observe) from "not delivered" (.timeout / throw). Option A.
                session.lastActionVerification = v
                return v == .confirmed || v == .transientOpened
            }
            return true
        } catch {
            return false
        }
    }

    /// Ports `_iter_node_ancestors`. Yields ancestors by scanning the cached
    /// pre-order tree backwards (each is the nearest preceding node with smaller depth).
    func iterNodeAncestors(_ session: AppSession, _ node: Node) -> [Node] {
        guard !session.treeNodes.isEmpty, node.index >= 0, node.index < session.treeNodes.count else { return [] }
        var result: [Node] = []
        var ancestorDepth = node.depth
        var prevIdx = node.index - 1
        while prevIdx >= 0 {
            let prev = session.treeNodes[prevIdx]
            if prev.depth >= ancestorDepth { prevIdx -= 1; continue }
            result.append(prev)
            ancestorDepth = prev.depth
            prevIdx -= 1
        }
        return result
    }

    /// Ports `_background_pid_for_node` (Invariant 9). Out-of-process nodes
    /// (XPC/helper-rendered) deliver to their own `elementPid`; everything else to
    /// the window's pid.
    func backgroundPidForNode(_ session: AppSession, _ node: Node?) -> Int {
        if let node, node.isOop, let pid = node.elementPid { return pid }
        return session.target.windowPid
    }

    /// Ports `_iter_live_click_ancestors`. Walks up to 12 live AX parents from the
    /// node's `axRef`, materializing each as a `Node`.
    func iterLiveClickAncestors(_ session: AppSession, _ node: Node) -> [Node] {
        var result: [Node] = []
        var current = node.axRef
        var depth = node.depth
        for _ in 0..<12 {
            guard let cur = current else { break }
            guard let parent = providers.accessibility.getParentRef(cur) else { break }
            depth = max(0, depth - 1)
            current = parent
            if let n = try? providers.accessibility.nodeFromRef(parent, depth: depth, index: -1) {
                result.append(n)
            }
        }
        return result
    }

    private func nodeHasCurrentSnapshotIndex(_ session: AppSession, _ node: Node) -> Bool {
        node.index >= 0
            && node.index < session.treeNodes.count
            && session.treeNodes[node.index] === node
    }

    /// Ports `_resolve_click_target_node`. Finds the nearest node (self, live AX
    /// ancestors, then cached-tree ancestors) that has a non-nil frame.
    func resolveClickTargetNode(_ session: AppSession, _ node: Node) -> Node {
        var candidates: [Node] = [node]
        candidates.append(contentsOf: iterLiveClickAncestors(session, node))
        if nodeHasCurrentSnapshotIndex(session, node) {
            candidates.append(contentsOf: iterNodeAncestors(session, node))
        }
        for candidate in candidates where providers.accessibility.getElementFrame(node: candidate) != nil {
            return candidate
        }
        return node
    }

    /// Ports `_window_visible_rect`. The visible window bounds in screen points.
    func windowVisibleRect(_ session: AppSession) -> Rect? {
        providers.capture.getWindowBounds(windowId: session.target.windowId)
    }

    /// Ports `_visible_click_point_for_frame`. The center of the element's visible
    /// intersection with the window (so off-screen-clipped elements click in-bounds).
    func visibleClickPointForFrame(_ session: AppSession, _ frame: Rect) -> Point? {
        let fx = frame.x, fy = frame.y, fw = frame.w, fh = frame.h
        if fw <= 0 || fh <= 0 { return nil }
        guard let visible = windowVisibleRect(session) else {
            return Point(x: fx + fw / 2, y: fy + fh / 2)
        }
        let vx = visible.x, vy = visible.y, vw = visible.w, vh = visible.h
        if vw <= 0 || vh <= 0 { return nil }
        let ix = max(fx, vx)
        let iy = max(fy, vy)
        let iw = min(fx + fw, vx + vw) - ix
        let ih = min(fy + fh, vy + vh) - iy
        if iw <= 0 || ih <= 0 { return nil }
        return Point(x: ix + iw / 2, y: iy + ih / 2)
    }

    /// Ports `_click_point_for_node`.
    func clickPointForNode(_ session: AppSession, _ node: Node) -> Point? {
        guard let frame = providers.accessibility.getElementFrame(node: node) else { return nil }
        return visibleClickPointForFrame(session, frame)
    }

    /// Ports `_node_is_visible_in_window`.
    func nodeIsVisibleInWindow(_ session: AppSession, _ node: Node) -> Bool {
        guard let frame = providers.accessibility.getElementFrame(node: node) else { return false }
        return visibleClickPointForFrame(session, frame) != nil
    }

    /// Ports `_refresh_live_node_from_ref`. Re-materializes the node from its AX ref.
    func refreshLiveNodeFromRef(_ node: Node) -> Node {
        guard let ref = node.axRef else { return node }
        return (try? providers.accessibility.nodeFromRef(ref, depth: node.depth, index: node.index)) ?? node
    }

    /// Ports `_prepare_node_for_pointer_click`. If the node is clipped out of the
    /// window and supports `AXScrollToVisible`, scroll it into view first.
    func prepareNodeForPointerClick(_ session: AppSession, _ node: Node) -> Node {
        if nodeIsVisibleInWindow(session, node) { return node }
        if !nodeActionNames(session, node).contains("AXScrollToVisible") { return node }
        do {
            let mark = session.axOutcomeMonitor?.mark()
            try providers.accessibility.performAction(node: node, action: "AXScrollToVisible")
            let s = session
            let n = node
            let v = verifyAXContract(
                session,
                contract: VerificationContract(
                    allowFocusChange: false, allowValueChange: false,
                    directVerifier: sendableVerifier { [weak self] in
                        guard let self else { return false }
                        return self.nodeIsVisibleInWindow(s, self.refreshLiveNodeFromRef(n))
                    }
                ),
                mark: mark
            )
            if v == .confirmed || v == .transientOpened {
                return refreshLiveNodeFromRef(node)
            }
        } catch {
            // best-effort
        }
        return node
    }

    /// Ports `_try_ax_click_node`. AX-action click path: AXSelected for selectable
    /// rows, AXShowMenu for right-click, AXPress for left-click (unless the node is a
    /// button without an activation action — then defer to pointer).
    func tryAXClickNode(
        _ session: AppSession, _ node: Node, _ idx: Int, button: String, count: Int
    ) -> String? {
        if count == 1, button == "left", node.states.contains("selectable") {
            let mark = session.axOutcomeMonitor?.mark()
            do {
                try providers.accessibility.setAttribute(node: node, "AXSelected", "true")
                let v = verifyAXContract(
                    session,
                    contract: VerificationContract(directVerifier: sendableVerifier { [providers] in
                        guard let ref = node.axRef,
                              let n = try? providers.accessibility.nodeFromRef(ref, depth: node.depth, index: node.index)
                        else { return false }
                        return n.states.contains("selected")
                    }),
                    mark: mark
                )
                if v == .confirmed || v == .transientOpened {
                    return "Clicked element \(idx) (AXSelected)"
                }
            } catch {
                // continue
            }
        }

        if button == "right" {
            let mark = session.axOutcomeMonitor?.mark()
            do {
                try providers.accessibility.performAction(node: node, action: "AXShowMenu")
                let transientSource = makeTransientSource(
                    session, node, actionName: "AXShowMenu",
                    reopenFn: { [weak self] resolved in
                        self?.safePerformAction(session, resolved, "AXShowMenu") ?? false
                    }
                )
                let v = verifyAXContract(
                    session, contract: VerificationContract(expectTransientOpen: true),
                    mark: mark, transientSource: transientSource
                )
                if v == .confirmed || v == .transientOpened {
                    return "Right-clicked element \(idx) (AXShowMenu)"
                }
                return nil
            } catch {
                session.inputStrategy?.recordAXFailure()
                return nil
            }
        }

        if count == 1, button == "left" {
            if shouldForcePointerForNode(session, node) { return nil }
            let mark = session.axOutcomeMonitor?.mark()
            do {
                try providers.accessibility.performAction(node: node, action: "AXPress")
                let v = verifyAXContract(session, contract: VerificationContract(), mark: mark)
                if v == .confirmed || v == .transientOpened {
                    return "Clicked element \(idx) (AXPress)"
                }
            } catch {
                session.inputStrategy?.recordAXFailure()
            }
        }
        return nil
    }

    /// Ports `_try_ax_hit_test_click`. Single-click only: hit-test the visible click
    /// point and `performActionOnRef` AXShowMenu/AXPress on the hit element.
    func tryAXHitTestClick(
        _ session: AppSession, _ node: Node, _ idx: Int, button: String, count: Int
    ) -> String? {
        if count != 1 { return nil }
        let targetNode = resolveClickTargetNode(session, node)
        guard let point = clickPointForNode(session, targetNode) else { return nil }
        guard let hitRef = providers.accessibility.elementAtPosition(
            axApp: session.target.axApp, x: point.x, y: point.y
        ) else { return nil }
        do {
            let mark = session.axOutcomeMonitor?.mark()
            if button == "right" {
                try providers.accessibility.performActionOnRef(hitRef, action: "AXShowMenu")
                var transientSource: TransientSource?
                if let hitNode = try? providers.accessibility.nodeFromRef(hitRef, depth: 0, index: -1) {
                    transientSource = makeTransientSource(
                        session, hitNode, actionName: "AXShowMenu",
                        reopenFn: { [weak self] resolved in
                            self?.safePerformAction(session, resolved, "AXShowMenu") ?? false
                        }
                    )
                }
                let v = verifyAXContract(
                    session, contract: VerificationContract(expectTransientOpen: true),
                    mark: mark, transientSource: transientSource
                )
                if v == .confirmed || v == .transientOpened {
                    return "Right-clicked element \(idx) (AX hit-test)"
                }
                return nil
            }
            try providers.accessibility.performActionOnRef(hitRef, action: "AXPress")
            let v = verifyAXContract(session, contract: VerificationContract(), mark: mark)
            if v == .confirmed || v == .transientOpened {
                return "Clicked element \(idx) (AX hit-test)"
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Ports `_try_ax_hit_test_click_at_point`. The coordinate-mode AX hit-test;
    /// honors InputStrategy (web content forces CGEvent → returns nil so the caller
    /// falls back to the pointer path).
    func tryAXHitTestClickAtPoint(
        _ session: AppSession, _ x: Double, _ y: Double,
        displayX: Double, displayY: Double, button: String, count: Int
    ) -> String? {
        if count != 1 { return nil }
        guard let hitRef = providers.accessibility.elementAtPosition(
            axApp: session.target.axApp, x: x, y: y
        ) else { return nil }

        let hitNode = try? providers.accessibility.nodeFromRef(hitRef, depth: 0, index: -1)
        if let hitNode, let strategy = session.inputStrategy,
           !strategy.shouldUseAXAction(.click, isWebArea: hitNode.isWebArea) {
            return nil
        }

        do {
            let mark = session.axOutcomeMonitor?.mark()
            if button == "right" {
                try providers.accessibility.performActionOnRef(hitRef, action: "AXShowMenu")
                var transientSource: TransientSource?
                if let n = hitNode ?? (try? providers.accessibility.nodeFromRef(hitRef, depth: 0, index: -1)) {
                    transientSource = makeTransientSource(
                        session, n, actionName: "AXShowMenu",
                        reopenFn: { [weak self] resolved in
                            self?.safePerformAction(session, resolved, "AXShowMenu") ?? false
                        }
                    )
                }
                let v = verifyAXContract(
                    session, contract: VerificationContract(expectTransientOpen: true),
                    mark: mark, transientSource: transientSource
                )
                if v == .confirmed || v == .transientOpened {
                    return "Right-clicked at (\(fmt(displayX)), \(fmt(displayY))) (AX hit-test)"
                }
                return nil
            }
            try providers.accessibility.performActionOnRef(hitRef, action: "AXPress")
            let v = verifyAXContract(session, contract: VerificationContract(), mark: mark)
            if v == .confirmed || v == .transientOpened {
                return "Clicked at (\(fmt(displayX)), \(fmt(displayY))) (AX hit-test)"
            }
            return nil
        } catch {
            session.inputStrategy?.recordAXFailure()
            return nil
        }
    }

    private func hasWebAncestor(_ nodes: [Node], _ idx: Int) -> Bool {
        guard idx >= 0, idx < nodes.count else { return false }
        let node = nodes[idx]
        var ancestorDepth = node.depth
        var prevIdx = idx - 1
        while prevIdx >= 0 {
            let prev = nodes[prevIdx]
            if prev.depth >= ancestorDepth { prevIdx -= 1; continue }
            if webContainerRoles.contains(prev.role) { return true }
            ancestorDepth = prev.depth
            prevIdx -= 1
        }
        return false
    }

    /// Ports `_should_prefer_pointer_input`. Decides AX-first vs pointer-first for a
    /// targeted click, from InputStrategy + web-ancestry + role + activation actions.
    func shouldPreferPointerInput(_ session: AppSession, _ node: Node) -> Bool {
        let hasWeb = node.index >= 0 && node.index < session.treeNodes.count
            && hasWebAncestor(session.treeNodes, node.index)
        if let strategy = session.inputStrategy,
           !strategy.shouldUseAXAction(.click, isWebArea: node.isWebArea || hasWeb) {
            return true
        }
        if !pointerPreferredRoles.contains(node.role) { return false }
        if node.index < 0 || node.index >= session.treeNodes.count { return false }
        if shouldForcePointerForNode(session, node) { return true }
        return hasWeb
    }

    /// Ports `_node_action_names`. The node's AX action names (live ref preferred,
    /// else the cached `secondaryActions`).
    func nodeActionNames(_ session: AppSession, _ node: Node) -> Set<String> {
        guard let ref = node.axRef else { return Set(node.secondaryActions) }
        let names = providers.accessibility.getActionNamesForRef(ref)
        return names.isEmpty ? Set(node.secondaryActions) : Set(names)
    }

    /// Ports `_should_force_pointer_for_node`. A buttonish element exposing actions
    /// but NO activation action (AXConfirm/AXPick/AXPress) must be clicked by pointer.
    func shouldForcePointerForNode(_ session: AppSession, _ node: Node) -> Bool {
        guard let role = node.axRole, buttonishAXRoles.contains(role) else { return false }
        let actionNames = nodeActionNames(session, node)
        if actionNames.isEmpty { return false }
        return actionNames.isDisjoint(with: axActivationActions)
    }

    private func nodeIdentity(_ node: Node) -> SelectionIdentity {
        SelectionIdentity(axId: node.axId, description: node.description, label: node.label)
    }

    /// Ports `_selection_container_node`. The nearest selection-container ancestor
    /// (collection/list/outline/table) with a live AX ref.
    func selectionContainerNode(_ session: AppSession, _ node: Node) -> Node? {
        var candidates: [Node] = [refreshLiveNodeFromRef(node)]
        candidates.append(contentsOf: iterLiveClickAncestors(session, node))
        if nodeHasCurrentSnapshotIndex(session, node) {
            candidates.append(contentsOf: iterNodeAncestors(session, node))
        }
        for candidate in candidates
        where selectionContainerRoles.contains(candidate.role) && candidate.axRef != nil {
            return candidate
        }
        return nil
    }

    /// Ports `_selected_identities_in_container`. The identities of all selected
    /// descendants of the container.
    func selectedIdentitiesInContainer(_ session: AppSession, _ container: Node) -> Set<SelectionIdentity> {
        guard let ref = container.axRef else { return [] }
        guard let subtree = try? providers.accessibility.walkTree(
            axElement: ref, targetPid: backgroundPidForNode(session, container),
            maxDepth: Int.max, maxNodes: Int.max, includeActions: false, includeStates: true
        ) else { return [] }
        var result: Set<SelectionIdentity> = []
        for item in subtree where item.states.contains("selected") {
            result.insert(nodeIdentity(item))
        }
        return result
    }

    /// Ports `_make_selection_click_verifier`. For force-pointer (selection-style)
    /// buttons, returns a verifier asserting the node became selected after the click.
    func makeSelectionClickVerifier(_ session: AppSession, _ node: Node) -> (@Sendable () -> Bool)? {
        if !shouldForcePointerForNode(session, node) { return nil }
        guard let container = selectionContainerNode(session, node) else { return nil }
        let baseline = selectedIdentitiesInContainer(session, container)
        let targetIdentity = nodeIdentity(node)
        let s = session
        let n = node
        let c = container
        return sendableVerifier { [weak self] in
            guard let self else { return false }
            let refreshed = self.refreshLiveNodeFromRef(n)
            if refreshed.states.contains("selected") { return true }
            let refreshedContainer = self.refreshLiveNodeFromRef(c)
            let after = self.selectedIdentitiesInContainer(s, refreshedContainer)
            return after != baseline && after.contains(targetIdentity)
        }
    }

    /// Ports `_focus_node_for_keyboard_input`. Element-level AX focus first; falls
    /// back to a background click on the element (never activates the app, Invariant 7).
    func focusNodeForKeyboardInput(_ session: AppSession, _ node: Node) -> Bool {
        if (try? providers.accessibility.setAttribute(node: node, "AXFocused", "true")) != nil {
            return true
        }
        if backgroundClickNode(session, node) { return true }
        return false
    }

    /// Ports `_to_screen_coords`. Screenshot-pixel → screen-point lookup (no event).
    func toScreenCoords(_ session: AppSession, _ windowId: Int, _ x: Double, _ y: Double) -> (Double, Double) {
        if let p = providers.input.windowToScreenCoords(
            windowId: windowId, x: x, y: y, screenshotSize: session.screenshotSize
        ) {
            return (p.x, p.y)
        }
        return (x, y)
    }

    // ======================================================================
    // MARK: - Scroll helpers
    // ======================================================================

    /// Ports `_node_supports_scroll`.
    func nodeSupportsScroll(_ session: AppSession, _ node: Node) -> Bool {
        if scrollableDisplayRoles.contains(node.role) { return true }
        if node.secondaryActions.contains(where: { directionalScrollActions.contains($0) }) { return true }
        if let ref = node.axRef { return providers.accessibility.hasScrollbarRef(ref) }
        return false
    }

    /// Ports `_iter_live_scroll_ancestors`.
    func iterLiveScrollAncestors(_ session: AppSession, _ node: Node) -> [Node] {
        iterLiveClickAncestors(session, node)
    }

    /// Ports `_resolve_scroll_node`. The node itself if scrollable, else the nearest
    /// scrollable ancestor (live AX then cached tree).
    func resolveScrollNode(_ session: AppSession, _ node: Node) -> Node {
        if nodeSupportsScroll(session, node) { return node }
        for ancestor in iterLiveScrollAncestors(session, node) where nodeSupportsScroll(session, ancestor) {
            return ancestor
        }
        for ancestor in iterNodeAncestors(session, node) where nodeSupportsScroll(session, ancestor) {
            return ancestor
        }
        return node
    }

    /// Ports `_scroll_point_for_node`. The element frame center.
    func scrollPointForNode(_ node: Node) -> Point? {
        guard let frame = providers.accessibility.getElementFrame(node: node) else { return nil }
        return Point(x: frame.x + frame.w / 2, y: frame.y + frame.h / 2)
    }

    /// Ports `_scroll_method_order`. AX-preferred → scrollbar/ax/pixel/pid; else
    /// pixel/pid/ax/scrollbar.
    func scrollMethodOrder(_ preferAX: Bool) -> [String] {
        preferAX ? ["scrollbar", "ax", "pixel", "pid"] : ["pixel", "pid", "ax", "scrollbar"]
    }

    /// Ports `_try_scroll_method`. Dispatch to the named scroll method.
    func tryScrollMethod(
        _ session: AppSession, _ node: Node?, _ point: Point?, _ direction: String, _ method: String
    ) -> Bool {
        switch method {
        case "ax" where node != nil: return tryAXScroll(session, node!, direction)
        case "scrollbar" where node != nil: return tryScrollbarFallback(session, node!, direction)
        case "pixel" where point != nil: return tryPidPixelScroll(session, node, point!, direction)
        case "pid" where point != nil: return tryPidScroll(session, node, point!, direction)
        default: return false
        }
    }

    /// Ports `_try_scrollbar_fallback`. Nudges the AX scrollbar value by ±0.1.
    func tryScrollbarFallback(_ session: AppSession, _ node: Node, _ direction: String) -> Bool {
        let isVertical = direction == "up" || direction == "down"
        let scrollbarAttr = isVertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
        guard let ref = node.axRef else { return false }
        // The real implementation reads/sets a nested scrollbar's AXValue; the Core
        // seam exposes only string attribute access, so this best-effort path nudges
        // the value when the current value is readable.
        guard let scrollbarValue = providers.accessibility.getAttributeValue(ref, scrollbarAttr),
              let current = Double(scrollbarValue) else { return false }
        let delta = (direction == "down" || direction == "right") ? 0.1 : -0.1
        let newVal = max(0.0, min(1.0, current + delta))
        return (try? providers.accessibility.setAttribute(node: node, scrollbarAttr, String(newVal))) != nil
    }

    /// Ports `_try_ax_scroll`. Tries `AXScroll<Dir>ByPage`/`AXScroll<Dir>` on the
    /// node and its scrollable ancestors, verifying via a child-witness position.
    func tryAXScroll(_ session: AppSession, _ node: Node, _ direction: String) -> Bool {
        let dirTitle = direction.prefix(1).uppercased() + direction.dropFirst()
        let axPageActions = ["AXScroll\(dirTitle)ByPage", "AXScroll\(dirTitle)"]

        var candidates: [Node] = [node]
        candidates.append(contentsOf: iterLiveScrollAncestors(session, node))
        candidates.append(contentsOf: iterNodeAncestors(session, node))
        let before = getScrollWitness(session, node)

        for candidate in candidates {
            let actionNames: [String] = candidate.axRef.map {
                providers.accessibility.getActionNamesForRef($0)
            } ?? candidate.secondaryActions
            for action in axPageActions where actionNames.contains(action) {
                let mark = session.axOutcomeMonitor?.mark()
                do {
                    try providers.accessibility.performAction(node: candidate, action: action)
                    let s = session
                    let n = node
                    let b = before
                    let v = verifyAXContract(
                        session,
                        contract: VerificationContract(directVerifier: sendableVerifier { [weak self] in
                            self?.scrollChanged(s, n, b) ?? false
                        }),
                        mark: mark
                    )
                    if v == .confirmed || v == .transientOpened { return true }
                } catch {
                    // try next candidate/action
                }
            }
        }
        return false
    }

    /// Ports `_get_scroll_witness`. The position of a child element used to detect
    /// whether a scroll actually moved content.
    func getScrollWitness(_ session: AppSession, _ node: Node?) -> Point? {
        guard let node, !session.treeNodes.isEmpty, node.index >= 0 else { return nil }
        let upper = min(node.index + 20, session.treeNodes.count)
        var i = node.index + 1
        while i < upper {
            let child = session.treeNodes[i]
            if child.depth <= node.depth { break }
            if let frame = providers.accessibility.getElementFrame(node: child) {
                return Point(x: frame.x, y: frame.y)
            }
            i += 1
        }
        return nil
    }

    /// Ports `_scroll_changed`. True if the witness child moved by >1px in either axis.
    func scrollChanged(_ session: AppSession, _ node: Node?, _ before: Point?) -> Bool {
        guard let before else { return false }
        guard let after = getScrollWitness(session, node) else { return false }
        return abs(after.x - before.x) > 1 || abs(after.y - before.y) > 1
    }

    /// Ports `_try_pid_pixel_scroll`. Per-pid pixel-precise wheel scroll
    /// (Invariants 1, 6); verified against the child witness.
    func tryPidPixelScroll(_ session: AppSession, _ node: Node?, _ point: Point, _ direction: String) -> Bool {
        let before = getScrollWitness(session, node)
        let bounds = providers.capture.getWindowBounds(windowId: session.target.windowId)
        let isVertical = direction == "up" || direction == "down"
        let span = bounds.map { isVertical ? $0.h : $0.w } ?? 0
        let pixels = max(SpineConst.scrollPixelsMin, Int(span * SpineConst.scrollPixelsPerPageRatio))
        let transportMark = session.cgeventOutcomeMonitor?.mark() ?? 0
        do {
            try providers.input.scrollPidPixel(
                pid: backgroundPidForNode(session, node),
                x: point.x, y: point.y, direction: direction, pixels: pixels,
                windowId: session.target.windowId, source: session.eventSource
            )
            if flags.cgeventActionVerification, session.cgeventOutcomeMonitor != nil {
                let s = session
                let n = node
                let b = before
                let v = verifyCGEventContract(
                    session, transportMark: transportMark,
                    contract: VerificationContract(directVerifier: sendableVerifier { [weak self] in
                        self?.scrollChanged(s, n, b) ?? false
                    })
                )
                return v == .confirmed || v == .transientOpened
            }
            return true
        } catch {
            return false
        }
    }

    /// Ports `_try_pid_scroll`. Per-pid line/wheel-click scroll (Invariant 1).
    func tryPidScroll(_ session: AppSession, _ node: Node?, _ point: Point, _ direction: String) -> Bool {
        let before = getScrollWitness(session, node)
        let transportMark = session.cgeventOutcomeMonitor?.mark() ?? 0
        do {
            try providers.input.scrollPid(
                pid: backgroundPidForNode(session, node),
                x: point.x, y: point.y, direction: direction, clicks: SpineConst.scrollClicksPerPage,
                windowId: session.target.windowId, source: session.eventSource
            )
            if flags.cgeventActionVerification, session.cgeventOutcomeMonitor != nil {
                let s = session
                let n = node
                let b = before
                let v = verifyCGEventContract(
                    session, transportMark: transportMark,
                    contract: VerificationContract(directVerifier: sendableVerifier { [weak self] in
                        self?.scrollChanged(s, n, b) ?? false
                    })
                )
                return v == .confirmed || v == .transientOpened
            }
            return true
        } catch {
            return false
        }
    }

    // ======================================================================
    // MARK: - Verification helpers (Invariants 20-21: transport ≠ outcome)
    // ======================================================================

    /// Ports `_make_transient_source`. Builds a `TransientSource` from the node's own
    /// `graphLocator` and a reopen closure for the spine to consume on transient loss.
    /// (The spine owns graph re-resolution; here the closure is applied to the node.)
    func makeTransientSource(
        _ session: AppSession, _ node: Node, actionName: String,
        reopenFn: @escaping (Node) -> Bool
    ) -> TransientSource {
        let locator = node.graphLocator
        let n = node
        return TransientSource(
            actionName: actionName,
            nodeLocator: locator,
            graphKind: .persistent,
            description: node.label ?? node.description ?? node.role,
            reopen: { reopenFn(n) }
        )
    }

    /// Ports `_verify_ax_contract`. When AX verification is off or no monitor is
    /// wired, poll the `directVerifier` (if any) until the timeout; otherwise defer
    /// to the `OutcomeMonitor`. A `transientSource` is stashed for the spine when the
    /// action opens a transient surface.
    func verifyAXContract(
        _ session: AppSession,
        contract: VerificationContract,
        mark: Int?,
        transientSource: TransientSource? = nil,
        timeout: Double = 0.35
    ) -> ActionVerificationResult {
        if !flags.axActionVerification || session.axOutcomeMonitor == nil {
            if let transientSource { session.pendingTransientSource = transientSource }
            if let verifier = contract.directVerifier {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if verifier() { return .confirmed }
                }
                return verifier() ? .confirmed : .timeout
            }
            return .confirmed
        }
        let result = session.axOutcomeMonitor!.verifyAX(contract: contract, mark: mark, timeout: timeout)
        session.lastActionVerification = result
        if result == .transientOpened, let transientSource {
            session.pendingTransientSource = transientSource
        }
        return result
    }

    /// Ports `_verify_cgevent_contract`. Combines transport confirmation (tap echo,
    /// Invariant 4) with the AX/direct outcome check. Confirmed transport + no
    /// observed effect collapses to `noEffect` (Invariant 20).
    func verifyCGEventContract(
        _ session: AppSession,
        transportMark: Int,
        contract: VerificationContract,
        transientSource: TransientSource? = nil,
        timeout: Double = 0.35
    ) -> ActionVerificationResult {
        if !flags.cgeventActionVerification {
            if let transientSource { session.pendingTransientSource = transientSource }
            return .confirmed
        }
        guard let monitor = session.cgeventOutcomeMonitor else {
            let outcome = verifyAXContract(
                session, contract: contract, mark: nil, transientSource: transientSource, timeout: timeout
            )
            if contract.directVerifier != nil || contract.expectTransientOpen || contract.expectTransientClose {
                return outcome
            }
            return .confirmed
        }
        let transportOK = monitor.verifyTransport(startSequence: transportMark, timeout: min(timeout, 0.25))
        let outcome = verifyAXContract(
            session, contract: contract, mark: nil, transientSource: transientSource, timeout: timeout
        )
        if transportOK, outcome == .confirmed || outcome == .transientOpened || outcome == .transientClosed {
            return outcome
        }
        if transportOK { return .noEffect }
        return .timeout
    }

    /// Convenience: verify CGEvent transport only (used by the coordinate-click retry).
    func verifyTransport(_ session: AppSession, startSequence: Int, timeout: Double = 0.25) -> Bool {
        guard flags.cgeventActionVerification, let monitor = session.cgeventOutcomeMonitor else { return true }
        return monitor.verifyTransport(startSequence: startSequence, timeout: timeout)
    }

    /// Ports `_capture_element_snapshot`. Lightweight pre/post element state.
    func captureElementSnapshot(_ session: AppSession, _ node: Node?) -> ElementSnapshot {
        var value: AnyHashable?
        var selected = false
        let childCount = 0
        if let node {
            value = node.value
            selected = node.states.contains("selected")
        }

        var focusedId: AnyHashable?
        if node != nil {
            if let focused = providers.accessibility.getFocusedElement(
                axApp: session.target.axApp, tree: session.treeNodes
            ) {
                focusedId = focused
            }
        }

        let menuOpen = session.menuTracker?.menusOpen ?? false

        return ElementSnapshot(
            value: value, selected: selected, focusedElementId: focusedId,
            menuOpen: menuOpen, childCount: childCount
        )
    }

    /// Ports `_compute_delivery_verdict`. Stores the verdict on the session.
    @discardableResult
    func computeDeliveryVerdict(
        _ session: AppSession, before: ElementSnapshot, after: ElementSnapshot,
        transportConfirmed: Bool, fallbackUsed: Bool, expected: ExpectedDiff
    ) -> DeliveryVerdict {
        let diff = before.diff(after)
        let verdict = ActionVerifier.computeVerdict(
            transportConfirmed: transportConfirmed, diffAnyChanged: diff.anyChanged,
            expected: expected, fallbackUsed: fallbackUsed
        )
        session.lastDeliveryVerdict = verdict
        return verdict
    }

    /// Update the session's logical cursor to a delivery point (F / US-039). This
    /// is the single chokepoint that drives the decorative ghost overlay via
    /// `BackgroundCursor.moveTo` (render deferred to Phase 6). Logical only — the
    /// OS cursor never moves (Prime Invariant / Invariant 2).
    func noteCursor(_ session: AppSession, _ point: Point, kind: GhostCursorKind = .arrow) {
        // Animated = the ghost glides (eased bezier "scoot") to where the agent is
        // acting, instead of teleporting — human-like motion toward each element.
        session.cursor?.moveTo(point, animated: true)
        // Pick the matching pointer shape (arrow / I-beam / hand) for what's there.
        ghostController.setKind(windowId: session.target.windowId, kind)
    }

    /// Map an element's accessibility role to the ghost pointer shape, mirroring
    /// the system cursors: I-beam over editable text, a pointing hand over
    /// buttons/links/clickable controls, otherwise the default arrow.
    func cursorKind(for node: Node?) -> GhostCursorKind {
        switch node?.axRole {
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox":
            return .ibeam
        case "AXButton", "AXLink", "AXMenuButton", "AXPopUpButton", "AXMenuItem",
             "AXCheckBox", "AXRadioButton", "AXDisclosureTriangle", "AXTabButton",
             "AXIncrementor", "AXStepper", "AXSwitch":
            return .hand
        default:
            return .arrow
        }
    }

    /// Mirrors `_safe_perform_action`: perform an action on a node, swallowing errors.
    func safePerformAction(_ session: AppSession, _ node: Node, _ action: String) -> Bool {
        (try? providers.accessibility.performAction(node: node, action: action)) != nil
    }

    // ======================================================================
    // MARK: - Param parsing
    // ======================================================================

    /// element_index may arrive as Int or String (per the tool schema). Returns nil
    /// if absent or unparseable.
    func elementIndex(_ params: [String: Any]) -> Int? {
        guard let raw = params["element_index"] else { return nil }
        if let i = raw as? Int { return i }
        if let s = raw as? String { return Int(s) }
        if let d = raw as? Double { return Int(d) }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    func intParam(_ raw: Any?, default def: Int) -> Int {
        guard let raw else { return def }
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        if let n = raw as? NSNumber { return n.intValue }
        return def
    }

    func doubleParam(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let d = raw as? Double { return d }
        if let i = raw as? Int { return Double(i) }
        if let s = raw as? String, let d = Double(s) { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    func stringParam(_ raw: Any?, default def: String) -> String {
        (raw as? String) ?? def
    }

    func boolParam(_ raw: Any?, default def: Bool) -> Bool {
        guard let raw else { return def }
        if let b = raw as? Bool { return b }
        if let i = raw as? Int { return i != 0 }
        if let n = raw as? NSNumber { return n.boolValue }
        return def
    }

    /// Format a Double the way Python's f-string prints a coordinate (drops the
    /// trailing ".0" for integral values, matching `f"{x}"` on an int-valued float).
    func fmt(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(value)
    }

    /// Mirror of Python `repr()` for a string used in success messages: single
    /// quotes around the value.
    func repr(_ value: String) -> String {
        "'\(value)'"
    }
}

/// Identity tuple used for selection-set comparison (ports the Python
/// `(ax_id, description, label)` tuple).
struct SelectionIdentity: Hashable {
    let axId: String?
    let description: String?
    let label: String?
}

/// Bridges a plain (non-Sendable-capturing) verifier closure into the
/// `@Sendable () -> Bool` shape that `VerificationContract.directVerifier`
/// requires. The whole `SessionManager` spine is confined to the single MCP
/// dispatch thread (SessionManager.swift §concurrency note), so the captured
/// reference types (`Node`, `Providers`, `SessionManager`) are never touched
/// concurrently — `@unchecked Sendable` records that fact without weakening the
/// Core seam's signature.
final class SendableVerifier: @unchecked Sendable {
    private let body: () -> Bool
    init(_ body: @escaping () -> Bool) { self.body = body }
    func callAsFunction() -> Bool { body() }
}

extension SessionManager {
    /// Wrap a plain verifier closure as a `@Sendable` one for `VerificationContract`.
    func sendableVerifier(_ body: @escaping () -> Bool) -> (@Sendable () -> Bool) {
        let box = SendableVerifier(body)
        return { box() }
    }
}
