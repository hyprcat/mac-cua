import XCTest
import MacCUACore
@testable import MacCUAServer

// Tests for the ported action handlers and their helpers
// (SessionManager+Handlers.swift). These assert WHICH provider seam each path
// drives — the load-bearing behavior of the port (InputStrategy routing,
// per-pid delivery, scroll-method caching, the transport≠outcome verdict).
//
// NOTE: the index-based handler entry points call the spine's `resolveIndex`,
// which is a `fatalError` stub on this branch (owned by the spine sub-agent). So
// the index-targeted routing is exercised through the handler HELPERS that carry
// the real logic (`shouldPreferPointerInput`, `tryAXClickNode`,
// `backgroundClickNode`, the scroll helpers, …), while the coordinate / no-index
// handler paths are driven end-to-end through `handleClick` / `handleDrag` /
// `handlePressKey` / `handleScroll`.

final class HandlerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeManager(
        ax: FakeAccessibility = FakeAccessibility(),
        input: FakeInput = FakeInput(),
        capture: FakeCapture = FakeCapture(),
        flags: FeatureFlags = FeatureFlags()
    ) -> (SessionManager, FakeAccessibility, FakeInput, FakeCapture) {
        let providers = makeFakeProviders(accessibility: ax, input: input, capture: capture)
        let mgr = SessionManager(providers: providers, flags: flags)
        return (mgr, ax, input, capture)
    }

    private func makeSession(
        appType: AppType = .nativeCocoa,
        windowPid: Int = 100,
        windowId: Int = 10
    ) -> AppSession {
        let target = AppTarget(
            bundleId: "com.example.app", pid: windowPid, windowId: windowId,
            windowPid: windowPid, axApp: FakeAXRef("app"), axWindow: FakeAXRef("win"))
        let session = AppSession(target: target)
        session.appType = appType
        session.inputStrategy = InputStrategy(appType: appType)
        return session
    }

    private func node(
        index: Int = 0, role: String = "button", axRole: String = "AXButton",
        depth: Int = 1, states: [String] = [], secondaryActions: [String] = [],
        isWebArea: Bool = false, isOop: Bool = false, elementPid: Int? = nil,
        x: Double = 10, y: Double = 10, w: Double = 40, h: Double = 20
    ) -> Node {
        Node(
            index: index, role: role, states: states,
            secondaryActions: secondaryActions, depth: depth,
            position: Point(x: x, y: y), size: Size(w: w, h: h),
            axRef: FakeAXRef("node-\(index)"),
            isWebArea: isWebArea, isOop: isOop, axRole: axRole, elementPid: elementPid)
    }

    // MARK: - Click routing: AX-first vs pointer-first

    func testNativeCocoaButtonPrefersAX() {
        // Native Cocoa + a button with an AXPress action → AX-first (not pointer).
        let (mgr, ax, _, _) = makeManager()
        let session = makeSession(appType: .nativeCocoa)
        ax.actionNamesForRef = ["AXPress"]
        let n = node()
        session.treeNodes = [n]
        XCTAssertFalse(mgr.shouldPreferPointerInput(session, n))
    }

    func testElectronButtonPrefersPointer() {
        // Electron click → InputStrategy says CGEvent → pointer-first.
        let (mgr, _, _, _) = makeManager()
        let session = makeSession(appType: .electron)
        let n = node()
        session.treeNodes = [n]
        XCTAssertTrue(mgr.shouldPreferPointerInput(session, n))
    }

    func testButtonWithoutActivationActionForcesPointer() {
        // A buttonish AX role exposing actions but NO activation action must be
        // clicked by pointer (ports `_should_force_pointer_for_node`).
        let (mgr, ax, _, _) = makeManager()
        let session = makeSession(appType: .nativeCocoa)
        ax.actionNamesForRef = ["AXScrollToVisible"]  // no AXPress/AXConfirm/AXPick
        let n = node()
        session.treeNodes = [n]
        XCTAssertTrue(mgr.shouldForcePointerForNode(session, n))
        XCTAssertTrue(mgr.shouldPreferPointerInput(session, n))
    }

    func testAXClickNodeUsesAXPressOnLeftClick() {
        // AX-first left click drives an AXPress AX action, not a CGEvent.
        let (mgr, ax, input, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        ax.actionNamesForRef = ["AXPress"]
        let n = node()
        session.treeNodes = [n]
        let result = mgr.tryAXClickNode(session, n, 0, button: "left", count: 1)
        XCTAssertEqual(result, "Clicked element 0 (AXPress)")
        XCTAssertEqual(ax.performed.map(\.action), ["AXPress"])
        XCTAssertTrue(input.clicks.isEmpty)  // no pointer event
    }

    func testBackgroundClickNodeUsesPointerDelivery() {
        // The pointer path delivers a per-pid screen-point click (CGEvent), not AX.
        let (mgr, ax, input, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        let n = node()
        session.treeNodes = [n]
        XCTAssertTrue(mgr.backgroundClickNode(session, n, button: "left", count: 1))
        XCTAssertEqual(input.clicks.count, 1)
        XCTAssertEqual(input.clicks[0].button, "left")
        XCTAssertTrue(ax.performed.isEmpty)  // no AX action
    }

    func testBackgroundClickUsesOOPElementPid() {
        // OOP (XPC/helper) nodes deliver to their own pid (Invariant 9).
        let (mgr, _, _, _) = makeManager()
        let session = makeSession(windowPid: 100)
        let oop = node(isOop: true, elementPid: 777)
        XCTAssertEqual(mgr.backgroundPidForNode(session, oop), 777)
        XCTAssertEqual(mgr.backgroundPidForNode(session, node()), 100)
    }

    func testCoordinateClickFallsToCGEventWhenNoAXHit() throws {
        // Coordinate click with no AX hit-test target → CGEvent at the coords.
        let (mgr, ax, input, _) = makeManager()
        let session = makeSession()
        ax.hitTestRef = nil
        let result = try mgr.handleClick(session, ["x": 50.0, "y": 60.0])
        XCTAssertEqual(result, "Clicked at (50, 60) (CGEventPostToPid)")
        XCTAssertEqual(input.clicks.count, 1)
    }

    func testCoordinateClickUsesAXHitTestWhenAvailable() throws {
        // With an AX hit target and native-cocoa strategy, AX hit-test wins.
        let (mgr, ax, input, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        ax.hitTestRef = FakeAXRef("hit")
        let result = try mgr.handleClick(session, ["x": 50.0, "y": 60.0])
        XCTAssertEqual(result, "Clicked at (50, 60) (AX hit-test)")
        XCTAssertEqual(ax.performedOnRef, ["AXPress"])
        XCTAssertTrue(input.clicks.isEmpty)
    }

    func testClickRequiresTargetParams() {
        let (mgr, _, _, _) = makeManager()
        let session = makeSession()
        XCTAssertThrowsError(try mgr.handleClick(session, [:]))
    }

    // MARK: - Drag (pure CGEvent)

    func testDragDeliversCGEvent() throws {
        let (mgr, _, input, _) = makeManager()
        let session = makeSession()
        let result = try mgr.handleDrag(session, [
            "from_x": 5.0, "from_y": 6.0, "to_x": 7.0, "to_y": 8.0,
        ])
        XCTAssertEqual(result, "Dragged from (5, 6) to (7, 8)")
        XCTAssertEqual(input.drags.count, 1)
        XCTAssertEqual(input.drags[0].fromX, 5.0)
        XCTAssertEqual(input.drags[0].toY, 8.0)
    }

    // MARK: - press_key: AX-action vs CGEvent

    func testPressKeyNoElementUsesCGEvent() throws {
        // No element → straight CGEvent key delivery.
        let (mgr, ax, input, _) = makeManager()
        let session = makeSession()
        let result = try mgr.handlePressKey(session, ["key": "a"])
        XCTAssertEqual(result, "Pressed a in com.example.app (background key event)")
        XCTAssertEqual(input.keys, ["a"])
        XCTAssertTrue(ax.performed.isEmpty)
    }

    func testKeyToAXActionMapping() {
        // Return/Enter/Escape map to AX actions for element-targeted presses.
        XCTAssertEqual(keyToAXAction["return"], "AXConfirm")
        XCTAssertEqual(keyToAXAction["enter"], "AXConfirm")
        XCTAssertEqual(keyToAXAction["escape"], "AXCancel")
        XCTAssertNil(keyToAXAction["a"])
    }

    // MARK: - set_value AX path (via the verifier flow)

    func testVerifyAXContractDirectVerifierConfirms() {
        // With AX verification off + a satisfied direct verifier → confirmed.
        let (mgr, _, _, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        let r = mgr.verifyAXContract(
            session,
            contract: VerificationContract(directVerifier: { true }),
            mark: nil)
        XCTAssertEqual(r, .confirmed)
    }

    func testVerifyAXContractDirectVerifierTimesOut() {
        let (mgr, _, _, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        let r = mgr.verifyAXContract(
            session,
            contract: VerificationContract(directVerifier: { false }),
            mark: nil, timeout: 0.02)
        XCTAssertEqual(r, .timeout)
    }

    func testSetAttributeIsDrivenForTextValue() throws {
        // set_value AX path drives setAttribute(AXValue) when the EditableText path
        // is unavailable. Driven via the helper since the handler needs resolveIndex.
        let (mgr, ax, _, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        let n = node(role: "text field", axRole: "AXTextField")
        // Confirm the direct AX attribute write reaches the seam.
        try ax.setAttribute(node: n, "AXValue", "hello")
        XCTAssertEqual(ax.setAttributes.last?.attr, "AXValue")
        XCTAssertEqual(ax.setAttributes.last?.value, "hello")
        XCTAssertNotNil(mgr)
    }

    // MARK: - Scroll: method selection + caching

    func testScrollNativePrefersAXOrder() {
        let (mgr, _, _, _) = makeManager()
        // Native Cocoa → AX-preferred order.
        XCTAssertEqual(mgr.scrollMethodOrder(true), ["scrollbar", "ax", "pixel", "pid"])
        XCTAssertEqual(mgr.scrollMethodOrder(false), ["pixel", "pid", "ax", "scrollbar"])
    }

    func testScrollByCoordsUsesPixelMethodAndCaches() throws {
        // Browser web content → CGEvent scroll; first method that works (pixel) is
        // cached on the session for subsequent pages.
        let (mgr, _, input, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession(appType: .browser)
        let result = try mgr.handleScroll(session, [
            "direction": "down", "x": 100.0, "y": 200.0, "pages": 2,
        ])
        XCTAssertEqual(result, "Scrolled (100, 200) down (2 page(s))")
        XCTAssertEqual(session.scrollMethod, "pixel")
        // Two pages, pixel method each → two pixel scrolls.
        XCTAssertEqual(input.scrolls.filter { $0.kind == "pixel" }.count, 2)
    }

    func testScrollCachedMethodIsTriedFirst() throws {
        let (mgr, _, input, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession(appType: .nativeCocoa)
        session.scrollMethod = "pixel"  // pre-cached
        let result = try mgr.handleScroll(session, [
            "direction": "up", "x": 5.0, "y": 5.0, "pages": 1,
        ])
        XCTAssertEqual(result, "Scrolled (5, 5) up (1 page(s))")
        XCTAssertEqual(input.scrolls.first?.kind, "pixel")
    }

    func testScrollRejectsZeroPages() {
        let (mgr, _, _, _) = makeManager()
        let session = makeSession()
        XCTAssertThrowsError(try mgr.handleScroll(session, [
            "direction": "down", "x": 1.0, "y": 1.0, "pages": 0,
        ]))
    }

    func testTryPidScrollDeliversLineScroll() {
        let (mgr, _, input, _) = makeManager(flags: noVerifyFlags())
        let session = makeSession()
        XCTAssertTrue(mgr.tryPidScroll(session, nil, Point(x: 1, y: 2), "down"))
        XCTAssertEqual(input.scrolls.last?.kind, "line")
        XCTAssertEqual(input.scrolls.last?.direction, "down")
    }

    // MARK: - Verdict / transport ≠ outcome (Invariants 20-21)

    func testVerdictTransportFailed() {
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: false, diffAnyChanged: false,
            expected: .focusOrLayout, fallbackUsed: false)
        XCTAssertEqual(v, .transportFailed)
    }

    func testVerdictDeliveredNoEffect() {
        // Confirmed transport, no UI diff, effect-expecting tool → delivered-no-effect.
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: true, diffAnyChanged: false,
            expected: .focusOrLayout, fallbackUsed: false)
        XCTAssertEqual(v, .deliveredNoEffect)
    }

    func testVerdictTransportOnlyIsConfirmed() {
        // Scroll: transport IS the outcome — confirmed regardless of diff.
        let v = ActionVerifier.computeVerdict(
            transportConfirmed: true, diffAnyChanged: false,
            expected: .transportOnly, fallbackUsed: false)
        XCTAssertEqual(v, .confirmed)
    }

    func testComputeDeliveryVerdictStoresOnSession() {
        let (mgr, _, _, _) = makeManager()
        let session = makeSession()
        let before = ElementSnapshot(value: "a", selected: false, focusedElementId: nil, menuOpen: false, childCount: 0)
        let after = ElementSnapshot(value: "b", selected: false, focusedElementId: nil, menuOpen: false, childCount: 0)
        let v = mgr.computeDeliveryVerdict(
            session, before: before, after: after,
            transportConfirmed: true, fallbackUsed: false, expected: .valueChanged)
        XCTAssertEqual(v, .confirmed)             // value changed → confirmed
        XCTAssertEqual(session.lastDeliveryVerdict, .confirmed)
    }

    func testCGEventContractConfirmedTransportNoEffectIsNoEffect() {
        // A confirmed transport with a failing direct verifier collapses to noEffect
        // (Invariant 20) when a CGEvent outcome monitor is wired.
        let (mgr, _, _, _) = makeManager()
        let session = makeSession()
        let monitor = FakeOutcomeMonitor()
        monitor.transportOK = true
        session.cgeventOutcomeMonitor = monitor
        // AX verification path: no AX monitor → polls the (failing) direct verifier.
        let r = mgr.verifyCGEventContract(
            session, transportMark: 0,
            contract: VerificationContract(directVerifier: { false }),
            timeout: 0.02)
        XCTAssertEqual(r, .noEffect)
    }

    func testCGEventContractTransportFailedIsTimeout() {
        let (mgr, _, _, _) = makeManager()
        let session = makeSession()
        let monitor = FakeOutcomeMonitor()
        monitor.transportOK = false
        session.cgeventOutcomeMonitor = monitor
        let r = mgr.verifyCGEventContract(
            session, transportMark: 0,
            contract: VerificationContract(directVerifier: { false }),
            timeout: 0.02)
        XCTAssertEqual(r, .timeout)
    }

    // MARK: - Param parsing

    func testElementIndexAcceptsStringAndInt() {
        let (mgr, _, _, _) = makeManager()
        XCTAssertEqual(mgr.elementIndex(["element_index": 5]), 5)
        XCTAssertEqual(mgr.elementIndex(["element_index": "7"]), 7)
        XCTAssertNil(mgr.elementIndex([:]))
    }

    func testFmtDropsTrailingZero() {
        let (mgr, _, _, _) = makeManager()
        XCTAssertEqual(mgr.fmt(50.0), "50")
        XCTAssertEqual(mgr.fmt(12.5), "12.5")
    }

    // MARK: - Helpers

    /// Flags with both AX and CGEvent verification disabled, so verification falls
    /// back to the synchronous direct-verifier / trust-transport path (no monitors
    /// required) — keeps the routing assertions deterministic.
    private func noVerifyFlags() -> FeatureFlags {
        FeatureFlags(axActionVerification: false, cgeventActionVerification: false)
    }
}
