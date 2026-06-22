import XCTest
@testable import MacCUACore

final class ModelsTests: XCTestCase {
    func testNodeDefaults() {
        let n = Node(index: 0, role: "AXButton", depth: 0)
        XCTAssertEqual(n.role, "AXButton")
        XCTAssertEqual(n.states, [])
        XCTAssertEqual(n.graphGeneration, 0)
        XCTAssertFalse(n.isWebArea)
        XCTAssertFalse(n.isOop)
        XCTAssertNil(n.label)
    }

    func testVersionHashMatchesPython() {
        // hashlib.sha256(b"0.1.0").hexdigest()[:8]
        XCTAssertEqual(Version.computeVersionHash(packageVersion: "0.1.0"), "6ad9613a")
        XCTAssertTrue(Version.formatResponseHeader().hasPrefix("Desktop Automation state (version: "))
    }

    func testSHA256KnownVector() {
        // sha256("abc")
        let hex = SHA256Lite.hexDigest("abc")
        XCTAssertEqual(hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
