import XCTest
import MacCUACore
@testable import MacCUAServer

/// US-027 — Phase-3 acceptance: real `list_apps` + `get_app_state` end-to-end.
///
/// The real-app behavior (live AX read + SCK capture against Safari/Slack/System
/// Settings) is a MANUAL-VERIFY item; what is verifiable on Linux is the
/// END-TO-END packet shape the two read tools produce when driven through the
/// real spine (`execute`) and rendered through `formatMCP`. These tests prove the
/// integration wiring of the already-landed pieces (US-016 resolver, US-017/018
/// walker, US-019 enhanced-UI, US-022/023/024 capture, pruning, serialize):
///
///   * `get_app_state` → a `<app_state>` text block carrying the serialized tree
///     with dense `0..N-1` indices, a trailing PNG image block, and NO
///     foregrounding (Prime Invariant / Inv 7 — no frontmost restore on a
///     state-only read).
///   * pruning reindexes a sparse/out-of-order walk to dense `0..N-1` in the
///     final packet.
///   * an "announced truncation" (web-area cap) survives all the way into the
///     model-facing packet text.
///   * `list_apps` → the no-tree plain-text path (no image, no session created).
final class Phase3AcceptanceTests: XCTestCase {

    private let pid = 111
    private let windowId = 77

    // MARK: - Fixtures

    private func apps() -> FakeAppResolver {
        let a = FakeAppResolver()
        a.running = [AppInfo(name: "Example", bundleId: "com.example.App", pid: pid, running: true)]
        a.resolved = a.running.first
        // The user's frontmost app is someone else — a state-only read must NOT
        // restore/activate anything (no foregrounding).
        a.frontmost = AppInfo(name: "UserApp", bundleId: "com.user.app", pid: 999, running: true)
        return a
    }

    private func capture() -> FakeCapture {
        let cap = FakeCapture()
        cap.windows = [
            WindowInfo(windowId: windowId, ownerPid: pid, ownerName: "Example",
                       title: "Doc", x: 0, y: 0, width: 800, height: 600, onscreen: true)
        ]
        return cap
    }

    /// Flags geared for a deterministic read-tool run. `treePruning` toggled per
    /// test; codex style OFF so indices serialize as bracketed `[n]` for parsing.
    private func flags(treePruning: Bool = false) -> FeatureFlags {
        FeatureFlags(
            treePruning: treePruning,
            codexTreeStyle: false,
            richTextMarkdown: false,
            webContentExtraction: false,
            userInterruptionDetection: false,
            focusEnforcement: false,
            menuTracking: false,
            transientGraphs: false,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: false,
            confirmedDelivery: false)
    }

