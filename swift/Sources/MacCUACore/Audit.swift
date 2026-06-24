import Foundation

// Redacted JSONL audit sink (US-048, design §G — "redacted audit"). A trust/debug
// trail of the actions the agent performed, written one JSON object per line.
//
// Two hard rules, both enforced by the pure `AuditRedactor` below so they are
// Linux-testable and cannot regress silently:
//   1. NO secrets — user-typed/pasted/written content (`text`/`value`/`content`)
//      is never recorded verbatim; only its length survives.
//   2. NO tree refs (Invariant 8 / US-012) — no `<AXUIElement 0x…>` strings, no
//      raw pointers, no graph_id/graph_locator field. MCP params are JSON
//      primitives so a ref can only sneak in as a string; we scrub those too.
//
// The pure record + redactor live in Core; the file-backed sink is Foundation-only
// (works on Linux) so it lives here as well rather than behind a macOS seam.

// MARK: - Record

/// One audited action. Pure value type — `timestamp` is injected (no clock call
/// here) so the redacted shape is deterministic and unit-testable.
public struct AuditRecord: Equatable, Sendable {
    public let timestamp: Double
    public let tool: String
    public let app: String?
    public let success: Bool
    public let error: String?
    /// Already-redacted params (run them through `AuditRedactor.redactParams`).
    public let params: [String: String]

    public init(
        timestamp: Double,
        tool: String,
        app: String?,
        success: Bool,
        error: String? = nil,
        params: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.tool = tool
        self.app = app
        self.success = success
        self.error = error
        self.params = params
    }

    /// One deterministic JSON line (sorted keys, no trailing newline). The params
    /// are nested under `params`; absent fields (`app`/`error`) are omitted.
    public func jsonLine() -> String {
        var obj: [String: Any] = [
            "ts": timestamp,
            "tool": tool,
            "success": success,
        ]
        if let app { obj["app"] = app }
        if let error { obj["error"] = AuditRedactor.scrubString(error) }
        if !params.isEmpty { obj["params"] = params }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            // Should never happen for [String: primitive]; fail closed to an
            // empty-but-valid record rather than crash the action path.
            return "{\"tool\":\"\(tool)\",\"success\":\(success)}"
        }
        return line
    }
}

// MARK: - Redaction

public enum AuditRedactor {
    /// Param keys whose values are user content (potential secrets): never logged
    /// verbatim — replaced with a length marker.
    public static let secretKeys: Set<String> = ["text", "value", "content"]

    /// Redact a tool's MCP params into a flat string dict safe to serialize.
    /// Secret keys collapse to `<redacted len=N>`; every other value is
    /// stringified and scrubbed of any tree-ref / pointer leak.
    public static func redactParams(tool: String, params: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, raw) in params {
            if secretKeys.contains(key) {
                let len = (raw as? String).map { $0.count } ?? stringify(raw).count
                out[key] = "<redacted len=\(len)>"
            } else {
                out[key] = scrubString(stringify(raw))
            }
        }
        return out
    }

    /// Stringify a JSON-primitive param value compactly.
    static func stringify(_ raw: Any) -> String {
        switch raw {
        case let s as String: return s
        case let b as Bool: return b ? "true" : "false"
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        default: return String(describing: raw)
        }
    }

    /// Strip anything that looks like an AX element ref or raw pointer so it can
    /// never reach the audit file (Invariant 8). Replaces `<AXUIElement 0x…>`
    /// wrappers and bare hex pointers with `<ref>`.
    public static func scrubString(_ s: String) -> String {
        guard s.contains("0x") || s.contains("AXUIElement") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        let scalars = Array(s.unicodeScalars)
        var i = 0
        let n = scalars.count
        func isHex(_ c: Unicode.Scalar) -> Bool {
            (c >= "0" && c <= "9") || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")
        }
        while i < n {
            // Match `<AXUIElement ...>` wrapper.
            if matches(scalars, i, "<AXUIElement") {
                while i < n && scalars[i] != ">" { i += 1 }
                if i < n { i += 1 } // consume '>'
                result += "<ref>"
                continue
            }
            // Match a bare `0x…` hex pointer.
            if i + 1 < n && scalars[i] == "0" && (scalars[i + 1] == "x" || scalars[i + 1] == "X") {
                var j = i + 2
                while j < n && isHex(scalars[j]) { j += 1 }
                if j > i + 2 {
                    result += "<ref>"
                    i = j
                    continue
                }
            }
            result.unicodeScalars.append(scalars[i])
            i += 1
        }
        return result
    }

    private static func matches(_ scalars: [Unicode.Scalar], _ at: Int, _ token: String) -> Bool {
        let t = Array(token.unicodeScalars)
        guard at + t.count <= scalars.count else { return false }
        for k in 0..<t.count where scalars[at + k] != t[k] { return false }
        return true
    }
}

// MARK: - Sink

/// Where audit records land. Sync by design — it drops into the spine's
/// synchronous return paths with no async ripple.
public protocol AuditSink: AnyObject {
    func record(_ record: AuditRecord)
}

/// Default no-op sink (audit disabled).
public final class NoopAuditSink: AuditSink {
    public init() {}
    public func record(_ record: AuditRecord) {}
}

/// In-memory sink for tests — keeps the raw records and their JSONL lines.
public final class BufferingAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [AuditRecord] = []

    public init() {}

    public func record(_ record: AuditRecord) {
        lock.lock(); defer { lock.unlock() }
        _records.append(record)
    }

    public var records: [AuditRecord] {
        lock.lock(); defer { lock.unlock() }
        return _records
    }

    public var lines: [String] {
        records.map { $0.jsonLine() }
    }
}

/// Appends one JSON line per action to a file. Foundation-only (Linux-safe).
/// Thread-safe via a lock; opens the handle lazily and appends.
public final class JSONLAuditSink: AuditSink, @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()

    public init(path: URL) {
        self.path = path
    }

    public func record(_ record: AuditRecord) {
        lock.lock(); defer { lock.unlock() }
        guard let data = (record.jsonLine() + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path.path) {
            try? fm.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: path)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: path) else { return }
        defer { try? handle.close() }
        if #available(macOS 10.15.4, *) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }
}
