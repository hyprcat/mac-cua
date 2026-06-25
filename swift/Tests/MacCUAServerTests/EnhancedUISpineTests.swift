import XCTest
import MacCUACore
@testable import MacCUAServer

/// Spine wiring for A1 (US-019): on attach, Chromium/Electron sessions get
/// enhanced UI primed (enableEnhancedUI + re-walk), native apps do not, and
/// priming happens at most once per session.
final class EnhancedUISpineTests: XCTestCase {

    private func makeSession(appType: AppType) -> AppSession {
        let target = AppTarget(
            bundleId: "com.example", pid: 321, windowId: 10, windowPid: 321,
            axApp: FakeAXRef("app"), axWindow: FakeAXRef("win"))
        let session = AppSession(target: target)
        session.appType = appType
        return session
    }

    func testPrimesEnhancedUIForElectron() {
        let ax = FakeAccessibility()
        // Web content present -> poll stops as soon as the web area appears.
        ax.tree = [Node(index: 0, role: "web area", depth: 0, isWebArea: true, axRole: "AXWebArea")]
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .electron)

        mgr.primeEnhancedUI(session)

        XCTAssertEqual(ax.enhancedUIPids, [321])
        XCTAssertTrue(session.enhancedUIPrimed)
        XCTAssertEqual(ax.walkCount, 1)
    }

    func testPrimesEnhancedUIForBrowser() {
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "web area", depth: 0, isWebArea: true, axRole: "AXWebArea")]
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .browser)

        mgr.primeEnhancedUI(session)
        XCTAssertEqual(ax.enhancedUIPids, [321])
    }

    func testSkipsNativeCocoa() {
        let ax = FakeAccessibility()
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .nativeCocoa)

        mgr.primeEnhancedUI(session)
        XCTAssertTrue(ax.enhancedUIPids.isEmpty)
        XCTAssertFalse(session.enhancedUIPrimed)
    }

    func testPrimesAtMostOncePerSession() {
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "web area", depth: 0, isWebArea: true, axRole: "AXWebArea")]
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .electron)

        mgr.primeEnhancedUI(session)
        mgr.primeEnhancedUI(session)
        XCTAssertEqual(ax.enhancedUIPids, [321])  // exactly once
    }

    func testRewalkPollsUntilAttemptsExhaustedWithoutWebContent() {
        // A tree that never shows an AXWebArea -> the re-walk loop exhausts its
        // attempts (proves chrome-only / empty trees do not abort the poll early;
        // it now stops on "web content appeared", not "tree non-empty").
        let ax = FakeAccessibility()
        ax.tree = []
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .electron)

        mgr.primeEnhancedUI(session)
        // Priming policy: no web content ever -> walks all priming attempts.
        XCTAssertEqual(ax.walkCount, EnhancedUIRewalkPolicy.priming.maxAttempts)
    }
}
