import XCTest
@testable import MacCUACore

final class SkyLightKeyboardDeliveryTests: XCTestCase {
    func testNoModifiersIsZeroFlags() {
        XCTAssertEqual(SkyLightKeyboardDelivery.cgEventFlags(modifierMask: 0), 0)
    }

    func testEachModifierMapsToItsNamedFlagMask() {
        XCTAssertEqual(
            SkyLightKeyboardDelivery.cgEventFlags(modifierMask: KeyParser.maskShift),
            CGEventFlagMask.shift)
        XCTAssertEqual(
            SkyLightKeyboardDelivery.cgEventFlags(modifierMask: KeyParser.maskControl),
            CGEventFlagMask.control)
        XCTAssertEqual(
            SkyLightKeyboardDelivery.cgEventFlags(modifierMask: KeyParser.maskAlternate),
            CGEventFlagMask.alternate)
        XCTAssertEqual(
            SkyLightKeyboardDelivery.cgEventFlags(modifierMask: KeyParser.maskCommand),
            CGEventFlagMask.command)
    }

    func testCompoundModifiersOrTogether() {
        // Cmd-Shift (e.g. Cmd-Shift-T)
        let mask = KeyParser.maskCommand | KeyParser.maskShift
        let flags = SkyLightKeyboardDelivery.cgEventFlags(modifierMask: mask)
        XCTAssertEqual(flags, CGEventFlagMask.command | CGEventFlagMask.shift)
        XCTAssertNotEqual(flags & CGEventFlagMask.command, 0)
        XCTAssertNotEqual(flags & CGEventFlagMask.shift, 0)
        // Control/Alt absent.
        XCTAssertEqual(flags & CGEventFlagMask.control, 0)
        XCTAssertEqual(flags & CGEventFlagMask.alternate, 0)
    }

    func testAllModifiersTogether() {
        let mask = KeyParser.maskCommand | KeyParser.maskShift
            | KeyParser.maskControl | KeyParser.maskAlternate
        let flags = SkyLightKeyboardDelivery.cgEventFlags(modifierMask: mask)
        XCTAssertEqual(
            flags,
            CGEventFlagMask.command | CGEventFlagMask.shift
                | CGEventFlagMask.control | CGEventFlagMask.alternate)
    }

    func testKeyParserMasksEqualNamedCGFlagMasks() {
        // The KeyParser masks are the same bit positions as the CGEventFlags masks;
        // the translation must agree so the Mac impl can use either name safely.
        XCTAssertEqual(UInt64(KeyParser.maskShift), CGEventFlagMask.shift)
        XCTAssertEqual(UInt64(KeyParser.maskControl), CGEventFlagMask.control)
        XCTAssertEqual(UInt64(KeyParser.maskAlternate), CGEventFlagMask.alternate)
        XCTAssertEqual(UInt64(KeyParser.maskCommand), CGEventFlagMask.command)
    }

    func testDeliveryUsesBothRoutes() {
        XCTAssertEqual(
            SkyLightKeyboardDelivery.deliveryRoutes,
            [.skyLightAuthenticatedPostToPid, .cgEventPostToOwnerPSN])
        // Both catalogued routes are present (authenticated pid post + owner PSN post).
        XCTAssertEqual(Set(SkyLightKeyboardDelivery.deliveryRoutes),
                       Set(SkyLightKeyDeliveryRoute.allCases))
    }
}
