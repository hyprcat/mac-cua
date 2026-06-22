import XCTest
@testable import MacCUACoreTests

fileprivate extension ModelsTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__ModelsTests = [
        ("testNodeDefaults", testNodeDefaults),
        ("testSHA256KnownVector", testSHA256KnownVector),
        ("testVersionHashMatchesPython", testVersionHashMatchesPython)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __MacCUACoreTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(ModelsTests.__allTests__ModelsTests)
    ]
}