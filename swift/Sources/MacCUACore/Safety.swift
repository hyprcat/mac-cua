import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Port of app/_lib/safety.py — app and URL blocking for safety.
//
// Pure logic EXCEPT hostname resolution (`socket.getaddrinfo` in Python). The
// resolver is abstracted behind `DNSResolver` and injected, so the blocklist /
// SSRF decision semantics are fully testable with a fake resolver. A thin
// production conformer (`SystemDNSResolver`) wraps POSIX `getaddrinfo` and is
// the default when none is supplied. Everything else — URL parsing, IP literal
// parsing, and private-range containment — is pure Swift mirroring Python's
// `ipaddress` + `urllib.parse` behaviour.

// MARK: - Constants

/// System security processes that must never be automated.
/// Mirrors `BLOCKED_APPS`.
public let blockedApps: Set<String> = [
    "com.apple.keychainaccess",
    "com.apple.SecurityAgent",
    "com.apple.Passwords",
    "com.apple.ScreenSharingAgent",
    "com.apple.UserNotificationCenter",
]

/// Apps that must never receive *synthetic input* (Codex parity §G). These are
/// in addition to `blockedApps`: terminal emulators (a stray keystroke can run
/// destructive shell commands), admin-authorization / security-privacy prompts,
/// and Keychain. Reads (`get_app_state`) are still permitted — only input is
/// refused — so the model can see, but not act on, these surfaces.
public let inputBlockedApps: Set<String> = [
    // Terminal emulators.
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "co.zeit.hyper",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "io.alacritty",
    // Admin-auth / security-privacy prompts (also covered by blockedApps's
    // SecurityAgent; listed here so input is refused even if the read blocklist
    // is bypassed via allow_forbidden for diagnostics).
    "com.apple.SecurityAgent",
    "com.apple.CoreServicesUIAgent",
    "com.apple.security.authhost",
    "com.apple.keychainaccess",
    "com.apple.Passwords",
]

/// Reason emitted when synthetic input is refused because the screen is locked.
/// Mirrors the Codex lock-screen guard (§G / §K).
public let lockScreenInputRefusal =
    "Automation input is refused because the screen is locked."

/// Session-stop guidance string emitted when automation hits a blocked URL.
/// Mirrors `SESSION_STOP_SAFETY`.
public let sessionStopSafety =
    "This session has been stopped because Automation is not allowed on the "
    + "current browser URL. Stop your work and send a final message noting why "
    + "the session has been ended."

/// Session-stop guidance string emitted when the user stops the session.
/// Mirrors `SESSION_STOP_USER`.
public let sessionStopUser =
    "This application session has been explicitly stopped by the user for this "
    + "turn. Stop your work and send a final message noting they stopped the "
    + "session and you're ready to continue if they want you to. Automation "
    + "can be used again in the next assistant turn."

// MARK: - DNS resolver seam

/// Abstraction over hostname resolution (the only impure dependency in
/// `safety.py`). Returns the set of resolved IP address strings for `hostname`,
/// or an empty array if resolution fails (mirroring Python's `socket.gaierror`
/// branch which simply yields no results).
public protocol DNSResolver: Sendable {
    func resolve(_ hostname: String) -> [String]
}

/// Production resolver backed by POSIX `getaddrinfo` (AF_UNSPEC / SOCK_STREAM),
/// matching `socket.getaddrinfo(hostname, None, AF_UNSPEC, SOCK_STREAM)`.
/// Available on Linux (Glibc) and macOS (Darwin) without any platform GUI
/// frameworks, so it stays in the pure Core target.
public struct SystemDNSResolver: DNSResolver {
    public init() {}

    public func resolve(_ hostname: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var addrs: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            if let sa = current.pointee.ai_addr {
                if let ip = Self.ipString(from: sa, length: current.pointee.ai_addrlen) {
                    addrs.append(ip)
                }
            }
            node = current.pointee.ai_next
        }
        return addrs
    }

    private static func ipString(
        from sa: UnsafeMutablePointer<sockaddr>,
        length: socklen_t
    ) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = getnameinfo(
            sa, length,
            &host, socklen_t(host.count),
            nil, 0,
            NI_NUMERICHOST
        )
        guard rc == 0 else { return nil }
        let truncated = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: truncated, as: UTF8.self)
    }
}

// MARK: - Private network ranges

/// CIDR networks that count as "private" / SSRF-blocked. Mirrors
/// `_BLOCKED_NETWORKS` (the v4 ranges plus IPv6 loopback / ULA / link-local).
struct IPNetwork {
    let base: [UInt8]
    let prefix: Int

