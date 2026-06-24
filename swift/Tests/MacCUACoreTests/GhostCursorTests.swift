import XCTest
@testable import MacCUACore

/// Records every call the `GhostCursorController` makes to its overlay seam, so
/// the pure registry/clamp/palette logic can be asserted on Linux without any
/// AppKit (render is deferred to Phase 6).
final class FakeGhostOverlay: GhostCursorOverlay {
    struct Shown: Equatable { let windowId: Int; let style: GhostCursorStyle; let frame: Rect? }
    struct Moved: Equatable { let windowId: Int; let point: Point; let animated: Bool }

    var shown: [Shown] = []
    var moved: [Moved] = []
    var framed: [Int: Rect?] = [:]
    var hidden: [Int] = []
    var removed: [Int] = []

    func show(windowId: Int, style: GhostCursorStyle, windowFrame: Rect?) {
        shown.append(Shown(windowId: windowId, style: style, frame: windowFrame))
    }
    func move(windowId: Int, to point: Point, animated: Bool) {
        moved.append(Moved(windowId: windowId, point: point, animated: animated))
    }
    func setWindowFrame(windowId: Int, _ frame: Rect?) { framed[windowId] = frame }
    func hide(windowId: Int) { hidden.append(windowId) }
    func remove(windowId: Int) { removed.append(windowId) }
}

final class GhostCursorTests: XCTestCase {

    // MARK: clampPointToWindow (pure)

    func testClampInsideUnchanged() {
        let frame = Rect(x: 100, y: 100, w: 200, h: 100)
        let p = GhostCursorController.clampPointToWindow(Point(x: 150, y: 140), frame)
        XCTAssertEqual(p, Point(x: 150, y: 140))
    }

    func testClampOutsideClampsToEdges() {
        let frame = Rect(x: 100, y: 100, w: 200, h: 100)
        XCTAssertEqual(
            GhostCursorController.clampPointToWindow(Point(x: -50, y: 5000), frame),
            Point(x: 100, y: 200))
        XCTAssertEqual(
            GhostCursorController.clampPointToWindow(Point(x: 9999, y: 50), frame),
            Point(x: 300, y: 100))
    }

    func testClampDegenerateFrameReturnsPointUnchanged() {
        let frame = Rect(x: 0, y: 0, w: 0, h: 0)
        XCTAssertEqual(
            GhostCursorController.clampPointToWindow(Point(x: 42, y: 7), frame),
            Point(x: 42, y: 7))
    }

    // MARK: palette rotation + per-window registry

    func testDistinctTintsPerWindowAndStableOnRetrack() {
        let c = GhostCursorController()
        let s1 = c.startTracking(windowId: 1)
        let s2 = c.startTracking(windowId: 2)
        XCTAssertNotEqual(s1, s2)
        // Re-tracking the same window keeps the same tint (idempotent).
        XCTAssertEqual(c.startTracking(windowId: 1), s1)
        XCTAssertEqual(c.style(forWindowId: 2), s2)
    }

    func testPaletteWrapsAround() {
        let palette = [
            GhostCursorStyle(name: "a", red: 1, green: 0, blue: 0),
            GhostCursorStyle(name: "b", red: 0, green: 1, blue: 0),
        ]
        let c = GhostCursorController(palette: palette)
        XCTAssertEqual(c.startTracking(windowId: 10).name, "a")
        XCTAssertEqual(c.startTracking(windowId: 11).name, "b")
        XCTAssertEqual(c.startTracking(windowId: 12).name, "a")  // wrapped
    }

