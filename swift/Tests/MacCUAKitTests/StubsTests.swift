#if os(macOS)
import XCTest
@testable import MacCUAKit
import MacCUACore

/// US-014: prove the Kit target compiles and its stubs conform to the Core
/// provider protocols (the build graph Core <- Kit is wired). Real behavior is
/// filled in per provider in Phases 3-6.
final class StubsTests: XCTestCase {
    func testStubsConformToProviderProtocols() {
        // Each stub is usable through its Core protocol type — proves conformance.
        let _: AppResolver = KitAppResolver()
        let _: AccessibilityProvider = KitAccessibilityProvider()
        let _: InputProvider = KitInputProvider()
        let _: CaptureProvider = KitCaptureProvider()
        let _: SelectionProvider = KitSelectionProvider()
        let _: ClipboardProvider = KitClipboardProvider()
        let _: SettleMonitor = KitSettleMonitor()
        let _: OutcomeMonitor = KitOutcomeMonitor()
        let _: UserInteractionMonitoring = KitUserInteractionMonitor()
        let _: MenuTracking = KitMenuTracker()
        let _: FrontmostTracking = KitFrontmostTracker()
        XCTAssertTrue(true)
    }

    func testSkyLightKeyboardDeliveryFailsClosedNonActivating() {
        // US-031: delivering to a bogus window/pid must return false (owner PSN
        // cannot resolve, or the capability is absent) — it falls through to the
        // CGEvent base path and NEVER foregrounds (Invariant 18). Whatever the
        // host's symbol surface, this must not crash and must not throw.
        let sky = KitSkyLightProvider()
        let delivered = sky.deliverKeyboard(
            pid: -1, windowId: 0, keycode: 0, keyDown: true, modifierMask: 0)
        XCTAssertFalse(delivered)
    }

    func testNonActingStubDefaultsAreInert() {
        // Remaining stubs must not act (Prime Invariant): the trivial-return
        // bodies report "nothing happened", never foreground.
        XCTAssertEqual(KitSettleMonitor().waitForSettle(context: "t", timeout: 1, quietPeriod: 0.1), .noChange)
    }

    func testAppResolverListIsReadOnlyAndWellFormed() {
        // US-016: listRunningApps is a pure read via NSWorkspace — never
        // foregrounds. The harness host always has at least one regular GUI app
        // running; every entry must carry a bundle id and a live pid.
        let apps = KitAppResolver().listRunningApps()
        for a in apps {
            XCTAssertFalse(a.bundleId.isEmpty)
            XCTAssertTrue(a.running)
            XCTAssertNotNil(a.pid)
        }
    }

    func testResolveUnknownAppThrows() {
        // A nonsense hint that is neither running nor an installable bundle id
        // must fail honestly rather than launch/foreground anything.
        XCTAssertThrowsError(try KitAppResolver().resolveApp("zz-no-such-app-zz"))
    }

    func testRestoreFrontmostNilIsNoOp() {
        // Restoring nil must do nothing (no activation).
        KitAppResolver().restoreFrontmostApp(nil)
    }

    func testWalkTreeEmptyRefIsInertAndNonActivating() throws {
        // US-017: walking an element with no backing AXUIElement must return an
        // empty tree (fail honestly) — never crash, never activate/raise. The
        // real-app walk needs a live AX tree (MANUAL-VERIFY).
        let nodes = try KitAccessibilityProvider().walkTree(
            axElement: KitAXElementRef(), targetPid: 1234, maxDepth: 30,
            maxNodes: 5000, includeActions: true, includeStates: true)
        XCTAssertTrue(nodes.isEmpty)
    }

    func testRefsEqualMatchesIdentityForNilHandles() {
        // Two empty Kit refs are distinct objects with no AXUIElement; refsEqual
        // falls back to === and must not crash.
        let p = KitAccessibilityProvider()
        let a = KitAXElementRef()
        XCTAssertTrue(p.refsEqual(a, a))
        XCTAssertFalse(p.refsEqual(a, KitAXElementRef()))
    }

    func testPermissionSeamsReturnWithoutCrashing() {
        // US-015: the permission seams are now REAL (AXIsProcessTrustedWithOptions
        // / CGPreflightScreenCaptureAccess). They must answer a Bool without
        // prompting and without foregrounding. Value depends on the host's grant
        // state, so we only assert the call returns. `prompt: false` = query only.
        _ = KitAppResolver().checkAccessibilityPermission(prompt: false)
        _ = KitCaptureProvider().checkScreenRecordingPermission()
    }

