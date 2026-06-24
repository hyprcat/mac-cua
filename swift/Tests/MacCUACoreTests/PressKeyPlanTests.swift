import XCTest
@testable import MacCUACore

final class PressKeyPlanTests: XCTestCase {

    func testSingleKeyDownThenUpSameFlags() throws {
        let plan = try PressKeyPlan.plan(for: "Return")
        XCTAssertEqual(plan.count, 2)
        guard case let .down(kc1, f1) = plan[0].transition,
              case let .up(kc2, f2) = plan[1].transition else {
            return XCTFail("expected down then up")
        }
        XCTAssertEqual(kc1, kc2)
        XCTAssertEqual(f1, 0)
        XCTAssertEqual(f2, 0)
    }

    func testHoldAndIntervalTimingPreserved() throws {
        let plan = try PressKeyPlan.plan(for: "a")
        XCTAssertEqual(plan[0].delayAfter, PressKeyPlan.holdDelay, accuracy: 1e-9)
        XCTAssertEqual(plan[1].delayAfter, PressKeyPlan.eventDelay, accuracy: 1e-9)
    }

    func testChordModifiersRideAsFlagsNoFlagsChanged() throws {
        // Cmd-Shift-T: one keycode, both modifier masks on the flags of each
        // transition — and exactly two events (down/up), never a separate
        // discrete modifier event (Invariant 3).
        let plan = try PressKeyPlan.plan(for: "cmd+shift+t")
        XCTAssertEqual(plan.count, 2)
        let expected = KeyParser.maskCommand | KeyParser.maskShift
        for step in plan {
            switch step.transition {
            case let .down(_, flags), let .up(_, flags):
                XCTAssertEqual(flags & expected, expected)
            }
        }
    }

    func testUppercaseAutoShift() throws {
        let plan = try PressKeyPlan.plan(for: "C")
        guard case let .down(_, flags) = plan[0].transition else { return XCTFail() }
        XCTAssertEqual(flags & KeyParser.maskShift, KeyParser.maskShift)
    }

    func testSpaceLiteralResolvesToSpaceKey() throws {
        // A literal space coerces to the named "space" key rather than failing.
        XCTAssertEqual(PressKeyPlan.resolveKeyName(" "), "space")
        XCTAssertNoThrow(try PressKeyPlan.plan(for: " "))
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try PressKeyPlan.plan(for: "definitely_not_a_key"))
    }

    func testSequencePreservesPerKeyInterval() throws {
        let plan = try PressKeyPlan.plan(forSequence: ["a", "b"])
        // Two keys -> two down/up pairs in order.
        XCTAssertEqual(plan.count, 4)
        guard case .down = plan[0].transition, case .up = plan[1].transition,
              case .down = plan[2].transition, case .up = plan[3].transition else {
            return XCTFail("expected down/up/down/up")
        }
        // Inter-key interval is the trailing eventDelay of the first key's up.
        XCTAssertEqual(plan[1].delayAfter, PressKeyPlan.eventDelay, accuracy: 1e-9)
    }
}
