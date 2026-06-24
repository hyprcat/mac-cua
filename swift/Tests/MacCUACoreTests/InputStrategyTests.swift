import XCTest
@testable import MacCUACore

// Ports tests/test_virtual_cursor.py intent, plus coverage for the pure parts
// not exercised by the Python test (strategy matrix, AX-failure escalation,
// app-type detection, BackgroundCursor logical-position model).

final class InputStrategyTests: XCTestCase {

    // MARK: - Delivery method (mirrors InputStrategyDeliveryTests)

    func testNativeCocoaUsesCGEventDelivery() {
        XCTAssertEqual(InputStrategy(appType: .nativeCocoa).deliveryMethod, .cgeventPid)
    }

    func testElectronUsesSkylightDelivery() {
        XCTAssertEqual(InputStrategy(appType: .electron).deliveryMethod, .skylightSpi)
    }

    func testBrowserUsesSkylightDelivery() {
        XCTAssertEqual(InputStrategy(appType: .browser).deliveryMethod, .skylightSpi)
    }

    func testJavaUsesSkylightDelivery() {
        XCTAssertEqual(InputStrategy(appType: .java).deliveryMethod, .skylightSpi)
    }

    func testQtUsesSkylightDelivery() {
        XCTAssertEqual(InputStrategy(appType: .qt).deliveryMethod, .skylightSpi)
    }

    func testUnknownUsesCGEventDelivery() {
        XCTAssertEqual(InputStrategy(appType: .unknown).deliveryMethod, .cgeventPid)
    }

    // MARK: - Activation policy

    func testNativeCocoaActivationIsNever() {
        XCTAssertEqual(InputStrategy(appType: .nativeCocoa).activationPolicy, .never)
    }

    func testElectronActivationIsRetryOnly() {
        XCTAssertEqual(InputStrategy(appType: .electron).activationPolicy, .retryOnly)
    }

    func testUnknownActivationIsNever() {
        XCTAssertEqual(InputStrategy(appType: .unknown).activationPolicy, .never)
    }

    func testNativeCocoaPopupActivationIsRetry() {
        XCTAssertEqual(InputStrategy(appType: .nativeCocoa).activationPolicyForPopup, .retryOnly)
    }

    func testElectronPopupActivationIsRetry() {
        XCTAssertEqual(InputStrategy(appType: .electron).activationPolicyForPopup, .retryOnly)
    }

    // MARK: - Alternate delivery

    func testAlternateDeliveryReturnsOtherMethod() {
        XCTAssertEqual(InputStrategy(appType: .nativeCocoa).alternateDeliveryMethod, .skylightSpi)
        XCTAssertEqual(InputStrategy(appType: .electron).alternateDeliveryMethod, .cgeventPid)
    }

    // MARK: - shouldUseAXAction matrix

    func testNativeCocoaPrefersAXForAllActions() {
        let s = InputStrategy(appType: .nativeCocoa)
        XCTAssertTrue(s.shouldUseAXAction(.click))
        XCTAssertTrue(s.shouldUseAXAction(.type))
        XCTAssertTrue(s.shouldUseAXAction(.scroll))
        XCTAssertTrue(s.shouldUseAXAction(.focus))
    }

    func testBrowserChromePrefersAX() {
        let s = InputStrategy(appType: .browser)
        XCTAssertTrue(s.shouldUseAXAction(.click, isWebArea: false))
    }

    func testBrowserWebAreaAlwaysUsesCGEvent() {
        let s = InputStrategy(appType: .browser)
        XCTAssertFalse(s.shouldUseAXAction(.click, isWebArea: true))
        XCTAssertFalse(s.shouldUseAXAction(.focus, isWebArea: true))
    }

    func testElectronOnlyAXFocus() {
        let s = InputStrategy(appType: .electron)
        XCTAssertTrue(s.shouldUseAXAction(.focus))
        XCTAssertFalse(s.shouldUseAXAction(.click))
        XCTAssertFalse(s.shouldUseAXAction(.type))
        XCTAssertFalse(s.shouldUseAXAction(.scroll))
    }

