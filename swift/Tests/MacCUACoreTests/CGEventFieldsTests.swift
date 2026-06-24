import XCTest
@testable import MacCUACore

// US-006: assert every CGEvent field number / flag mask / source-state id matches
// docs/CODEX_PARITY_CHANGES.md Appendix exactly.
final class CGEventFieldsTests: XCTestCase {
    func testMouseFields() {
        XCTAssertEqual(CGEventFieldNumber.mouseEventNumber, 0)
        XCTAssertEqual(CGEventFieldNumber.mouseEventClickState, 1)
        XCTAssertEqual(CGEventFieldNumber.mouseEventPressure, 2)
        XCTAssertEqual(CGEventFieldNumber.mouseEventButtonNumber, 3)
        XCTAssertEqual(CGEventFieldNumber.mouseEventDeltaX, 4)
        XCTAssertEqual(CGEventFieldNumber.mouseEventDeltaY, 5)
        XCTAssertEqual(CGEventFieldNumber.mouseEventSubtype, 7)
    }

    func testKeyboardField() {
        XCTAssertEqual(CGEventFieldNumber.keyboardEventKeycode, 9)
    }

    func testScrollLineAxes() {
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventDeltaAxis1, 11)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventDeltaAxis2, 12)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventDeltaAxis3, 13)
    }

    func testScrollFixedPtAxes() {
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis1, 93)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis2, 94)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis3, 95)
    }

    func testScrollPointAxes() {
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventPointDeltaAxis1, 96)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventPointDeltaAxis2, 97)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventPointDeltaAxis3, 98)
    }

    func testScrollPhaseAndContinuity() {
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventIsContinuous, 88)
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventScrollPhase, 99)
    }

    func testWindowAssociationFields() {
        XCTAssertEqual(CGEventFieldNumber.mouseEventWindowUnderMousePointer, 91)
        XCTAssertEqual(CGEventFieldNumber.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, 92)
    }

    func testSourceStateIDField() {
        XCTAssertEqual(CGEventFieldNumber.eventSourceStateID, 45)
    }

    func testSkyLightPidField() {
        XCTAssertEqual(SkyLightEventField.pid, 40)
    }

    func testSourceStateIDValues() {
        XCTAssertEqual(CGEventSourceStateIDValue.privateState, -1)
        XCTAssertEqual(CGEventSourceStateIDValue.combinedSessionState, 0)
        XCTAssertEqual(CGEventSourceStateIDValue.hidSystemState, 1)
    }

    func testMouseButtons() {
        XCTAssertEqual(CGMouseButtonNumber.left, 0)
        XCTAssertEqual(CGMouseButtonNumber.right, 1)
        XCTAssertEqual(CGMouseButtonNumber.center, 2)
    }

    func testMouseSubtypeValue() {
        XCTAssertEqual(CGMouseEventSubtypeValue.tabletProximity, 3)
    }

    func testFlagMasks() {
        XCTAssertEqual(CGEventFlagMask.shift, 0x20000)
        XCTAssertEqual(CGEventFlagMask.control, 0x40000)
        XCTAssertEqual(CGEventFlagMask.alternate, 0x80000)
        XCTAssertEqual(CGEventFlagMask.command, 0x100000)
    }
}
