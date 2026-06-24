import XCTest
@testable import MacCUACore

final class PermissionsLogicTests: XCTestCase {
    func testNilListIsNotGranted() {
        XCTAssertFalse(PermissionsLogic.screenRecordingGrantedFromWindowNames(nil))
    }

    func testEmptyListIsNotGranted() {
        XCTAssertFalse(PermissionsLogic.screenRecordingGrantedFromWindowNames([]))
    }

    func testAllNilOrEmptyNamesIsNotGranted() {
        XCTAssertFalse(
            PermissionsLogic.screenRecordingGrantedFromWindowNames([nil, "", nil]))
    }

    func testAnyNonEmptyNameIsGranted() {
        XCTAssertTrue(
            PermissionsLogic.screenRecordingGrantedFromWindowNames([nil, "", "Safari"]))
    }

    func testFirstNonEmptyNameIsGranted() {
        XCTAssertTrue(
            PermissionsLogic.screenRecordingGrantedFromWindowNames(["Finder"]))
    }
}