    /// True when `addr` (same byte-width as `base`) falls within this network.
    func contains(_ addr: [UInt8]) -> Bool {
        guard addr.count == base.count else { return false }
        var bitsRemaining = prefix
        for i in 0..<base.count {
            if bitsRemaining <= 0 { break }
            let take = min(8, bitsRemaining)
            // Mask out the low (8 - take) bits we don't care about.
            let mask: UInt8 = take == 8 ? 0xFF : UInt8(truncatingIfNeeded: (0xFF << (8 - take)))
            if (addr[i] & mask) != (base[i] & mask) {
                return false
            }
            bitsRemaining -= take
        }
        return true
    }
}

private let blockedNetworks: [IPNetwork] = [
    // IPv4 ranges.
    IPNetwork(base: IPAddress.parse("127.0.0.0")!.bytes, prefix: 8),
    IPNetwork(base: IPAddress.parse("10.0.0.0")!.bytes, prefix: 8),
    IPNetwork(base: IPAddress.parse("172.16.0.0")!.bytes, prefix: 12),
    IPNetwork(base: IPAddress.parse("192.168.0.0")!.bytes, prefix: 16),
    IPNetwork(base: IPAddress.parse("169.254.0.0")!.bytes, prefix: 16),
    // IPv6 ranges.
    IPNetwork(base: IPAddress.parse("::1")!.bytes, prefix: 128),
    IPNetwork(base: IPAddress.parse("fc00::")!.bytes, prefix: 7),
    IPNetwork(base: IPAddress.parse("fe80::")!.bytes, prefix: 10),
]

// MARK: - IP literal parsing

/// Minimal pure-Swift IP literal parser mirroring `ipaddress.ip_address`.
/// Distinguishes IPv4 (4 bytes) from IPv6 (16 bytes); returns nil for anything
/// that isn't a valid numeric IP literal (Python raises `ValueError`).
struct IPAddress {
    let bytes: [UInt8]

    static func parse(_ text: String) -> IPAddress? {
        if let v4 = parseIPv4(text) {
            return IPAddress(bytes: v4)
        }
        if let v6 = parseIPv6(text) {
            return IPAddress(bytes: v6)
        }
        return nil
    }

    static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            // Reject empty, non-digit, or out-of-range octets (no leading-zero
            // games beyond what Int parsing allows; matches ipaddress strictness
            // for the values we care about).
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }),
                  let v = Int(part), v >= 0, v <= 255 else {
                return nil
            }
            // ipaddress rejects octets with redundant leading zeros, e.g. "01".
            if part.count > 1 && part.first == "0" { return nil }
            bytes.append(UInt8(v))
        }
        return bytes
    }

    static func parseIPv6(_ rawText: String) -> [UInt8]? {
        var text = rawText
        // Strip an optional zone id (e.g. "fe80::1%en0").
        if let pct = text.firstIndex(of: "%") {
            text = String(text[..<pct])
        }
        guard !text.isEmpty else { return nil }
        guard text.contains(":") else { return nil }

        // Split on the "::" gap (at most one allowed).
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(_ s: String) -> [String]? {
            if s.isEmpty { return [] }
            return s.components(separatedBy: ":").map { String($0) }
        }

        var headStrings: [String]
        var tailStrings: [String]
        let compressed = halves.count == 2
        if compressed {
            guard let h = groups(halves[0]), let t = groups(halves[1]) else { return nil }
            headStrings = h
            tailStrings = t
        } else {
            guard let h = groups(halves[0]) else { return nil }
            headStrings = h
            tailStrings = []
        }

        // Helper: convert a list of hextet strings to bytes, allowing the last
        // hextet to be an embedded IPv4 dotted-quad.
        func toBytes(_ strs: [String], allowEmbeddedV4: Bool) -> [UInt8]? {
            var out: [UInt8] = []
            for (i, g) in strs.enumerated() {
                let isLast = i == strs.count - 1
                if allowEmbeddedV4 && isLast && g.contains(".") {
                    guard let v4 = parseIPv4(g) else { return nil }
                    out.append(contentsOf: v4)
                    continue
                }
                guard !g.isEmpty, g.count <= 4,
                      g.allSatisfy({ $0.isHexDigit }),
                      let v = UInt16(g, radix: 16) else {
                    return nil
                }
                out.append(UInt8(truncatingIfNeeded: v >> 8))
                out.append(UInt8(truncatingIfNeeded: v & 0xFF))
            }
            return out
        }

        guard let headBytes = toBytes(headStrings, allowEmbeddedV4: true) else { return nil }
        guard let tailBytes = toBytes(tailStrings, allowEmbeddedV4: true) else { return nil }

        if compressed {
            let total = headBytes.count + tailBytes.count
            guard total <= 16 else { return nil }
            let fill = [UInt8](repeating: 0, count: 16 - total)
            return headBytes + fill + tailBytes
        } else {
            guard headBytes.count == 16 else { return nil }
            return headBytes
        }
    }
}

