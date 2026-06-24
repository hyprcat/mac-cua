import XCTest
@testable import MacCUACore

final class PlaybooksTests: XCTestCase {
    /// All seven curated apps the story requires, plus Music for Python parity.
    func testAllRequiredPlaybooksAuthored() {
        let required = [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.tinyspeck.slackmacgap",
            "com.apple.mail",
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.apple.systempreferences",
        ]
        for bundleId in required {
            let g = BuiltinPlaybooks.guidance(for: bundleId)
            XCTAssertNotNil(g, "missing playbook for \(bundleId)")
            XCTAssertFalse(g!.isEmpty, "empty playbook for \(bundleId)")
        }
        // Python-parity Music playbook stays present.
        XCTAssertNotNil(BuiltinPlaybooks.guidance(for: "com.apple.Music"))
    }

    func testUnknownBundleHasNoPlaybook() {
        XCTAssertNil(BuiltinPlaybooks.guidance(for: "com.example.unknown"))
    }

    func testPlaybooksHaveHeadingAndAreDistinct() {
        // Each authored playbook starts with a markdown "## … Tips" heading and
        // the content is unique (no copy-paste duplication across apps).
        var seen = Set<String>()
        for (bundleId, body) in BuiltinPlaybooks.playbooks {
            XCTAssertTrue(body.hasPrefix("## "), "\(bundleId) missing heading")
            XCTAssertTrue(body.contains("Tips"), "\(bundleId) missing Tips heading")
            XCTAssertTrue(seen.insert(body).inserted, "duplicate playbook body for \(bundleId)")
        }
    }

    func testBundleIdsListMatchesTable() {
        XCTAssertEqual(Set(BuiltinPlaybooks.bundleIds), Set(BuiltinPlaybooks.playbooks.keys))
    }
}