    func testStopTrackingForgetsWindow() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 5)
        XCTAssertNotNil(c.style(forWindowId: 5))
        c.stopTracking(windowId: 5)
        XCTAssertNil(c.style(forWindowId: 5))
        XCTAssertEqual(overlay.removed, [5])
    }

    // MARK: overlay drive + clamping

    func testMoveClampsToTrackedFrameAndForwardsToOverlay() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 9, windowFrame: Rect(x: 0, y: 0, w: 100, h: 100))
        c.move(windowId: 9, to: Point(x: 500, y: 50), animated: true)
        XCTAssertEqual(overlay.moved, [.init(windowId: 9, point: Point(x: 100, y: 50), animated: true)])
    }

    func testMoveWithoutFrameIsUnclamped() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 3)  // no frame
        c.move(windowId: 3, to: Point(x: 500, y: 600))
        XCTAssertEqual(overlay.moved.first?.point, Point(x: 500, y: 600))
    }

    func testWindowMovedUpdatesFrameUsedForClamp() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 1, windowFrame: Rect(x: 0, y: 0, w: 10, h: 10))
        c.windowMoved(windowId: 1, frame: Rect(x: 0, y: 0, w: 1000, h: 1000))
        c.move(windowId: 1, to: Point(x: 500, y: 500))
        XCTAssertEqual(overlay.moved.last?.point, Point(x: 500, y: 500))  // now in-bounds
    }

    // MARK: BackgroundCursor chokepoint (US-039)

    func testBackgroundCursorMoveDrivesGhost() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 42, windowFrame: Rect(x: 0, y: 0, w: 1000, h: 1000))
        let cursor = BackgroundCursor(pid: 1, windowId: 42)
        cursor.ghost = c

        cursor.moveTo(Point(x: 30, y: 40))
        XCTAssertEqual(cursor.position, Point(x: 30, y: 40))
        XCTAssertEqual(overlay.moved.last?.point, Point(x: 30, y: 40))
    }

    func testBackgroundCursorClickAndDragDriveGhost() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 7, windowFrame: Rect(x: 0, y: 0, w: 1000, h: 1000))
        let cursor = BackgroundCursor(pid: 1, windowId: 7)
        cursor.ghost = c

        cursor.clickAt(Point(x: 5, y: 6))
        cursor.drag(from: Point(x: 5, y: 6), to: Point(x: 9, y: 9))
        XCTAssertEqual(overlay.moved.map { $0.point }, [Point(x: 5, y: 6), Point(x: 9, y: 9)])
        // The drag move is animated (a "scoot"); the click is not.
        XCTAssertEqual(overlay.moved.last?.animated, true)
    }

    func testBackgroundCursorWithoutGhostStillUpdatesLogicalPosition() {
        let cursor = BackgroundCursor(pid: 1, windowId: 1)  // no ghost
        cursor.moveTo(Point(x: 11, y: 22))
        XCTAssertEqual(cursor.position, Point(x: 11, y: 22))
    }

    // MARK: DeliveryPath.classify (F / US-039)

    func testClassifyCGEventPaths() {
        XCTAssertEqual(DeliveryPath.classify(message: "Clicked element 3 (CGEventPostToPid)"), .cgEvent)
        XCTAssertEqual(
            DeliveryPath.classify(message: "Clicked at (1, 2) (CGEventPostToPid, refreshed window)"),
            .cgEvent)
        XCTAssertEqual(
            DeliveryPath.classify(message: "Typed 'hi' into element 2 (background key events)"),
            .cgEvent)
        XCTAssertEqual(DeliveryPath.classify(message: "Dragged from (0, 0) to (5, 5)"), .cgEvent)
    }

    func testClassifyAXPaths() {
        XCTAssertEqual(DeliveryPath.classify(message: "Clicked element 1 (AXPress)"), .axPress)
        XCTAssertEqual(DeliveryPath.classify(message: "Clicked element 1 (AX hit-test)"), .axPress)
        XCTAssertEqual(DeliveryPath.classify(message: "Clicked element 1 (AXSelected)"), .axPress)
        XCTAssertEqual(DeliveryPath.classify(message: "Set value of element 1 to 'x' (AXValue)"), .axPress)
        XCTAssertEqual(
            DeliveryPath.classify(message: "Typed 'x' into element 1 (EditableTextObject.insertText)"),
            .axPress)
    }

    func testClassifyScroll() {
        XCTAssertEqual(DeliveryPath.classify(message: "Scrolled element 2 down (1 page(s))"), .wheel)
    }

    // MARK: GhostWindowTrackingState (pure, US-052)

    func testTrackFirstVisibleSampleFollows() {
        var st = GhostWindowTrackingState()
        let f = Rect(x: 10, y: 20, w: 300, h: 200)
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f, isOnscreen: true)), .follow(f))
    }

    func testTrackUnchangedFrameIsNone() {
        var st = GhostWindowTrackingState()
        let f = Rect(x: 10, y: 20, w: 300, h: 200)
        _ = st.update(GhostWindowSample(bounds: f, isOnscreen: true))
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f, isOnscreen: true)), .none)
    }

    func testTrackMovedOrResizedFollows() {
        var st = GhostWindowTrackingState()
        let f1 = Rect(x: 10, y: 20, w: 300, h: 200)
        let f2 = Rect(x: 500, y: 20, w: 300, h: 200) // moved (e.g. to another display)
        _ = st.update(GhostWindowSample(bounds: f1, isOnscreen: true))
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f2, isOnscreen: true)), .follow(f2))
        let f3 = Rect(x: 500, y: 20, w: 400, h: 250) // resized
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f3, isOnscreen: true)), .follow(f3))
    }

    func testTrackOffscreenHidesOnce() {
        var st = GhostWindowTrackingState()
        let f = Rect(x: 10, y: 20, w: 300, h: 200)
        _ = st.update(GhostWindowSample(bounds: f, isOnscreen: true))
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f, isOnscreen: false)), .hide)
        // Still off-screen → no repeat hide.
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f, isOnscreen: false)), .none)
    }

    func testTrackAbsentSampleHides() {
        var st = GhostWindowTrackingState()
        let f = Rect(x: 10, y: 20, w: 300, h: 200)
        _ = st.update(GhostWindowSample(bounds: f, isOnscreen: true))
        XCTAssertEqual(st.update(nil), .hide)        // minimized / closed
        XCTAssertEqual(st.update(nil), .none)
    }

    func testTrackReappearFollows() {
        var st = GhostWindowTrackingState()
        let f = Rect(x: 10, y: 20, w: 300, h: 200)
        _ = st.update(GhostWindowSample(bounds: f, isOnscreen: true))
        _ = st.update(nil)                            // hidden
        // Reappears at the same frame → must follow (re-show), not stay none.
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f, isOnscreen: true)), .follow(f))
    }

    func testTrackInitiallyAbsentHidesOnce() {
        var st = GhostWindowTrackingState()
        XCTAssertEqual(st.update(nil), .hide)
        XCTAssertEqual(st.update(nil), .none)
    }

    func testTrackResetReplaysFollow() {
        var st = GhostWindowTrackingState()
        let f = Rect(x: 10, y: 20, w: 300, h: 200)
        _ = st.update(GhostWindowSample(bounds: f, isOnscreen: true))
        st.reset()
        XCTAssertEqual(st.update(GhostWindowSample(bounds: f, isOnscreen: true)), .follow(f))
    }

    // MARK: controller.apply drives the overlay (US-052)

    func testApplyFollowSetsWindowFrame() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 7)
        let f = Rect(x: 5, y: 5, w: 100, h: 100)
        c.apply(.follow(f), windowId: 7)
        XCTAssertEqual(overlay.framed[7], f)
    }

    func testApplyHideHidesWithoutForgettingTint() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        let tint = c.startTracking(windowId: 7)
        c.apply(.hide, windowId: 7)
        XCTAssertEqual(overlay.hidden, [7])
        // Tint preserved across hide so a re-show keeps the session's color.
        XCTAssertEqual(c.style(forWindowId: 7), tint)
    }

    func testApplyNoneDoesNothing() {
        let overlay = FakeGhostOverlay()
        let c = GhostCursorController(overlay: overlay)
        c.startTracking(windowId: 7)
        c.apply(.none, windowId: 7)
        XCTAssertTrue(overlay.hidden.isEmpty)
        XCTAssertTrue(overlay.framed.isEmpty)
    }

    // MARK: GhostCursorGeometry (pure, US-051)

    func testAppKitFrameFlipsYAgainstPrimaryHeight() {
        // A 200x100 window at CG top-left (100, 50) on a 900-tall primary screen:
        // bottom-left y = 900 - (50 + 100) = 750. x/w/h unchanged.
        let cg = Rect(x: 100, y: 50, w: 200, h: 100)
        let f = GhostCursorGeometry.appKitFrame(forCGRect: cg, primaryScreenHeight: 900)
        XCTAssertEqual(f, Rect(x: 100, y: 750, w: 200, h: 100))
    }

    func testAppKitFrameTopOfScreen() {
        // Window flush to the CG top (y=0) on an 800-tall screen → top in AppKit.
        let cg = Rect(x: 0, y: 0, w: 400, h: 300)
        let f = GhostCursorGeometry.appKitFrame(forCGRect: cg, primaryScreenHeight: 800)
        XCTAssertEqual(f, Rect(x: 0, y: 500, w: 400, h: 300))
    }

    func testSpritePointInPanelFlipsWithinWindow() {
        // Window CG rect (100,50,200,100). A CG point at the window's top-left
        // corner (100,50) maps to panel-local (0, h)=(0,100) (bottom-left origin).
        let rect = Rect(x: 100, y: 50, w: 200, h: 100)
        XCTAssertEqual(
            GhostCursorGeometry.spritePointInPanel(screenPoint: Point(x: 100, y: 50), windowCGRect: rect),
            Point(x: 0, y: 100))
        // The window's bottom-left CG corner (100, 150) → panel-local (0, 0).
        XCTAssertEqual(
            GhostCursorGeometry.spritePointInPanel(screenPoint: Point(x: 100, y: 150), windowCGRect: rect),
            Point(x: 0, y: 0))
        // Center (200, 100) → panel-local (100, 50).
        XCTAssertEqual(
            GhostCursorGeometry.spritePointInPanel(screenPoint: Point(x: 200, y: 100), windowCGRect: rect),
            Point(x: 100, y: 50))
    }
}
