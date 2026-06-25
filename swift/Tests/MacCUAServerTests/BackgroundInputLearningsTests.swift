import XCTest
import MacCUACore
@testable import MacCUAServer

/// Spine-wiring integration tests for the three "background-input learnings"
/// features (design doc `2026-06-25-background-input-learnings-design.md`),
/// driven end-to-end through the real `SessionManager.execute(...)` against the
/// test fakes. The PURE decision logic for each lives in Core and is unit-tested
/// elsewhere (`ClickPrimerPolicyTests`, `CanvasSurfaceHeuristicTests`,
/// `CaptureModeTests`); THIS file proves the spine actually CALLS into that logic
/// on the live action path and propagates the result to the provider seams:
///
///   * US-057 — the Chromium user-activation primer reaches `FakeInput.clickAt`'s
///     `prime:` flag ONLY for a browser/electron PIXEL (x/y) click with the flag
///     on; never for native apps, never when the flag is off, and never on the
///     element_index path (which doesn't go through `clickAt`).
///   * US-058 — `get_app_state`'s `mode` param flows to `takeSnapshot`: `som`
///     (default) captures both tree + screenshot (capture fake called); `ax`
///     skips the screen-capture call ENTIRELY (no Screen Recording needed) yet
///     still serializes a tree; `vision` keeps the screenshot but omits the tree
///     text from the response.
///   * US-060 — a pixel (x/y) click whose target bundle id is a known canvas
///     surface (Blender GHOST) throws `AutomationError.unsupportedSurface`
///     instead of silently dropping a doomed click; a normal app does not.
///
/// The harness mirrors `MultiSessionParallelCursorTests` exactly: one app with a
/// resolvable window (`windowsForAXApp` + `windowIdForAXWindow`), the user parked
/// in a THIRD app so nothing foregrounds, and the session's `appType` is derived
/// the way the spine derives it — by `detectAppType(bundleId:)` inside
/// `setupSessionMonitors`. The bundle id (hence app type / canvas-ness) is chosen
/// per-test by what `FakeAppResolver.resolveRunningAppByPid` returns for the
/// window's owning pid.
final class BackgroundInputLearningsTests: XCTestCase {

    // One app, one window. Coordinate clicks fall straight through to
    // `providers.input.clickAt` when `FakeAccessibility.hitTestRef` is nil
    // (per MultiSessionParallelCursorTests).
    private let appPid = 4101
    private let appWindow = 9101
    private let userApp = AppInfo(name: "UserApp", bundleId: "com.user.app", pid: 9999, running: true)

    private let axApp = FakeAXRef("ax-app")
    private let axWin = FakeAXRef("ax-win")

