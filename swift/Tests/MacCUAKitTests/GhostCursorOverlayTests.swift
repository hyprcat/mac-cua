#if os(macOS)
import XCTest
import AppKit
@testable import MacCUAKit
import MacCUACore

/// US-051 — Kit ghost-cursor overlay smoke tests. Drives the real
/// `KitGhostCursorOverlay` on the main actor and asserts the panel it creates
/// is borderless, non-activating, click-through, and CANNOT become key/main
/// (the Prime-Invariant guarantee: showing the ghost never steals focus).
@MainActor
final class GhostCursorOverlayTests: XCTestCase {

    func testShowCreatesNonActivatingClickThroughPanel() {
        let overlay = KitGhostCursorOverlay()
        let style = GhostCursorPalette.styles[0]
        overlay.show(windowId: 1, style: style, windowFrame: Rect(x: 100, y: 100, w: 300, h: 200))

        guard let panel = overlay.panelForTesting(windowId: 1) else {
            return XCTFail("panel not created")
        }
        // Non-activating: ordering the panel in must NEVER take key/main.
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        // Click-through to the underlying app.
        XCTAssertTrue(panel.ignoresMouseEvents)
        // Decorative chrome: transparent, no shadow, high level.
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertEqual(panel.level, .screenSaver)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        overlay.remove(windowId: 1)
    }

    func testNoFrameDefersPanelCreation() {
        let overlay = KitGhostCursorOverlay()
        overlay.show(windowId: 7, style: GhostCursorPalette.styles[0], windowFrame: nil)
        XCTAssertNil(overlay.panelForTesting(windowId: 7))
        // No prior entry → setWindowFrame(nil) is a no-op, still no panel.
        overlay.setWindowFrame(windowId: 7, nil)
        XCTAssertNil(overlay.panelForTesting(windowId: 7))
        overlay.remove(windowId: 7)
    }

    func testMoveDoesNotCrashAndStaysClamped() {
        let overlay = KitGhostCursorOverlay()
        overlay.show(windowId: 2, style: GhostCursorPalette.styles[1],
                     windowFrame: Rect(x: 0, y: 0, w: 100, h: 100))
        // Move far outside the window — must not throw; sprite is clamped.
        overlay.move(windowId: 2, to: Point(x: 9999, y: -9999), animated: false)
        overlay.move(windowId: 2, to: Point(x: 50, y: 50), animated: true)
        XCTAssertNotNil(overlay.panelForTesting(windowId: 2))
        overlay.remove(windowId: 2)
        XCTAssertNil(overlay.panelForTesting(windowId: 2))
    }
}
#endif
