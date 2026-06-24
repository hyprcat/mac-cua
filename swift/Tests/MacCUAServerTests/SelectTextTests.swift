import XCTest
import MacCUACore
@testable import MacCUAServer

/// `select_text` tool (Codex parity §D1, US-010 wiring). Verifies the spine reads
/// the target text via the `SelectionProvider` seam, runs the pure
/// `SelectTextResolver` (US-005), applies the resolved range, and reports
/// ambiguity / not-found honestly. The real Mac selection is US-040; here the
/// seam is the `FakeSelection`.
final class SelectTextTests: XCTestCase {

    private let pid = 333
    private let windowId = 91

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

    private func manager(_ selection: FakeSelection) -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(
                apps: apps(), capture: capture(),
                makeSelectionClient: { _ in selection }))
    }

    /// A unique match resolves to a range and is applied; a snapshot is returned.
    func testUniqueMatchSelected() {
        let sel = FakeSelection()
        sel.text = "hello world"
        let mgr = manager(sel)

        let resp = mgr.execute("select_text", ["window_id": windowId, "content": "world"])

        XCTAssertNil(resp.error)
        XCTAssertEqual(sel.appliedRanges, [TextRange(location: 6, length: 5)])
        XCTAssertNotNil(resp.screenshot)
        XCTAssertEqual(resp.result, "Selected 5 chars at offset 6.")
    }

    /// A duplicate match without disambiguation is reported as ambiguous, and
    /// nothing is applied.
    func testAmbiguousMatchErrors() {
        let sel = FakeSelection()
        sel.text = "ab ab ab"
        let mgr = manager(sel)

        let resp = mgr.execute("select_text", ["window_id": windowId, "content": "ab"])

        XCTAssertTrue(resp.error?.contains("matches 3 places") ?? false)
        XCTAssertTrue(sel.appliedRanges.isEmpty)
    }

    /// prefix disambiguates a repeated substring.
    func testPrefixDisambiguates() {
        let sel = FakeSelection()
        sel.text = "one cat two cat"
        let mgr = manager(sel)

        let resp = mgr.execute(
            "select_text", ["window_id": windowId, "content": "cat", "prefix": "two "])

        XCTAssertNil(resp.error)
        XCTAssertEqual(sel.appliedRanges, [TextRange(location: 12, length: 3)])
    }

    /// A not-found content reports cleanly; nothing applied.
    func testNotFoundErrors() {
        let sel = FakeSelection()
        sel.text = "hello"
        let mgr = manager(sel)

        let resp = mgr.execute("select_text", ["window_id": windowId, "content": "zzz"])

        XCTAssertTrue(resp.error?.contains("could not find") ?? false)
        XCTAssertTrue(sel.appliedRanges.isEmpty)
    }

    /// caret='before' collapses to a zero-length range at the match start.
    func testCaretBefore() {
        let sel = FakeSelection()
        sel.text = "hello world"
        let mgr = manager(sel)

        let resp = mgr.execute(
            "select_text", ["window_id": windowId, "content": "world", "caret": "before"])

        XCTAssertNil(resp.error)
        XCTAssertEqual(sel.appliedRanges, [TextRange(location: 6, length: 0)])
        XCTAssertEqual(resp.result, "Placed caret before the match (offset 6).")
    }

    /// caret='after' collapses to a zero-length range at the match end.
    func testCaretAfter() {
        let sel = FakeSelection()
        sel.text = "hello world"
        let mgr = manager(sel)

        let resp = mgr.execute(
            "select_text", ["window_id": windowId, "content": "hello", "caret": "after"])

        XCTAssertNil(resp.error)
        XCTAssertEqual(sel.appliedRanges, [TextRange(location: 5, length: 0)])
    }

    /// Missing content → clean error, no selection client read.
    func testMissingContentErrors() {
        let sel = FakeSelection()
        let mgr = manager(sel)

        let resp = mgr.execute("select_text", ["window_id": windowId])

        XCTAssertNotNil(resp.error)
        XCTAssertTrue(sel.selectableTextCalls.isEmpty)
    }

    /// An element_index is resolved and its axRef is threaded to the seam.
    func testElementIndexThreadsAXRef() {
        let sel = FakeSelection()
        sel.text = "target here"
        let acc = FakeAccessibility()
        acc.tree = [Node(index: 0, role: "text field", depth: 0, axRef: FakeAXRef("field"))]
        let mgr = SessionManager(
            providers: makeFakeProviders(
                apps: apps(), accessibility: acc, capture: capture(),
                makeSelectionClient: { _ in sel }))
        // Seed the session tree so resolveIndex finds the node.
        _ = mgr.execute("get_app_state", ["window_id": windowId])

        let resp = mgr.execute(
            "select_text", ["window_id": windowId, "content": "target", "element_index": "0"])

        XCTAssertNil(resp.error)
        XCTAssertEqual(sel.selectableTextCalls.last, true)  // axRef supplied
    }
}