    /// Build a manager whose single resolvable window is owned by `bundleId`. The
    /// spine derives `session.appType` from this bundle id via `detectAppType`, so
    /// passing `com.google.Chrome` yields `.browser`, an unlisted id yields
    /// `.nativeCocoa`, and `org.blender.blender` yields a (native-typed) session on
    /// a known CANVAS surface. `tree` seeds the AX walk so the snapshot can build a
    /// `treeNodes`/`refetchableTree` for element_index resolution.
    private func makeHarness(
        bundleId: String,
        flags: FeatureFlags,
        tree: [Node] = [],
        input: FakeInput = FakeInput(),
        capture: FakeCapture? = nil
    ) -> (SessionManager, FakeInput, FakeCapture, FakeAccessibility, FakeAppResolver) {
        let apps = FakeAppResolver()
        apps.running = [AppInfo(name: "Target", bundleId: bundleId, pid: appPid, running: true)]
        apps.axAppForPid = [appPid: axApp]
        // User is in a third app — driving the target must never foreground it.
        apps.frontmost = userApp

        let cap = capture ?? FakeCapture()
        cap.windows = [
            WindowInfo(windowId: appWindow, ownerPid: appPid, ownerName: "Target",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true),
        ]
        cap.windowIdForAXWindow = { [appWindow, axWin] ref in
            ref === axWin ? appWindow : nil
        }

        let ax = FakeAccessibility()
        ax.tree = tree
        ax.windowsForAXApp = { [axApp, axWin] root in root === axApp ? [axWin] : nil }
        // Coordinate clicks fall through to providers.input.clickAt.
        ax.hitTestRef = nil

        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: ax, input: input, capture: cap),
            flags: flags)
        return (mgr, input, cap, ax, apps)
    }

    /// Flags with verification monitors disabled (deterministic delivery) and the
    /// transient-graph / menu / interruption / selection machinery off so the
    /// action path is a clean straight line to the input seam. `clickPrimer`
    /// defaults to ON; tests that need it off pass `clickPrimer: false`.
    private func flags(clickPrimer: Bool = true) -> FeatureFlags {
        FeatureFlags(
            treePruning: false,
            userInterruptionDetection: false,
            focusEnforcement: false,
            menuTracking: false,
            transientGraphs: false,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: false,
            confirmedDelivery: false,
            clickPrimer: clickPrimer)
    }

    private func button(index: Int = 0) -> Node {
        Node(index: index, role: "button", states: [], secondaryActions: [], depth: 1,
             position: Point(x: 100, y: 100), size: Size(w: 40, h: 20),
             axRef: FakeAXRef("node-\(index)"), axRole: "AXButton")
    }

    // ======================================================================
    // MARK: - US-057 — Chromium user-activation primer
    // ======================================================================

    /// Browser + nil hit-test + flag on → the spine computes ClickPrimerPolicy and
    /// hands `prime: true` to the pixel click.
    func testBrowserPixelClickIsPrimed() {
        let (mgr, input, _, _, _) = makeHarness(bundleId: "com.google.Chrome", flags: flags())
        let r = mgr.execute("click", ["window_id": appWindow, "x": 120.0, "y": 140.0])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(input.clickPrimes.last, true,
                       "a browser pixel click must tick the Chromium user-activation primer")
        XCTAssertFalse(input.clicks.isEmpty, "the pixel click must reach clickAt")
    }

    /// Native Cocoa app → same pixel click is NOT primed (no Chromium gate).
    func testNativePixelClickIsNotPrimed() {
        let (mgr, input, _, _, _) = makeHarness(bundleId: "com.example.NativeApp", flags: flags())
        let r = mgr.execute("click", ["window_id": appWindow, "x": 120.0, "y": 140.0])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(input.clickPrimes.last, false,
                       "a native-cocoa pixel click must not be primed")
    }

    /// Browser but the `click_primer` flag is OFF → not primed.
    func testBrowserPixelClickNotPrimedWhenFlagDisabled() {
        let (mgr, input, _, _, _) = makeHarness(
            bundleId: "com.google.Chrome", flags: flags(clickPrimer: false))
        let r = mgr.execute("click", ["window_id": appWindow, "x": 120.0, "y": 140.0])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertEqual(input.clickPrimes.last, false,
                       "the primer must respect the click_primer feature flag")
    }

    /// Browser + element_index click (not x/y) → the element path never calls
    /// `clickAt`, so no primer is ever recorded (`clickPrimes` stays empty).
    func testBrowserElementClickNeverSetsPrimer() {
        // Seed an AX node so the snapshot builds a tree the element click resolves
        // against; the element path routes via AX-press / clickAtScreenPoint, NOT
        // the pixel `clickAt`, so `clickPrimes` must stay empty.
        let (mgr, input, _, _, _) = makeHarness(
            bundleId: "com.google.Chrome", flags: flags(), tree: [button()])
        let r = mgr.execute("click", ["window_id": appWindow, "element_index": 0])
        // The action may or may not "succeed" under the verifier, but it must never
        // have touched the pixel clickAt primer.
        _ = r
        XCTAssertTrue(input.clickPrimes.isEmpty,
                      "the element_index click path must not record any primer flag")
    }

    // ======================================================================
    // MARK: - US-058 — capture modes (som / ax / vision)
    // ======================================================================

    /// Default (no mode) → both a screenshot AND a tree; the capture fake WAS
    /// called.
    func testGetAppStateDefaultCapturesScreenshotAndTree() {
        let (mgr, _, cap, _, _) = makeHarness(
            bundleId: "com.example.NativeApp", flags: flags(),
            tree: [button()])
        let r = mgr.execute("get_app_state", ["window_id": appWindow])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertNotNil(r.screenshot)
        XCTAssertFalse(r.screenshot?.isEmpty ?? true, "som mode must return a screenshot")
        XCTAssertFalse(cap.captureCalls.isEmpty, "som mode must call the screen-capture seam")
        XCTAssertFalse(r.treeNodes.isEmpty, "som mode must return a real tree")
        XCTAssertNotNil(r.treeText)
    }

    /// Explicit `mode: "som"` → identical to default.
    func testGetAppStateSomModeCapturesScreenshotAndTree() {
        let (mgr, _, cap, _, _) = makeHarness(
            bundleId: "com.example.NativeApp", flags: flags(), tree: [button()])
        let r = mgr.execute("get_app_state", ["window_id": appWindow, "mode": "som"])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertFalse(r.screenshot?.isEmpty ?? true)
        XCTAssertFalse(cap.captureCalls.isEmpty)
        XCTAssertFalse(r.treeNodes.isEmpty)
    }

    /// `mode: "ax"` → no screenshot AND the screen-capture seam is NOT called (the
    /// no-Screen-Recording-permission benefit), but the tree is still present.
    func testGetAppStateAXModeSkipsScreenCaptureButKeepsTree() {
        let (mgr, _, cap, _, _) = makeHarness(
            bundleId: "com.example.NativeApp", flags: flags(), tree: [button()])
        let r = mgr.execute("get_app_state", ["window_id": appWindow, "mode": "ax"])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertNil(r.screenshot, "ax mode must NOT produce a screenshot")
        XCTAssertTrue(cap.captureCalls.isEmpty,
                      "ax mode must not invoke the screen-capture seam at all (no Screen Recording)")
        XCTAssertFalse(r.treeNodes.isEmpty, "ax mode must still return the accessibility tree")
        XCTAssertNotNil(r.treeText)
    }

    /// `mode: "vision"` → screenshot present, but the tree text is replaced by the
    /// vision-mode placeholder (tree omitted from the response).
    func testGetAppStateVisionModeKeepsScreenshotOmitsTreeText() {
        let (mgr, _, cap, _, _) = makeHarness(
            bundleId: "com.example.NativeApp", flags: flags(), tree: [button()])
        let r = mgr.execute("get_app_state", ["window_id": appWindow, "mode": "vision"])
        XCTAssertNil(r.error, r.error ?? "")
        XCTAssertFalse(r.screenshot?.isEmpty ?? true, "vision mode must return a screenshot")
        XCTAssertFalse(cap.captureCalls.isEmpty, "vision mode still captures the screen")
        XCTAssertNotNil(r.treeText)
        XCTAssertTrue(r.treeText?.contains("vision mode") ?? false,
                      "vision mode must replace the tree text with the omitted-tree placeholder")
        XCTAssertTrue(r.treeText?.contains("accessibility tree omitted") ?? false)
    }

    // ======================================================================
    // MARK: - US-060 — canvas / foreground-only surface error
    // ======================================================================

    /// A pixel (x/y) click against a known canvas surface (Blender GHOST) throws an
    /// `AutomationError` with `kind == .unsupportedSurface` rather than silently
    /// dropping the doomed click. `execute()` is failproof (never throws), so the
    /// error surfaces on the response; assert the throwing behavior directly via
    /// the handler too so the thrown KIND is pinned.
    func testCanvasSurfacePixelClickThrowsUnsupportedSurface() {
        let (mgr, _, _, _, _) = makeHarness(bundleId: "org.blender.blender", flags: flags())

        // Drive the handler directly so XCTAssertThrowsError can pin the thrown
        // AutomationError.kind (execute() catches and converts to a response).
        let session = try! mgr.getOrCreateSessionForWindow(appWindow)
        XCTAssertEqual(session.target.bundleId, "org.blender.blender")
        XCTAssertThrowsError(
            try mgr.handleClick(session, ["x": 120.0, "y": 140.0])
        ) { error in
            guard let autoErr = error as? AutomationError else {
                return XCTFail("expected AutomationError, got \(error)")
            }
            XCTAssertEqual(autoErr.kind, .unsupportedSurface,
                           "a canvas-surface pixel click must raise an unsupportedSurface error")
            XCTAssertTrue(
                autoErr.message.lowercased().contains("activation")
                    || autoErr.message.contains("Prime Invariant"),
                "the message should explain the activation / Prime-Invariant reason: \(autoErr.message)")
        }
    }

    /// The same click through the full failproof `execute(...)` path surfaces the
    /// unsupported-surface message on the response error (never throwing out).
    func testCanvasSurfacePixelClickSurfacesErrorThroughExecute() {
        let (mgr, _, _, _, _) = makeHarness(bundleId: "org.blender.blender", flags: flags())
        let r = mgr.execute("click", ["window_id": appWindow, "x": 120.0, "y": 140.0])
        XCTAssertNotNil(r.error, "a canvas pixel click must report an error, not a silent success")
        XCTAssertTrue(
            (r.error?.lowercased().contains("activation") ?? false)
                || (r.error?.contains("Prime Invariant") ?? false)
                || (r.error?.lowercased().contains("unsupported") ?? false),
            "the response error should explain the canvas/activation limitation: \(r.error ?? "")")
    }

    /// Sanity: a normal (non-canvas) app's pixel click does NOT raise an
    /// unsupported-surface error — it delivers via clickAt.
    func testNormalAppPixelClickDoesNotThrowUnsupportedSurface() {
        let (mgr, input, _, _, _) = makeHarness(bundleId: "com.example.NativeApp", flags: flags())
        let session = try! mgr.getOrCreateSessionForWindow(appWindow)
        XCTAssertNoThrow(try mgr.handleClick(session, ["x": 120.0, "y": 140.0]))
        XCTAssertFalse(input.clicks.isEmpty, "a normal pixel click should deliver via clickAt")
    }
}
