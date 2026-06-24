import Foundation

// Pure, Linux-green parsing + matching helpers extracted from apps.py so the
// load-bearing logic (lsappinfo block parsing, name/bundle resolution order) is
// unit-testable without AppKit. The Kit `AppResolver` impl (US-016) feeds the
// real `lsappinfo list` output / NSWorkspace results through these.

/// One foreground GUI app parsed out of `lsappinfo list` output.
public struct ParsedLSApp: Equatable, Sendable {
    public var bundleId: String
    public var name: String?
    public var pid: Int

    public init(bundleId: String, name: String?, pid: Int) {
        self.bundleId = bundleId
        self.name = name
        self.pid = pid
    }
}

public enum AppResolverParsing {
    /// Parse `lsappinfo list` output into the foreground GUI apps it lists.
    /// Mirrors apps.py: split on `ASN:`, keep only blocks marked
    /// `type="Foreground"`, and require both a bundleID and a pid. The display
    /// name comes from `"LSDisplayName"="…"` when present, else the first
    /// quoted token on a line, else nil (caller derives a name from the bundle).
    public static func parseLSAppInfoList(_ output: String) -> [ParsedLSApp] {
        var result: [ParsedLSApp] = []
        for block in output.components(separatedBy: "ASN:") {
            guard block.contains("type=\"Foreground\"") else { continue }
            guard let bundleId = firstMatch(in: block, pattern: "bundleID=\"([^\"]+)\"") else {
                continue
            }
            guard let pidStr = firstMatch(in: block, pattern: "pid\\s*=\\s*(\\d+)"),
                  let pid = Int(pidStr) else {
                continue
            }
            let name = firstMatch(in: block, pattern: "\"LSDisplayName\"=\"([^\"]+)\"")
                ?? firstMatch(in: block, pattern: "(?m)^\\s*\"([^\"]+)\"\\s")
            result.append(ParsedLSApp(bundleId: bundleId, name: name, pid: pid))
        }
        return result
    }

    /// Resolve a name/bundle-id hint against the running apps, in apps.py order:
    /// exact bundle-id or case-insensitive exact name first, then a
    /// case-insensitive substring match on name or bundle id. Returns nil when
    /// no running app matches (caller then tries the install/launch path).
    public static func matchRunningApp(hint: String, among running: [AppInfo]) -> AppInfo? {
        let lower = hint.lowercased()
        for a in running where a.bundleId == hint || a.name.lowercased() == lower {
            return a
        }
        for a in running where a.name.lowercased().contains(lower)
            || a.bundleId.lowercased().contains(lower) {
            return a
        }
        return nil
    }

    /// Last path component of a bundle id (`com.apple.Safari` -> `Safari`), the
    /// fallback display name used throughout apps.py.
    public static func nameFromBundleId(_ bundleId: String) -> String {
        bundleId.components(separatedBy: ".").last ?? bundleId
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r])
    }
}
