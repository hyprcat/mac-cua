import XCTest
import MacCUACore
@testable import MacCUAServer

/// `clipboard` tool (Codex parity §D2, US-010 wiring). Verifies get/set/clear
/// route to the `ClipboardProvider` seam. No app target, no session, no settle —
/// the pasteboard is system-wide. Real NSPasteboard impl is US-041.
final class ClipboardTests: XCTestCase {

    private func manager(_ clip: FakeClipboard) -> SessionManager {
        SessionManager(providers: makeFakeProviders(clipboard: clip))
    }

    func testGetReturnsContents() {
        let clip = FakeClipboard()
        clip.contents = "hi"
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "get"])

        XCTAssertNil(resp.error)
        XCTAssertTrue(resp.result?.contains("hi") ?? false)
    }

    func testGetEmpty() {
        let clip = FakeClipboard()
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "get"])

        XCTAssertEqual(resp.result, "Clipboard is empty.")
    }

    func testSetWritesContents() {
        let clip = FakeClipboard()
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "set", "text": "paste me"])

        XCTAssertNil(resp.error)
        XCTAssertEqual(clip.sets, ["paste me"])
        XCTAssertEqual(clip.contents, "paste me")
    }

    func testSetWithoutTextErrors() {
        let clip = FakeClipboard()
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "set"])

        XCTAssertNotNil(resp.error)
        XCTAssertTrue(clip.sets.isEmpty)
    }

    func testClearEmptiesContents() {
        let clip = FakeClipboard()
        clip.contents = "something"
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "clear"])

        XCTAssertNil(resp.error)
        XCTAssertEqual(clip.clears, 1)
        XCTAssertNil(clip.contents)
    }

    func testUnknownActionErrors() {
        let clip = FakeClipboard()
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "bogus"])

        XCTAssertNotNil(resp.error)
    }

    func testMissingActionErrors() {
        let clip = FakeClipboard()
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", [:])

        XCTAssertNotNil(resp.error)
    }

    func testProviderFailureSurfacedAsError() {
        let clip = FakeClipboard()
        clip.getThrows = true
        let mgr = manager(clip)

        let resp = mgr.execute("clipboard", ["action": "get"])

        XCTAssertNotNil(resp.error)
    }
}