    func testJavaQtUnknownAlwaysCGEvent() {
        for t in [AppType.java, .qt, .unknown] {
            let s = InputStrategy(appType: t)
            XCTAssertFalse(s.shouldUseAXAction(.focus), "\(t) focus should be CGEvent")
            XCTAssertFalse(s.shouldUseAXAction(.click), "\(t) click should be CGEvent")
        }
    }

    func testForceSimulateDisablesAX() {
        let s = InputStrategy(appType: .nativeCocoa, forceSimulate: true)
        XCTAssertFalse(s.shouldUseAXAction(.click))
        XCTAssertFalse(s.shouldUseAXAction(.focus))
    }

    // MARK: - AX-failure auto-escalation

    func testAXFailureEscalationDisablesAXAfterTwo() {
        let s = InputStrategy(appType: .nativeCocoa)
        XCTAssertTrue(s.shouldUseAXAction(.click))
        s.recordAXFailure()
        XCTAssertTrue(s.shouldUseAXAction(.click))  // 1 failure: still AX
        s.recordAXFailure()
        XCTAssertFalse(s.shouldUseAXAction(.click)) // 2 failures: escalated
    }

    func testResetFailuresRestoresAX() {
        let s = InputStrategy(appType: .nativeCocoa)
        s.recordAXFailure()
        s.recordAXFailure()
        XCTAssertFalse(s.shouldUseAXAction(.click))
        s.resetFailures()
        XCTAssertTrue(s.shouldUseAXAction(.click))
    }

    // MARK: - App-type detection

    func testDetectBrowserBundle() {
        XCTAssertEqual(detectAppType(bundleId: "com.google.Chrome", pid: 1), .browser)
        XCTAssertEqual(detectAppType(bundleId: "com.apple.Safari", pid: 1), .browser)
    }

    func testDetectElectronBundle() {
        XCTAssertEqual(detectAppType(bundleId: "com.microsoft.VSCode", pid: 1), .electron)
        XCTAssertEqual(detectAppType(bundleId: "com.tinyspeck.slackmacgap", pid: 1), .electron)
    }

    func testDetectDefaultsToNativeCocoaWithoutProbe() {
        XCTAssertEqual(detectAppType(bundleId: "com.apple.TextEdit", pid: 1), .nativeCocoa)
    }

    func testDetectUsesProbeForUnknownBundle() {
        final class FakeProbe: ProcessLibraryProbing {
            let output: String?
            init(_ output: String?) { self.output = output }
            func loadedLibraries(pid: Int) -> String? { output }
        }
        XCTAssertEqual(
            detectAppType(bundleId: "com.x.Unknown", pid: 1,
                          probe: FakeProbe("/path/Electron Framework")), .electron)
        XCTAssertEqual(
            detectAppType(bundleId: "com.x.Unknown", pid: 1,
                          probe: FakeProbe("/usr/lib/libjvm.dylib")), .java)
        XCTAssertEqual(
            detectAppType(bundleId: "com.x.Unknown", pid: 1,
                          probe: FakeProbe("/opt/QtCore.framework")), .qt)
        // No match -> falls through to native cocoa
        XCTAssertEqual(
            detectAppType(bundleId: "com.x.Unknown", pid: 1,
                          probe: FakeProbe("/usr/lib/libSomething.dylib")), .nativeCocoa)
        // Probe failure (nil) -> native cocoa
        XCTAssertEqual(
            detectAppType(bundleId: "com.x.Unknown", pid: 1,
                          probe: FakeProbe(nil)), .nativeCocoa)
    }

    func testBundleSetsTakePrecedenceOverProbe() {
        final class CrashProbe: ProcessLibraryProbing {
            func loadedLibraries(pid: Int) -> String? {
                XCTFail("probe must not run when bundle matches")
                return nil
            }
        }
        XCTAssertEqual(
            detectAppType(bundleId: "com.google.Chrome", pid: 1, probe: CrashProbe()),
            .browser)
    }

