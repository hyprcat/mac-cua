import XCTest
@testable import MacCUACore

/// Hermetic resolver: returns canned IPs from a hostname->IPs map, so DNS-backed
/// SSRF checks are instant and deterministic (no real `getaddrinfo`).
struct FakeDNSResolver: DNSResolver {
    let table: [String: [String]]
    func resolve(_ hostname: String) -> [String] {
        table[hostname] ?? []
    }
}

final class SafetyTestsApps: XCTestCase {
    private func makeBlocklist(allowForbidden: Bool = false) -> SafetyBlocklist {
        SafetyBlocklist(allowForbidden: allowForbidden, resolver: FakeDNSResolver(table: [:]))
    }

    func testBlocksKeychainAccess() {
        let result = makeBlocklist().checkApp("com.apple.keychainaccess")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("system security process"))
    }

    func testBlocksSecurityAgent() {
        XCTAssertNotNil(makeBlocklist().checkApp("com.apple.SecurityAgent"))
    }

    func testAllowsNormalApp() {
        XCTAssertNil(makeBlocklist().checkApp("com.apple.Music"))
    }

    func testAllowsNormalAppWithFlag() {
        let bl = makeBlocklist(allowForbidden: true)
        XCTAssertNil(bl.checkApp("com.apple.keychainaccess"))
    }
}

final class SafetyTestsURLs: XCTestCase {
    private func makeBlocklist(
        allowForbidden: Bool = false,
        table: [String: [String]] = [:]
    ) -> SafetyBlocklist {
        SafetyBlocklist(allowForbidden: allowForbidden, resolver: FakeDNSResolver(table: table))
    }

    func testBlocksLocalhostURL() {
        let result = makeBlocklist().checkURL("http://127.0.0.1:8080/api")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("private_ip_blocked"))
    }

    func testBlocksPrivate10Range() {
        XCTAssertNotNil(makeBlocklist().checkURL("http://10.0.0.1/admin"))
    }

    func testBlocksPrivate172Range() {
        XCTAssertNotNil(makeBlocklist().checkURL("http://172.16.0.1/"))
    }

    func testBlocksPrivate192Range() {
        XCTAssertNotNil(makeBlocklist().checkURL("http://192.168.1.1/"))
    }

    func testBlocksIPv6Loopback() {
        XCTAssertNotNil(makeBlocklist().checkURL("http://[::1]:3000/"))
    }

    func testAllowsPublicURL() {
        // Public hostname resolving to a public IP via the fake resolver.
        let bl = makeBlocklist(table: ["www.example.com": ["93.184.216.34"]])
        XCTAssertNil(bl.checkURL("https://www.example.com/page"))
    }

    func testAllowsWithFlag() {
        XCTAssertNil(makeBlocklist(allowForbidden: true).checkURL("http://127.0.0.1/"))
    }

    func testIsPrivateIPDirect() {
        let bl = makeBlocklist()
        XCTAssertTrue(bl.isPrivateIP("127.0.0.1"))
        XCTAssertTrue(bl.isPrivateIP("10.255.0.1"))
        XCTAssertFalse(bl.isPrivateIP("8.8.8.8"))
    }

    func testHandlesMalformedURL() {
        XCTAssertNil(makeBlocklist().checkURL("not-a-url"))
    }

    // MARK: - Resolver-backed SSRF (hermetic, fake resolver)

    func testBlocksHostnameResolvingToPrivateIP() {
        // A hostname that resolves to a private IP must be blocked (SSRF).
        let bl = makeBlocklist(table: ["internal.evil.test": ["10.1.2.3"]])
        let result = bl.checkURL("http://internal.evil.test/secret")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("private_ip_blocked"))
    }

    func testAllowsHostnameResolvingToPublicIP() {
        let bl = makeBlocklist(table: ["good.test": ["1.2.3.4"]])
        XCTAssertNil(bl.checkURL("http://good.test/"))
    }

    func testUnresolvableHostnameIsAllowed() {
        // No resolver entry -> empty results -> not private (mirrors gaierror).
        XCTAssertNil(makeBlocklist().checkURL("http://nonexistent.invalid/"))
    }

    func testMixedResolutionBlocksIfAnyPrivate() {
        let bl = makeBlocklist(table: ["rebind.test": ["1.2.3.4", "192.168.0.5"]])
        XCTAssertNotNil(bl.checkURL("http://rebind.test/"))
    }
}

final class SafetyTestsIPParsing: XCTestCase {
    func testIPv4LinkLocalBlocked() {
        XCTAssertTrue(SafetyBlocklist(resolver: FakeDNSResolver(table: [:])).isPrivateIP("169.254.1.1"))
    }

    func testIPv6ULABlocked() {
        XCTAssertTrue(SafetyBlocklist(resolver: FakeDNSResolver(table: [:])).isPrivateIP("fc00::1"))
    }

    func testIPv6LinkLocalBlocked() {
        XCTAssertTrue(SafetyBlocklist(resolver: FakeDNSResolver(table: [:])).isPrivateIP("fe80::abcd"))
    }

    func testPublicIPv6NotBlocked() {
        XCTAssertFalse(SafetyBlocklist(resolver: FakeDNSResolver(table: [:])).isPrivateIP("2001:4860:4860::8888"))
    }

    func test172EdgeBoundary() {
        let bl = SafetyBlocklist(resolver: FakeDNSResolver(table: [:]))
        // 172.16.0.0/12 covers 172.16.0.0 - 172.31.255.255.
        XCTAssertTrue(bl.isPrivateIP("172.31.255.255"))
        XCTAssertFalse(bl.isPrivateIP("172.32.0.1"))
        XCTAssertFalse(bl.isPrivateIP("172.15.0.1"))
    }
}
