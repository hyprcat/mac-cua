import XCTest
import MacCUACore
@testable import MacCUAServer

/// US-048: the spine emits exactly one redacted audit record per action through
/// the injected `AuditSink`, with secrets stripped. Driven through the real spine
/// against fakes (Linux-green).
final class AuditSinkSpineTests: XCTestCase {
    private let pid = 222
    private let windowId = 88

    private func capture() -> FakeCapture {
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowId, ownerPid: pid, ownerName: "Example",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true)
        ]
        return cap
    }

    private func apps() -> FakeAppResolver {
        let a = FakeAppResolver()
        a.running = [AppInfo(name: "Example", bundleId: "com.example.App", pid: pid, running: true)]
        a.resolved = a.running.first
        return a
    }

    private func flags() -> FeatureFlags {
        FeatureFlags(
            treePruning: false, userInterruptionDetection: false, focusEnforcement: false,
            menuTracking: false, transientGraphs: false, axActionVerification: false,
            cgeventActionVerification: false, systemSelection: false, confirmedDelivery: false)
    }

    private func manager(_ sink: AuditSink) -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(apps: apps(), capture: capture(), auditSink: sink),
            flags: flags())
    }

    func testClickEmitsOneRecord() {
        let sink = BufferingAuditSink()
        let mgr = manager(sink)
        _ = mgr.execute("click", ["window_id": windowId, "x": 12.0, "y": 34.0])
        XCTAssertEqual(sink.records.count, 1)
        let rec = sink.records[0]
        XCTAssertEqual(rec.tool, "click")
        XCTAssertEqual(rec.app, "com.example.App")
        XCTAssertTrue(rec.success)
        XCTAssertEqual(rec.params["window_id"], "88")
    }

    func testTypeTextSecretIsRedactedInAudit() {
        let sink = BufferingAuditSink()
        let mgr = manager(sink)
        _ = mgr.execute(
            "type_text", ["window_id": windowId, "x": 1.0, "y": 2.0, "text": "my-pa$$word"])
        XCTAssertEqual(sink.records.count, 1)
        let rec = sink.records[0]
        XCTAssertEqual(rec.params["text"], "<redacted len=11>")
        // The secret must not survive anywhere in the serialized line.
        XCTAssertFalse(rec.jsonLine().contains("pa$$word"))
    }

    func testFailedActionRecordsError() {
        let sink = BufferingAuditSink()
        let mgr = manager(sink)
        // No such window → resolution fails → an error record is still emitted.
        _ = mgr.execute("click", ["window_id": 9999, "x": 1.0, "y": 2.0])
        XCTAssertEqual(sink.records.count, 1)
        XCTAssertFalse(sink.records[0].success)
        XCTAssertNotNil(sink.records[0].error)
    }

    func testNoSinkIsNoop() {
        // Default providers carry no audit sink — must not crash.
        let mgr = SessionManager(
            providers: makeFakeProviders(apps: apps(), capture: capture()), flags: flags())
        let resp = mgr.execute("click", ["window_id": windowId, "x": 1.0, "y": 2.0])
        XCTAssertNil(resp.error)
    }
}