    func testClassifyLibraries() {
        XCTAssertEqual(classifyLibraries("electron helper"), .electron)
        XCTAssertEqual(classifyLibraries("JavaNativeFoundation"), .java)
        XCTAssertEqual(classifyLibraries("QtWidgets"), .qt)
        XCTAssertNil(classifyLibraries("nothing relevant"))
    }

    // MARK: - C1 click delivery order (pointer-first vs AX-first)

    func testNativeCocoaControlIsAXFirst() {
        let s = InputStrategy(appType: .nativeCocoa)
        // A normal native button with a working AXPress -> AX-first.
        XCTAssertFalse(s.preferPointerForClick(
            role: "button", axRole: "AXButton", actionNames: ["AXPress"]))
    }

    func testMenuItemIsAXFirstWhereAXClicksWork() {
        // Where the app-type click policy permits AX (native Cocoa, browser
        // chrome), a menu item is AX-first: not buttonish, no web ancestor.
        for t in [AppType.nativeCocoa, .browser] {
            let s = InputStrategy(appType: t)
            XCTAssertFalse(
                s.preferPointerForClick(role: "menu item", axRole: "AXMenuItem"),
                "\(t) menu item should be AX-first")
        }
        // In Electron the click policy is CGEvent for everything but focus, so
        // even a menu item is delivered pointer-first (faithful to Python's
        // should_use_ax_action gate running first).
        XCTAssertTrue(
            InputStrategy(appType: .electron).preferPointerForClick(
                role: "menu item", axRole: "AXMenuItem"))
    }

    func testElectronControlIsPointerFirst() {
        // Electron click policy -> CGEvent -> pointer-first regardless of role.
        let s = InputStrategy(appType: .electron)
        XCTAssertTrue(s.preferPointerForClick(
            role: "button", axRole: "AXButton", actionNames: ["AXPress"]))
    }

    func testBrowserWebAreaControlIsPointerFirst() {
        let s = InputStrategy(appType: .browser)
        XCTAssertTrue(s.preferPointerForClick(
            role: "button", axRole: "AXButton", isWebArea: true, actionNames: ["AXPress"]))
    }

    func testBrowserChromeNativeControlIsAXFirst() {
        // Browser chrome (not web content) behaves like native Cocoa.
        let s = InputStrategy(appType: .browser)
        XCTAssertFalse(s.preferPointerForClick(
            role: "button", axRole: "AXButton", isWebArea: false, actionNames: ["AXPress"]))
    }

    func testHasWebAncestorForcesPointerEvenInNativeApp() {
        let s = InputStrategy(appType: .nativeCocoa)
        XCTAssertTrue(s.preferPointerForClick(
            role: "link", axRole: "AXLink", hasWebAncestor: true))
    }

    func testButtonishWithNoActivatingActionForcesPointer() {
        let s = InputStrategy(appType: .nativeCocoa)
        // Buttonish role advertising only non-activating actions -> pointer.
        XCTAssertTrue(s.preferPointerForClick(
            role: "button", axRole: "AXButton", actionNames: ["AXShowMenu"]))
    }

    func testNonPointerPreferredRoleIsAXFirst() {
        let s = InputStrategy(appType: .nativeCocoa)
        // A static-text-ish role isn't pointer-preferred -> AX-first.
        XCTAssertFalse(s.preferPointerForClick(
            role: "text", axRole: "AXStaticText", actionNames: ["AXPress"]))
    }

    func testShouldForcePointerForNodeMatrix() {
        // Empty actions -> never force.
        XCTAssertFalse(InputStrategy.shouldForcePointerForNode(axRole: "AXButton", actionNames: []))
        // Non-buttonish role -> never force.
        XCTAssertFalse(InputStrategy.shouldForcePointerForNode(
            axRole: "AXMenuItem", actionNames: ["AXShowMenu"]))
        // Buttonish + activating action present -> AX is fine, don't force.
        XCTAssertFalse(InputStrategy.shouldForcePointerForNode(
            axRole: "AXCheckBox", actionNames: ["AXPress", "AXShowMenu"]))
        // Buttonish + only non-activating actions -> force pointer.
        XCTAssertTrue(InputStrategy.shouldForcePointerForNode(
            axRole: "AXRadioButton", actionNames: ["AXShowMenu"]))
    }