// MARK: - SafetyBlocklist

/// App and URL blocking for safety. Mirrors `SafetyBlocklist`.
public final class SafetyBlocklist {
    private let allowForbidden: Bool
    private let resolver: DNSResolver
    private let ownBundleId: String?

    public init(
        allowForbidden: Bool = false,
        resolver: DNSResolver = SystemDNSResolver(),
        ownBundleId: String? = nil
    ) {
        self.allowForbidden = allowForbidden
        self.resolver = resolver
        self.ownBundleId = ownBundleId
    }

    /// Returns block reason or nil if allowed. Mirrors `check_app`.
    public func checkApp(_ bundleId: String) -> String? {
        if allowForbidden { return nil }
        if blockedApps.contains(bundleId) {
            return "Automation is not allowed for system security process: \(bundleId)"
        }
        return nil
    }

    /// Returns block reason or nil if synthetic input is allowed against
    /// `bundleId`. Stricter than `checkApp`: also refuses terminals, our own
    /// process (no self-driving), and admin-auth / security prompts. `allow_forbidden`
    /// is intentionally NOT honored here — these targets are never safe to type
    /// into. Mirrors the Codex parity extension (§G).
    public func checkInputApp(_ bundleId: String) -> String? {
        if let own = ownBundleId, !own.isEmpty, bundleId == own {
            return "Automation is not allowed to send input to its own process: \(bundleId)"
        }
        if inputBlockedApps.contains(bundleId) {
            return "Automation input is not allowed for sensitive process: \(bundleId)"
        }
        return nil
    }

    /// Returns block reason or nil. Includes SSRF protection. Mirrors `check_url`.
    public func checkURL(_ url: String) -> String? {
        if allowForbidden { return nil }
        guard let hostname = Self.hostname(from: url) else {
            return nil
        }
        if isPrivateIP(hostname) {
            return "private_ip_blocked: \(hostname)"
        }
        return nil
    }

    /// Resolve hostname and check against private IP ranges. Mirrors
    /// `is_private_ip`.
    public func isPrivateIP(_ hostname: String) -> Bool {
        // Direct IP literal — no resolution needed.
        if let addr = IPAddress.parse(hostname) {
            return blockedNetworks.contains { $0.contains(addr.bytes) }
        }
        // Otherwise resolve and check each result.
        for ipStr in resolver.resolve(hostname) {
            guard let addr = IPAddress.parse(ipStr) else { continue }
            if blockedNetworks.contains(where: { $0.contains(addr.bytes) }) {
                return true
            }
        }
        return false
    }

    // MARK: URL hostname extraction

    /// Extracts the hostname from a URL the way `urllib.parse.urlparse(...).hostname`
    /// does: lower-cased, brackets stripped from IPv6 literals, port and
    /// userinfo removed. Returns nil when there is no authority/host component
    /// (e.g. "not-a-url"), mirroring `parsed.hostname is None`.
    static func hostname(from url: String) -> String? {
        // Locate the authority component, which only exists after "//".
        guard let schemeEnd = url.range(of: "//") else {
            return nil
        }
        var rest = String(url[schemeEnd.upperBound...])

        // Authority ends at the first '/', '?', or '#'.
        if let stop = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<stop])
        }
        // Strip userinfo ("user:pass@host").
        if let at = rest.lastIndex(of: "@") {
            rest = String(rest[rest.index(after: at)...])
        }
        if rest.isEmpty { return nil }

        // IPv6 literal in brackets: "[::1]:3000" -> "::1".
        if rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let inner = String(rest[rest.index(after: rest.startIndex)..<close])
            return inner.isEmpty ? nil : inner.lowercased()
        }

        // Strip ":port" for the non-bracketed case.
        if let colon = rest.lastIndex(of: ":") {
            rest = String(rest[..<colon])
        }
        if rest.isEmpty { return nil }
        return rest.lowercased()
    }
}
