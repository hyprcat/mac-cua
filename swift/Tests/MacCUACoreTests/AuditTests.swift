import XCTest
@testable import MacCUACore

final class AuditTests: XCTestCase {

    // MARK: - Redaction: secrets

    func testSecretKeysRedactedToLength() {
        let p = AuditRedactor.redactParams(
            tool: "type_text", params: ["text": "hunter2 password", "element_index": 4])
        XCTAssertEqual(p["text"], "<redacted len=16>")
        XCTAssertEqual(p["element_index"], "4")
        XCTAssertFalse(p["text"]!.contains("hunter2"))
    }

    func testAllSecretKeysRedacted() {
        for key in ["text", "value", "content"] {
            let p = AuditRedactor.redactParams(tool: "x", params: [key: "s3cr3t-data"])
            XCTAssertEqual(p[key], "<redacted len=11>")
            XCTAssertFalse(p[key]!.contains("s3cr3t"))
        }
    }

    func testNonSecretParamsStringified() {
        let p = AuditRedactor.redactParams(
            tool: "click", params: ["window_id": 99, "double": true, "app": "Safari"])
        XCTAssertEqual(p["window_id"], "99")
        XCTAssertEqual(p["double"], "true")
        XCTAssertEqual(p["app"], "Safari")
    }

    // MARK: - Redaction: tree refs (Invariant 8)

    func testScrubAXElementWrapper() {
        XCTAssertEqual(
            AuditRedactor.scrubString("clicked <AXUIElement 0x600001234560> ok"),
            "clicked <ref> ok")
    }

    func testScrubBareHexPointer() {
        XCTAssertEqual(AuditRedactor.scrubString("ptr=0xdeadbeef done"), "ptr=<ref> done")
    }

    func testScrubLeavesCleanStringsUntouched() {
        XCTAssertEqual(AuditRedactor.scrubString("just a normal label"), "just a normal label")
    }

    func testRedactParamsScrubsRefInNonSecretValue() {
        let p = AuditRedactor.redactParams(
            tool: "click", params: ["hint": "<AXUIElement 0x7f8b> button"])
        XCTAssertFalse(p["hint"]!.contains("0x"))
        XCTAssertFalse(p["hint"]!.contains("AXUIElement"))
        XCTAssertEqual(p["hint"], "<ref> button")
    }

    // MARK: - JSON line shape

    func testJSONLineShapeDeterministic() {
        let rec = AuditRecord(
            timestamp: 1.5, tool: "click", app: "com.apple.Safari",
            success: true, params: ["window_id": "7"])
        XCTAssertEqual(
            rec.jsonLine(),
            #"{"app":"com.apple.Safari","params":{"window_id":"7"},"success":true,"tool":"click","ts":1.5}"#)
    }

    func testJSONLineOmitsAbsentFields() {
        let rec = AuditRecord(timestamp: 0, tool: "wait", app: nil, success: false)
        let line = rec.jsonLine()
        XCTAssertFalse(line.contains("app"))
        XCTAssertFalse(line.contains("error"))
        XCTAssertFalse(line.contains("params"))
        XCTAssertTrue(line.contains("\"success\":false"))
    }

    func testJSONLineScrubsErrorMessage() {
        let rec = AuditRecord(
            timestamp: 0, tool: "click", app: "a", success: false,
            error: "stale ref <AXUIElement 0x123abc>")
        let line = rec.jsonLine()
        XCTAssertFalse(line.contains("0x123abc"))
        XCTAssertTrue(line.contains("<ref>"))
    }

    func testNoSecretSurvivesIntoJSONLine() {
        let params = AuditRedactor.redactParams(tool: "type_text", params: ["text": "TOPSECRET"])
        let rec = AuditRecord(timestamp: 0, tool: "type_text", app: "a", success: true, params: params)
        XCTAssertFalse(rec.jsonLine().contains("TOPSECRET"))
    }

    // MARK: - Sinks

    func testBufferingSinkCollects() {
        let sink = BufferingAuditSink()
        sink.record(AuditRecord(timestamp: 0, tool: "click", app: "a", success: true))
        sink.record(AuditRecord(timestamp: 1, tool: "type_text", app: "a", success: false))
        XCTAssertEqual(sink.records.count, 2)
        XCTAssertEqual(sink.lines.count, 2)
        XCTAssertEqual(sink.records[0].tool, "click")
    }

    func testNoopSinkDoesNothing() {
        let sink = NoopAuditSink()
        sink.record(AuditRecord(timestamp: 0, tool: "click", app: "a", success: true))
        // Nothing to assert beyond "does not crash".
    }

    func testJSONLSinkAppendsLines() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maccua-audit-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("audit.jsonl")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sink = JSONLAuditSink(path: file)
        sink.record(AuditRecord(timestamp: 1, tool: "click", app: "a", success: true))
        sink.record(AuditRecord(
            timestamp: 2, tool: "type_text", app: "a", success: true,
            params: AuditRedactor.redactParams(tool: "type_text", params: ["text": "secret"])))

        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("\"tool\":\"click\""))
        XCTAssertTrue(lines[1].contains("<redacted len=6>"))
        XCTAssertFalse(contents.contains("secret"))
        // Each line is valid JSON.
        for l in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(l.utf8)))
        }
    }
}