    func testForceSimulateMakesEveryClickPointerFirst() {
        let s = InputStrategy(appType: .nativeCocoa, forceSimulate: true)
        XCTAssertTrue(s.preferPointerForClick(
            role: "button", axRole: "AXButton", actionNames: ["AXPress"]))
        XCTAssertTrue(s.preferPointerForClick(role: "menu item", axRole: "AXMenuItem"))
    }

    func testAXFailureEscalationFlipsClickToPointerFirst() {
        let s = InputStrategy(appType: .nativeCocoa)
        XCTAssertFalse(s.preferPointerForClick(
            role: "button", axRole: "AXButton", actionNames: ["AXPress"]))
        s.recordAXFailure()
        s.recordAXFailure()
        XCTAssertTrue(s.preferPointerForClick(
            role: "button", axRole: "AXButton", actionNames: ["AXPress"]))
    }

    // MARK: - BackgroundCursor logical-position model

    func testMoveToUpdatesLogicalPositionOnly() {
        let c = BackgroundCursor(pid: 100, windowId: 5)
        XCTAssertEqual(c.position, Point(x: 0, y: 0))
        c.moveTo(Point(x: 42, y: 99))
        XCTAssertEqual(c.position, Point(x: 42, y: 99))
    }

    func testScaledCoordinatesUseScaleFactor() {
        let c = BackgroundCursor(pid: 100, windowId: 5)
        c.moveTo(Point(x: 20, y: 40))
        // default scale factor is 1.0
        XCTAssertEqual(c.positionInScaledCoordinates, Point(x: 20, y: 40))
    }

    func testClickUpdatesPositionAndForwardsToDelivery() {
        final class SpyDelivery: PointerEventDelivering {
            var lastClick: (Int, Int, Double, Double, PointerButton, Int)?
            var lastDrag: (Double, Double, Double, Double)?
            func clickAt(pid: Int, windowId: Int, x: Double, y: Double,
                         button: PointerButton, count: Int, screenshotSize: Size?) {
                lastClick = (pid, windowId, x, y, button, count)
            }
            func drag(pid: Int, windowId: Int, fromX: Double, fromY: Double,
                      toX: Double, toY: Double, screenshotSize: Size?) {
                lastDrag = (fromX, fromY, toX, toY)
            }
        }
        let spy = SpyDelivery()
        let c = BackgroundCursor(pid: 7, windowId: 9, delivery: spy)

        c.clickAt(Point(x: 1, y: 2))
        XCTAssertEqual(c.position, Point(x: 1, y: 2))
        XCTAssertEqual(spy.lastClick?.0, 7)
        XCTAssertEqual(spy.lastClick?.1, 9)
        XCTAssertEqual(spy.lastClick?.4, .left)
        XCTAssertEqual(spy.lastClick?.5, 1)

        c.doubleClickAt(Point(x: 3, y: 4))
        XCTAssertEqual(spy.lastClick?.5, 2)
        XCTAssertEqual(spy.lastClick?.4, .left)

        c.rightClickAt(Point(x: 5, y: 6))
        XCTAssertEqual(spy.lastClick?.4, .right)
        XCTAssertEqual(c.position, Point(x: 5, y: 6))

        c.drag(from: Point(x: 0, y: 0), to: Point(x: 10, y: 20))
        XCTAssertEqual(c.position, Point(x: 10, y: 20))
        XCTAssertEqual(spy.lastDrag?.2, 10)
        XCTAssertEqual(spy.lastDrag?.3, 20)
    }

    func testCursorWorksWithoutDeliverySeam() {
        // Pure path: no delivery wired; methods only update logical position.
        let c = BackgroundCursor(pid: 1, windowId: 1)
        c.clickAt(Point(x: 11, y: 22))
        XCTAssertEqual(c.position, Point(x: 11, y: 22))
        c.drag(from: Point(x: 0, y: 0), to: Point(x: 5, y: 5))
        XCTAssertEqual(c.position, Point(x: 5, y: 5))
    }
}