    func testWindowIdForEmptyRefIsNilNonActivating() {
        // US-020 (A4): an element with no backing AXUIElement has no window id.
        // The private _AXUIElementGetWindow binding must fail honestly (nil),
        // never crash, never foreground. The real multi-window binding is
        // MANUAL-VERIFY against live apps.
        let p = KitAccessibilityProvider()
        XCTAssertNil(p.windowIdForElement(KitAXElementRef()))
    }

    func testFindWindowIdForEmptyAXWindowFallsBackCleanly() {
        // With no backing element the SPI yields nil and the bounds/title
        // fallback runs over the live window list with an empty signature —
        // it must return without crashing (id is host-dependent / may be nil).
        _ = KitCaptureProvider().findWindowIdForAXWindow(pid: -1, axWindow: KitAXElementRef())
    }

    func testTextGeometrySeamsAreNilForEmptyRefNonActivating() {
        // US-021 (A5): the parameterized text-geometry reads on a node with no
        // backing AXUIElement must fail honestly (nil), never crash, never
        // foreground. The real bounds/range reads need live text elements
        // (MANUAL-VERIFY in TextEdit/Safari).
        let p = KitAccessibilityProvider()
        let n = Node(index: 0, role: "text field", depth: 0, axRef: KitAXElementRef())
        XCTAssertNil(p.boundsForTextRange(node: n, range: MacCUACore.TextRange(location: 0, length: 3)))
        XCTAssertNil(p.rangeForTextPosition(node: n, x: 10, y: 20))
        XCTAssertNil(p.visibleTextRange(node: n))
    }

    func testCaptureWindowOnBogusWindowIsNilNonActivating() throws {
        // US-022 (B1/B5): capturing a non-existent window id must fail honestly
        // (nil) — no SCWindow match — never crash, never foreground. Real
        // occluded-window capture is MANUAL-VERIFY against live apps.
        let p = KitCaptureProvider()
        XCTAssertNil(try p.captureWindow(windowId: -1, includeCursor: false))
    }

    func testWindowMetadataReadsAreWellFormed() {
        // listWindows / getWindowBounds / getWindowPid are read-only window-server
        // snapshots; a bogus id yields nil, never crashes/foregrounds.
        let p = KitCaptureProvider()
        XCTAssertNil(p.getWindowBounds(windowId: -1))
        XCTAssertNil(p.getWindowPid(windowId: -1))
        _ = p.listWindows(ownerPid: -1) // host-dependent count; must not crash
    }

    // MARK: - US-028 InputProvider (CGEvent base)

    func testInputEventSourceIsPrivatePerSession() {
        // Each created source is an independent private CGEventSource (Inv 4);
        // creating one never warps/foregrounds — it's a pure source allocation.
        let p = KitInputProvider()
        let a = p.createEventSource()
        let b = p.createEventSource()
        XCTAssertTrue(a is KitEventSource)
        XCTAssertNotIdentical(a as AnyObject, b as AnyObject)
    }

    func testWindowToScreenCoordsBogusWindowIsNil() {
        // Coordinate conversion needs live window bounds; a bogus id yields nil
        // honestly — a read-only CGWindowList lookup, never foregrounds (Inv 7/13).
        let p = KitInputProvider()
        XCTAssertNil(p.windowToScreenCoords(windowId: -1, x: 10, y: 10, screenshotSize: nil))
    }

    func testClickOnUnresolvableWindowThrowsNeverForegrounds() {
        // No window to resolve -> honest InputError; NO foregrounding fallback
        // (Inv 18). Real background-click delivery is MANUAL-VERIFY on live apps.
        let p = KitInputProvider()
        XCTAssertThrowsError(
            try p.clickAt(pid: -1, windowId: -1, x: 0, y: 0,
                          button: "left", count: 1, screenshotSize: nil, source: nil))
    }

    func testClickRejectsUnknownButton() {
        let p = KitInputProvider()
        XCTAssertThrowsError(
            try p.clickAtScreenPoint(pid: -1, x: 0, y: 0,
                                     button: "wheel", count: 1, windowId: nil, source: nil))
    }
}
#endif
