import XCTest
@testable import MacCUACore

/// US-025 — pure poll-loop driver + tree-fingerprint feed for the SettleMonitor.
final class SettlePollerTests: XCTestCase {
    private func node(_ index: Int, role: String = "AXButton", label: String? = nil,
                      value: String? = nil, states: [String] = [],
                      position: Point? = nil, size: Size? = nil) -> Node {
        Node(index: index, role: role, label: label, states: states, value: value,
             depth: 0, position: position, size: size)
    }

    // MARK: - TreeFingerprint

    func testFingerprintStableForIdenticalTrees() {
        let a = [node(0, label: "A", value: "1"), node(1, label: "B")]
        let b = [node(0, label: "A", value: "1"), node(1, label: "B")]
        XCTAssertEqual(TreeFingerprint.compute(a), TreeFingerprint.compute(b))
    }

    func testFingerprintChangesOnContentChange() {
        let a = [node(0, value: "1")]
        let b = [node(0, value: "2")]
        XCTAssertNotEqual(TreeFingerprint.compute(a), TreeFingerprint.compute(b))
    }

    func testFingerprintChangesOnStateChange() {
        let a = [node(0, states: ["enabled"])]
        let b = [node(0, states: ["disabled"])]
        XCTAssertNotEqual(TreeFingerprint.compute(a), TreeFingerprint.compute(b))
    }

    func testFingerprintIgnoresGeometry() {
        // Geometry is fed separately as key-frame rects, so a pure move must NOT
        // change the structural fingerprint (else motion reads as a new tree).
        let a = [node(0, position: Point(x: 0, y: 0), size: Size(w: 10, h: 10))]
        let b = [node(0, position: Point(x: 99, y: 99), size: Size(w: 10, h: 10))]
        XCTAssertEqual(TreeFingerprint.compute(a), TreeFingerprint.compute(b))
    }

    func testKeyFrameRectsOnlyForPositionedSizedNodes() {
        let nodes = [
            node(0, position: Point(x: 1, y: 2), size: Size(w: 3, h: 4)),
            node(1),                                   // no geometry -> skipped
            node(2, position: Point(x: 5, y: 6), size: Size(w: 7, h: 8)),
        ]
        let rects = TreeFingerprint.keyFrameRects(nodes)
        XCTAssertEqual(rects, [
            SettleRect(x: 1, y: 2, width: 3, height: 4),
            SettleRect(x: 5, y: 6, width: 7, height: 8),
        ])
    }

    // MARK: - SettlePoller

    /// A deterministic fake clock that advances by `pollInterval` each sleep.
    private final class FakeClock {
        var t = 0.0
        func now() -> Double { t }
        func sleep(_ d: Double) { t += d }
    }

    func testNoChangeWhenTreeNeverChanges() {
        let clock = FakeClock()
        let poller = SettlePoller(quietPeriod: 0.15, maxWait: 2.0, pollInterval: 0.05)
        let r = poller.run(
            now: clock.now,
            sample: { (42, []) },              // constant fingerprint
            sleep: clock.sleep
        )
        XCTAssertEqual(r, .noChange)
    }

    func testSettlesAfterChangeThenQuiet() {
        let clock = FakeClock()
        var fp = 1
        var polls = 0
        let poller = SettlePoller(quietPeriod: 0.15, maxWait: 5.0, pollInterval: 0.05)
        let r = poller.run(
            now: clock.now,
            sample: {
                polls += 1
                if polls < 3 { fp += 1 }   // changing for the first couple polls
                return (fp, [])
            },
            sleep: clock.sleep
        )
        XCTAssertEqual(r, .settled)
    }

    func testAnimationKeepsWaitingUntilCap() {
        let clock = FakeClock()
        var x = 0.0
        let poller = SettlePoller(quietPeriod: 0.15, maxWait: 1.0, pollInterval: 0.05)
        let r = poller.run(
            now: clock.now,
            sample: {
                x += 1   // a rect that moves every single poll = never quiesces
                return (7, [SettleRect(x: x, y: 0, width: 10, height: 10)])
            },
            sleep: clock.sleep
        )
        XCTAssertEqual(r, .timeout)
    }

    func testCancelledShortCircuits() {
        let clock = FakeClock()
        let poller = SettlePoller(quietPeriod: 0.15, maxWait: 2.0, pollInterval: 0.05)
        let r = poller.run(
            now: clock.now,
            sample: { (1, []) },
            sleep: clock.sleep,
            isCancelled: { true }
        )
        XCTAssertEqual(r, .cancelled)
    }

    func testPollIntervalClampedToNonZeroAndCap() {
        let p = SettlePoller(quietPeriod: 0.1, maxWait: 0.5, pollInterval: 0)
        XCTAssertGreaterThan(p.pollInterval, 0)
        let big = SettlePoller(quietPeriod: 0.1, maxWait: 0.2, pollInterval: 10)
        XCTAssertLessThanOrEqual(big.pollInterval, big.maxWait)
    }
}
