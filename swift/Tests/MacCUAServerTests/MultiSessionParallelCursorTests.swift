import XCTest
import MacCUACore
@testable import MacCUAServer

/// US-056 — Multi-session parallel-cursor acceptance test (K2, design §7.3).
///
/// The multi-agent payoff is that N sessions can drive N different apps *at the
/// same time*: each session owns a private synthetic event source (so two agents
/// never share an input pipeline), each driven window renders its own visually-
/// distinct ghost cursor, and NOTHING ever foregrounds/activates a target (Prime
/// Invariant / Inv 16). The real two-app behavior (Slack + Mail driven at once,
/// two cursors, neither foregrounded) is a MANUAL-VERIFY item; what is verifiable
/// on Linux is that the spine, driven against the fakes, keeps the two sessions
/// fully isolated:
///
///   * one private `EventSource` per session (two sessions ⇒ two distinct sources)
///   * every synthetic event for window A carries A's pid + A's source, and every
///     event for window B carries B's pid + B's source — zero cross-talk
///   * the `GhostCursorController` assigns each window a distinct tint
///   * no target app is ever activated; `restoreFrontmostApp` only ever restores
///     the USER's previously-frontmost app (Inv 16), never a driven target.
final class MultiSessionParallelCursorTests: XCTestCase {

    // Two distinct apps, each with one window.
    private let pidA = 501, windowA = 701
    private let pidB = 502, windowB = 702
    private let userApp = AppInfo(name: "UserApp", bundleId: "com.user.app", pid: 999, running: true)

    // Distinct AX roots + windows per app so each window_id binds to its own app.
    private let axAppA = FakeAXRef("ax-app-A")
    private let axAppB = FakeAXRef("ax-app-B")
    private let axWinA = FakeAXRef("ax-win-A")
    private let axWinB = FakeAXRef("ax-win-B")

    private func apps() -> FakeAppResolver {
        let a = FakeAppResolver()
        a.running = [
            AppInfo(name: "AppA", bundleId: "com.example.A", pid: pidA, running: true),
            AppInfo(name: "AppB", bundleId: "com.example.B", pid: pidB, running: true),
        ]
        a.axAppForPid = [pidA: axAppA, pidB: axAppB]
        // The user is in a THIRD app — driving A and B must never foreground either.
        a.frontmost = userApp
        return a
    }

