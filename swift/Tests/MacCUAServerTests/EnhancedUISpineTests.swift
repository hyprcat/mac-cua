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
        ax.tree = [Node(index: 0, role: "button", depth: 0)]  // non-empty -> poll stops fast
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .electron)

        mgr.primeEnhancedUI(session)

        XCTAssertEqual(ax.enhancedUIPids, [321])
        XCTAssertTrue(session.enhancedUIPrimed)
        XCTAssertGreaterThanOrEqual(ax.walkCount, 1)
    }

    func testPrimesEnhancedUIForBrowser() {
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "group", depth: 0)]
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
        ax.tree = [Node(index: 0, role: "button", depth: 0)]
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .electron)

        mgr.primeEnhancedUI(session)
        mgr.primeEnhancedUI(session)
        XCTAssertEqual(ax.enhancedUIPids, [321])  // exactly once
    }

    func testRewalkPollsWhenTreeStaysEmpty() {
        // Empty tree -> the re-walk loop exhausts its attempts (proves the first
        // walk being empty does not abort). Use a tiny interval to keep it fast.
        let ax = FakeAccessibility()
        ax.tree = []
        let mgr = SessionManager(providers: makeFakeProviders(accessibility: ax))
        let session = makeSession(appType: .electron)

        mgr.primeEnhancedUI(session)
        // Default policy = 5 attempts; an always-empty tree walks all 5.
        XCTAssertEqual(ax.walkCount, EnhancedUIRewalkPolicy().maxAttempts)
    }
}
