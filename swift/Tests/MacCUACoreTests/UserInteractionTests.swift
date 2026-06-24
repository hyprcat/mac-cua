import XCTest
@testable import MacCUACore

final class UserInteractionTests: XCTestCase {
    private let safari = "com.apple.Safari"
    private let slack = "com.tinyspeck.slackmacgap"

    func testNoInteractionYieldsNil() {
        var s = UserInteractionState()
        XCTAssertNil(s.consumeInterruption(bundleId: safari, now: 100))
    }

    func testWithinDebounceNotYetInterrupted() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        // Only 0.3s elapsed — debounce hasn't fired.
        XCTAssertNil(s.consumeInterruption(bundleId: safari, now: 100.3))
    }

    func testAfterDebounceInterrupted() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        let msg = s.consumeInterruption(bundleId: safari, now: 100.5)
        XCTAssertEqual(msg, UserInteractionState.warningMessage(bundleId: safari))
    }

    func testOneShotConsume() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        XCTAssertNotNil(s.consumeInterruption(bundleId: safari, now: 101))
        // Second consume returns nil — one-shot.
        XCTAssertNil(s.consumeInterruption(bundleId: safari, now: 102))
    }

    func testRepeatedEventsResetDebounce() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        s.recordInteraction(bundleId: safari, now: 100.4)  // resets window
        // 0.5s after the FIRST event but only 0.1s after the last — not fired.
        XCTAssertNil(s.consumeInterruption(bundleId: safari, now: 100.5))
        // 0.5s after the last event — fired.
        XCTAssertNotNil(s.consumeInterruption(bundleId: safari, now: 100.9))
    }

    func testPerBundleIndependence() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        s.recordInteraction(bundleId: slack, now: 100)
        // Consuming Safari does not consume Slack.
        XCTAssertNotNil(s.consumeInterruption(bundleId: safari, now: 101))
        XCTAssertNotNil(s.consumeInterruption(bundleId: slack, now: 101))
    }

    func testResetClearsState() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        s.reset()
        XCTAssertNil(s.consumeInterruption(bundleId: safari, now: 101))
    }

    func testEmptyBundleIgnored() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: "", now: 100)
        XCTAssertNil(s.consumeInterruption(bundleId: "", now: 101))
    }

    func testWarningMessageFormat() {
        XCTAssertEqual(
            UserInteractionState.warningMessage(bundleId: "com.apple.Safari"),
            "The user changed 'Safari'. Re-query the latest state "
                + "with `get_app_state` before sending more actions.")
        // No dot — whole id is the app name.
        XCTAssertEqual(
            UserInteractionState.warningMessage(bundleId: "Terminal"),
            "The user changed 'Terminal'. Re-query the latest state "
                + "with `get_app_state` before sending more actions.")
    }

    func testAdvanceIsIdempotent() {
        var s = UserInteractionState(debounceDuration: 0.5)
        s.recordInteraction(bundleId: safari, now: 100)
        s.advance(now: 101)
        s.advance(now: 102)
        XCTAssertNotNil(s.consumeInterruption(bundleId: safari, now: 103))
        XCTAssertNil(s.consumeInterruption(bundleId: safari, now: 104))
    }
}
