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

    func testNonActingStubDefaultsAreInert() {
        // Stubs must not act (Prime Invariant): the trivial-return bodies report
        // "nothing available / nothing happened", never foreground.
        XCTAssertTrue(KitAppResolver().listRunningApps().isEmpty)
        XCTAssertEqual(KitSettleMonitor().waitForSettle(context: "t", timeout: 1, quietPeriod: 0.1), .noChange)
    }

    func testPermissionSeamsReturnWithoutCrashing() {
        // US-015: the permission seams are now REAL (AXIsProcessTrustedWithOptions
        // / CGPreflightScreenCaptureAccess). They must answer a Bool without
        // prompting and without foregrounding. Value depends on the host's grant
        // state, so we only assert the call returns. `prompt: false` = query only.
        _ = KitAppResolver().checkAccessibilityPermission(prompt: false)
        _ = KitCaptureProvider().checkScreenRecordingPermission()
    }
}
#endif
