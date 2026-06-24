import XCTest
@testable import MacCUACore

final class AppResolverParsingTests: XCTestCase {
    // MARK: - parseLSAppInfoList

    func testParsesForegroundAppWithDisplayName() {
        let out = """
        ASN:0x0-0x1234:
            bundleID="com.apple.Safari"=
            "LSDisplayName"="Safari"=
            type="Foreground"
            pid = 4321
        """
        let apps = AppResolverParsing.parseLSAppInfoList(out)
        XCTAssertEqual(apps, [ParsedLSApp(bundleId: "com.apple.Safari", name: "Safari", pid: 4321)])
    }

    func testSkipsBackgroundApps() {
        let out = """
        ASN:0x0-0x1:
            bundleID="com.apple.bg"=
            type="Background"
            pid = 11
        ASN:0x0-0x2:
            bundleID="com.apple.fg"=
            type="Foreground"
            pid = 22
        """
        let apps = AppResolverParsing.parseLSAppInfoList(out)
        XCTAssertEqual(apps.map(\.bundleId), ["com.apple.fg"])
    }

    func testRequiresBothBundleAndPid() {
        let out = """
        ASN:0x0-0x1:
            type="Foreground"
            pid = 99
        ASN:0x0-0x2:
            bundleID="com.apple.nopid"=
            type="Foreground"
        """
        XCTAssertTrue(AppResolverParsing.parseLSAppInfoList(out).isEmpty)
    }

    func testNameNilWhenAbsent() {
        let out = """
        ASN:0x0-0x9:
            bundleID="com.example.app"=
            type="Foreground"
            pid = 7
        """
        let apps = AppResolverParsing.parseLSAppInfoList(out)
        XCTAssertEqual(apps.count, 1)
        XCTAssertNil(apps[0].name)
    }

    func testEmptyOutput() {
        XCTAssertTrue(AppResolverParsing.parseLSAppInfoList("").isEmpty)
    }

    func testMultipleForegroundApps() {
        let out = """
        ASN:0x0-0x1:
            bundleID="com.a"=
            type="Foreground"
            pid = 1
        ASN:0x0-0x2:
            bundleID="com.b"=
            "LSDisplayName"="Bee"=
            type="Foreground"
            pid = 2
        """
        let apps = AppResolverParsing.parseLSAppInfoList(out)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[1], ParsedLSApp(bundleId: "com.b", name: "Bee", pid: 2))
    }

    // MARK: - matchRunningApp

    private let running = [
        AppInfo(name: "Safari", bundleId: "com.apple.Safari", pid: 1, running: true),
        AppInfo(name: "Notes", bundleId: "com.apple.Notes", pid: 2, running: true),
        AppInfo(name: "Visual Studio Code", bundleId: "com.microsoft.VSCode", pid: 3, running: true),
    ]

    func testExactBundleId() {
        XCTAssertEqual(AppResolverParsing.matchRunningApp(hint: "com.apple.Notes", among: running)?.pid, 2)
    }

    func testExactNameCaseInsensitive() {
        XCTAssertEqual(AppResolverParsing.matchRunningApp(hint: "safari", among: running)?.pid, 1)
    }

    func testSubstringName() {
        XCTAssertEqual(AppResolverParsing.matchRunningApp(hint: "studio", among: running)?.pid, 3)
    }

    func testSubstringBundle() {
        XCTAssertEqual(AppResolverParsing.matchRunningApp(hint: "microsoft", among: running)?.pid, 3)
    }

    func testNoMatch() {
        XCTAssertNil(AppResolverParsing.matchRunningApp(hint: "Xcode", among: running))
    }

    func testExactBeatsSubstring() {
        // "Notes" exact name should win even though "note" substring also matches.
        let apps = [
            AppInfo(name: "Notetaker", bundleId: "com.x.notetaker", pid: 5, running: true),
            AppInfo(name: "Notes", bundleId: "com.apple.Notes", pid: 6, running: true),
        ]
        XCTAssertEqual(AppResolverParsing.matchRunningApp(hint: "Notes", among: apps)?.pid, 6)
    }

    // MARK: - nameFromBundleId

    func testNameFromBundleId() {
        XCTAssertEqual(AppResolverParsing.nameFromBundleId("com.apple.Safari"), "Safari")
        XCTAssertEqual(AppResolverParsing.nameFromBundleId("singletoken"), "singletoken")
    }
}