    private func manager(ax: FakeAccessibility, cap: FakeCapture, apps: FakeAppResolver,
                         flags: FeatureFlags) -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: ax, capture: cap),
            flags: flags)
    }

    /// Parse every bracketed `[n]` element index out of a serialized tree block,
    /// in document order.
    private func parsedIndices(_ text: String) -> [Int] {
        var out: [Int] = []
        let scalars = Array(text)
        var i = 0
        while i < scalars.count {
            if scalars[i] == "[" {
                var j = i + 1
                var digits = ""
                while j < scalars.count, scalars[j].isNumber { digits.append(scalars[j]); j += 1 }
                if j < scalars.count, scalars[j] == "]", !digits.isEmpty, let n = Int(digits) {
                    out.append(n)
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }

    private func textBlock(_ blocks: [MCPContent]) -> String? {
        for case let .text(s) in blocks { return s }
        return nil
    }

    private func imageBlock(_ blocks: [MCPContent]) -> (base64: String, mime: String)? {
        for case let .image(base64, mime) in blocks { return (base64, mime) }
        return nil
    }

    // MARK: - get_app_state end-to-end packet shape

    /// Acceptance: get_app_state produces a `<app_state>` text block with the
    /// serialized tree + a trailing PNG image block, and foregrounds nothing.
    func testGetAppStateEndToEndPacketShape() {
        let ax = FakeAccessibility()
        ax.tree = [
            Node(index: 0, role: "button", label: "OK", depth: 0,
                 axRef: FakeAXRef("n0"), axRole: "AXButton"),
            Node(index: 1, role: "textfield", label: "Name", depth: 0,
                 axRef: FakeAXRef("n1"), axRole: "AXTextField"),
            Node(index: 2, role: "checkbox", label: "Remember me", depth: 0,
                 axRef: FakeAXRef("n2"), axRole: "AXCheckBox"),
        ]
        let cap = capture()
        let appResolver = apps()
        let mgr = manager(ax: ax, cap: cap, apps: appResolver, flags: flags())

        let response = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(response.error, response.error ?? "")

        let blocks = formatMCP(response)

        // Text block: app_state wrapper + the three tree rows in order.
        guard let text = textBlock(blocks) else {
            return XCTFail("expected a text block")
        }
        XCTAssertTrue(text.contains("<app_state>"), text)
        XCTAssertTrue(text.contains("</app_state>"), text)
        XCTAssertEqual(parsedIndices(text), [0, 1, 2], text)
        XCTAssertTrue(text.contains("button"))
        XCTAssertTrue(text.contains("checkbox"))

        // Trailing image block carries the captured PNG.
        guard let img = imageBlock(blocks) else {
            return XCTFail("expected an image block")
        }
        XCTAssertEqual(img.mime, "image/png")
        XCTAssertEqual(img.base64, "ZmFrZS1wbmc=")
        XCTAssertEqual(cap.captureCalls, [windowId])

        // Prime Invariant: a state-only read foregrounds nothing.
        XCTAssertTrue(appResolver.restoreCalls.isEmpty, "state-only read must not restore/activate")
    }

    /// Acceptance: pruning reindexes a sparse/out-of-order walk so the packet's
    /// element indices are dense `0..N-1`.
    func testGetAppStateDenseReindexThroughPruning() {
        let ax = FakeAccessibility()
        // Walk emits non-dense indices (0, 7, 42) — pruning must renumber them.
        ax.tree = [
            Node(index: 0, role: "button", label: "Alpha", depth: 0,
                 axRef: FakeAXRef("a"), axRole: "AXButton"),
            Node(index: 7, role: "button", label: "Beta", depth: 0,
                 axRef: FakeAXRef("b"), axRole: "AXButton"),
            Node(index: 42, role: "button", label: "Gamma", depth: 0,
                 axRef: FakeAXRef("c"), axRole: "AXButton"),
        ]
        let cap = capture()
        let mgr = manager(ax: ax, cap: cap, apps: apps(), flags: flags(treePruning: true))

        let response = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(response.error, response.error ?? "")

        let text = textBlock(formatMCP(response)) ?? ""
        let indices = parsedIndices(text)
        XCTAssertFalse(indices.isEmpty, text)
        // Dense 0..N-1, in order, regardless of the walk's original numbering.
        XCTAssertEqual(indices, Array(0..<indices.count), text)
    }

    /// Acceptance: an "announced truncation" (web-area node cap) survives end-to-
    /// end into the model-facing packet text.
    func testGetAppStateAnnouncedTruncationSurvivesToPacket() {
        let ax = FakeAccessibility()
        var tree: [Node] = [
            Node(index: 0, role: "web area", label: "Page", depth: 0,
                 axRef: FakeAXRef("wa"), isWebArea: true, axRole: "AXWebArea"),
        ]
        // 305 children one level under the web area → 5 over the 300 cap.
        let overflow = webAreaNodeCap + 5
        for k in 0..<overflow {
            tree.append(Node(index: k + 1, role: "link", label: "L\(k)", depth: 1,
                             axRef: FakeAXRef("l\(k)"), axRole: "AXLink"))
        }
        ax.tree = tree
        let cap = capture()
        let mgr = manager(ax: ax, cap: cap, apps: apps(), flags: flags(treePruning: true))

        let response = mgr.execute("get_app_state", ["window_id": windowId])
        XCTAssertNil(response.error, response.error ?? "")

        let text = textBlock(formatMCP(response)) ?? ""
        XCTAssertTrue(text.contains("earlier elements truncated"),
                      "expected the web-area truncation announcement in the packet:\n\(text.prefix(500))")
        // Indices still dense after the truncation removed nodes.
        let indices = parsedIndices(text)
        XCTAssertEqual(indices, Array(0..<indices.count), "indices must stay dense after truncation")
    }

    // MARK: - list_apps end-to-end (no-tree text path)

    /// Acceptance: list_apps takes the no-tree path — a plain-text block, no
    /// image, no session created, nothing foregrounded.
    func testListAppsEndToEndNoTreePath() {
        let cap = capture()
        let appResolver = apps()
        let mgr = manager(ax: FakeAccessibility(), cap: cap, apps: appResolver, flags: flags())

        let response = mgr.execute("list_apps", [:])
        XCTAssertNil(response.error)
        XCTAssertNil(response.treeText)
        XCTAssertNil(response.screenshot)

        let blocks = formatMCP(response)
        XCTAssertNil(imageBlock(blocks), "list_apps must not attach an image")
        let text = textBlock(blocks) ?? ""
        XCTAssertTrue(text.contains("Example"), text)
        XCTAssertTrue(text.contains("com.example.App"), text)

        XCTAssertTrue(mgr.sessions.isEmpty, "list_apps must not create a session")
        XCTAssertTrue(appResolver.restoreCalls.isEmpty)
        XCTAssertTrue(cap.captureCalls.isEmpty, "list_apps must not capture a screenshot")
    }
}