    private func capture() -> FakeCapture {
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowA, ownerPid: pidA, ownerName: "AppA",
                       title: "DocA", x: 0, y: 0, width: 800, height: 600, onscreen: true),
            WindowInfo(windowId: windowB, ownerPid: pidB, ownerName: "AppB",
                       title: "DocB", x: 900, y: 0, width: 800, height: 600, onscreen: true),
        ]
        cap.windowIdForAXWindow = { [windowA, windowB, axWinA, axWinB] ref in
            if ref === axWinA { return windowA }
            if ref === axWinB { return windowB }
            return nil
        }
        return cap
    }

    private func accessibility() -> FakeAccessibility {
        let ax = FakeAccessibility()
        ax.windowsForAXApp = { [axAppA, axAppB, axWinA, axWinB] axApp in
            if axApp === axAppA { return [axWinA] }
            if axApp === axAppB { return [axWinB] }
            return []
        }
        return ax
    }

    /// Confirmed-delivery ON so each session is handed a private per-session
    /// `EventSource` (the isolation seam under test).
    private func flags() -> FeatureFlags {
        FeatureFlags(
            treePruning: false,
            userInterruptionDetection: false,
            focusEnforcement: false,
            menuTracking: false,
            transientGraphs: false,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: false,
            confirmedDelivery: true)
    }

    func testTwoSessionsDriveTwoAppsWithoutCrossTalkOrForegrounding() {
        let input = FakeInput()
        let appResolver = apps()
        let cap = capture()
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: appResolver, accessibility: accessibility(),
                                         input: input, capture: cap),
            flags: flags())

        // Drive both apps "concurrently": interleave coordinate clicks so an event
        // for A is delivered, then one for B, then A again — exactly the pattern two
        // independent agents would produce against the one shared manager.
        let rA = mgr.execute("click", ["window_id": windowA, "x": 100.0, "y": 100.0])
        let rB = mgr.execute("click", ["window_id": windowB, "x": 200.0, "y": 200.0])
        let rA2 = mgr.execute("click", ["window_id": windowA, "x": 150.0, "y": 150.0])
        XCTAssertNil(rA.error, rA.error ?? "")
        XCTAssertNil(rB.error, rB.error ?? "")
        XCTAssertNil(rA2.error, rA2.error ?? "")

        // Two independent sessions, one per window.
        XCTAssertEqual(mgr.sessions.count, 2)
        guard let sA = mgr.sessions[windowA], let sB = mgr.sessions[windowB] else {
            return XCTFail("expected a session per window")
        }
        XCTAssertEqual(sA.target.pid, pidA)
        XCTAssertEqual(sB.target.pid, pidB)

        // --- Private per-session event source (no shared input pipeline) ---
        XCTAssertEqual(input.createdSourceCount, 2, "exactly one event source per session")
        guard let srcA = sA.eventSource, let srcB = sB.eventSource else {
            return XCTFail("each session must own a private event source")
        }
        let idA = ObjectIdentifier(srcA), idB = ObjectIdentifier(srcB)
        XCTAssertNotEqual(idA, idB, "the two sessions must not share an event source")

        // --- Zero cross-talk: every event rode the right session's source + pid ---
        let evA = input.events.filter { $0.windowId == windowA }
        let evB = input.events.filter { $0.windowId == windowB }
        XCTAssertEqual(evA.count, 2)
        XCTAssertEqual(evB.count, 1)
        for e in evA {
            XCTAssertEqual(e.pid, pidA, "A's event went to the wrong pid")
            XCTAssertEqual(e.sourceId, idA, "A's event rode B's (or no) source")
        }
        for e in evB {
            XCTAssertEqual(e.pid, pidB, "B's event went to the wrong pid")
            XCTAssertEqual(e.sourceId, idB, "B's event rode A's (or no) source")
        }
        // No event ever crossed pid↔window wires.
        XCTAssertFalse(input.events.contains { $0.pid == pidA && $0.windowId == windowB })
        XCTAssertFalse(input.events.contains { $0.pid == pidB && $0.windowId == windowA })

        // --- Multi-cursor identity: two windows ⇒ two distinct tints ---
        XCTAssertEqual(mgr.ghostController.trackedWindowCount, 2)
        let styleA = mgr.ghostController.style(forWindowId: windowA)
        let styleB = mgr.ghostController.style(forWindowId: windowB)
        XCTAssertNotNil(styleA)
        XCTAssertNotNil(styleB)
        XCTAssertNotEqual(styleA, styleB, "concurrent windows must render distinct ghost tints")

        // --- No foregrounding: a target is never activated; only the USER's app is
        // ever restored to front (Inv 16). ---
        for restored in appResolver.restoreCalls {
            XCTAssertEqual(restored?.bundleId, userApp.bundleId,
                           "only the user's previous frontmost app may be restored — never a driven target")
        }
        XCTAssertNotEqual(appResolver.frontmost?.pid, pidA, "user frontmost must not become a driven target")
        XCTAssertNotEqual(appResolver.frontmost?.pid, pidB)
    }

    /// A torn-down session's tint is freed and reused by a fresh session, and two
    /// live windows never share a color until the palette is exhausted (§7.3).
    func testTintReuseAcrossSessionTeardown() {
        let mgr = SessionManager(providers: makeFakeProviders(), flags: flags())
        let ctl = mgr.ghostController

        let s1 = ctl.startTracking(windowId: windowA)
        let s2 = ctl.startTracking(windowId: windowB)
        XCTAssertNotEqual(s1, s2)

        // Tear down A — its tint slot frees up.
        ctl.stopTracking(windowId: windowA)
        XCTAssertEqual(ctl.trackedWindowCount, 1)

        // A fresh window reuses the freed tint (A's), never colliding with the still-
        // live B.
        let s3 = ctl.startTracking(windowId: 703)
        XCTAssertEqual(s3, s1, "a freed tint is reused by the next new window")
        XCTAssertNotEqual(s3, s2, "the reused tint must not collide with the live window")
    }
}
