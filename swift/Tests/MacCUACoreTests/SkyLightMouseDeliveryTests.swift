import XCTest
@testable import MacCUACore

final class SkyLightMouseDeliveryTests: XCTestCase {
    func testCGStampsSubtypeAndWindowHints() {
        let stamps = SkyLightMouseDelivery.cgStamps(windowId: 4242)
        XCTAssertEqual(stamps.count, 3)

        // subtype (7) = 3
        XCTAssertEqual(stamps[0].field, 7)
        XCTAssertEqual(stamps[0].value, 3)
        // windowUnderPointer (91) = windowId
        XCTAssertEqual(stamps[1].field, 91)
        XCTAssertEqual(stamps[1].value, 4242)
        // windowUnderPointerThatCanHandle (92) = windowId
        XCTAssertEqual(stamps[2].field, 92)
        XCTAssertEqual(stamps[2].value, 4242)
    }

    func testCGStampsUseNamedConstants() {
        let stamps = SkyLightMouseDelivery.cgStamps(windowId: 7)
        XCTAssertEqual(stamps[0].field, CGEventFieldNumber.mouseEventSubtype)
        XCTAssertEqual(stamps[0].value, CGMouseEventSubtypeValue.tabletProximity)
        XCTAssertEqual(stamps[1].field, CGEventFieldNumber.mouseEventWindowUnderMousePointer)
        XCTAssertEqual(stamps[2].field,
                       CGEventFieldNumber.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
    }

    func testSkyStampsTargetPidField40() {
        let stamps = SkyLightMouseDelivery.skyStamps(pid: 1337)
        XCTAssertEqual(stamps.count, 1)
        XCTAssertEqual(stamps[0].field, 40)
        XCTAssertEqual(stamps[0].field, SkyLightEventField.pid)
        XCTAssertEqual(stamps[0].value, 1337)
    }

    func testStampsScaleWithIdentifiers() {
        XCTAssertEqual(SkyLightMouseDelivery.cgStamps(windowId: 0)[1].value, 0)
        XCTAssertEqual(SkyLightMouseDelivery.skyStamps(pid: 99999)[0].value, 99999)
    }
}
