import XCTest
import Foundation
import MacCUACore
@testable import MacCUAServer

// Tests for the MCP server layer (ToolDefs, formatMCP, PermissionsGate,
// MCPServer). All pure / Linux-buildable; providers come from Fakes.swift.

final class ServerLayerTests: XCTestCase {

    // MARK: - Tool definitions

    func testAllEightToolDefsPresentWithExactNames() {
        let names = toolDefs.map(\.name)
        XCTAssertEqual(names, [
            "list_apps",
            "get_app_state",
            "click",
            "drag",
            "press_key",
            "type_text",
            "set_value",
            "scroll",
            "perform_secondary_action",
            "batch",
        ])
        // server.py's TOOL_DEFS has 9 entries (list_apps + the 8 action tools);
        // `batch` (Codex parity §D3, US-008) is appended → 10.
        XCTAssertEqual(toolDefs.count, 10)
    }

    func testToolDefRequiredFieldsMatchPython() {
        func schema(_ name: String) -> [String: Any] {
            toolDefs.first { $0.name == name }!.inputSchema
        }
        func required(_ name: String) -> [String] {
            (schema(name)["required"] as? [String]) ?? []
        }

        XCTAssertEqual(required("list_apps"), [])
        XCTAssertEqual(required("get_app_state"), [])
        XCTAssertEqual(required("click"), [])
        XCTAssertEqual(required("drag"), ["from_x", "from_y", "to_x", "to_y"])
        XCTAssertEqual(required("press_key"), ["key"])
        XCTAssertEqual(required("type_text"), ["text"])
        XCTAssertEqual(required("set_value"), ["element_index", "value"])
        XCTAssertEqual(required("scroll"), ["direction"])
        XCTAssertEqual(required("perform_secondary_action"), ["element_index", "action"])
    }

    func testToolDefDescriptionsCopiedVerbatim() {
        let scroll = toolDefs.first { $0.name == "scroll" }!
        XCTAssertEqual(scroll.description, "Scroll an element in a direction by a number of pages.")
        let secondary = toolDefs.first { $0.name == "perform_secondary_action" }!
        XCTAssertEqual(secondary.description, "Invoke a secondary accessibility action exposed by an element.")
        let click = toolDefs.first { $0.name == "click" }!
        XCTAssertTrue(click.description.contains("background-targeted and do not activate the window"))
    }

    func testInputSchemaRendersToJSON() throws {
        let listApps = toolDefs.first { $0.name == "list_apps" }!
        let json = try listApps.inputSchemaJSON()
        // additionalProperties false, type object, empty properties object.
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "object")
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertNotNil(obj["properties"] as? [String: Any])

        // Round-trip a tool with enum + default values.
        let click = toolDefs.first { $0.name == "click" }!
        let clickObj = try JSONSerialization.jsonObject(with: try click.inputSchemaJSONData()) as! [String: Any]
        let props = clickObj["properties"] as! [String: Any]
        let mouseButton = props["mouse_button"] as! [String: Any]
        XCTAssertEqual(mouseButton["enum"] as? [String], ["left", "right", "middle"])
        XCTAssertEqual(mouseButton["default"] as? String, "left")
    }

    // MARK: - formatMCP

    func testFormatMCPErrorOnlyResponse() {
        let resp = ToolResponse(
            app: "Notes", pid: 1, snapshotId: 1,
            treeText: nil,
            result: nil,
            error: "boom: something failed"
        )
        let blocks = formatMCP(resp)
        XCTAssertEqual(blocks, [.text("boom: something failed")])
    }

    func testFormatMCPNoTreeResultAndError() {
        let resp = ToolResponse(
            app: "Notes", pid: 1, snapshotId: 1,
            treeText: nil,
            result: "did the thing",
            error: "but also a warning"
        )
        let blocks = formatMCP(resp)
        XCTAssertEqual(blocks, [.text("did the thing"), .text("but also a warning")])
    }

    func testFormatMCPNoTreeEmptyReturnsNoBlocks() {
        let resp = ToolResponse(app: "Notes", pid: 1, snapshotId: 1, treeText: nil)
        XCTAssertEqual(formatMCP(resp), [])
    }

    func testFormatMCPFullResponseHeaderTreeGuidanceSelectionScreenshot() {
        let tree = "Window: Notes\n\n[0] button \"OK\""
        let resp = ToolResponse(
            app: "Notes", pid: 1, snapshotId: 1,
            treeText: tree,
            screenshot: "QkFTRTY0UE5H", // "BASE64PNG"
            result: "Clicked element 0.",
            guidance: "Use coordinates when AX is sparse.",
            systemSelection: "Selected: hello world"
        )
        let blocks = formatMCP(resp)
        XCTAssertEqual(blocks.count, 2)

        guard case let .text(text) = blocks[0] else {
            return XCTFail("first block should be text")
        }

        // Version header present (matches Core's formatResponseHeader()).
        XCTAssertTrue(text.hasPrefix(Version.formatResponseHeader()))
        // Result included.
        XCTAssertTrue(text.contains("Clicked element 0."))
        // <app_state> wrapper present.
        XCTAssertTrue(text.contains("<app_state>"))
        XCTAssertTrue(text.contains("</app_state>"))
        // Guidance wrapped and spliced after the tree header (before the body).
        XCTAssertTrue(text.contains("<app_specific_instructions>\nUse coordinates when AX is sparse.\n</app_specific_instructions>"))
        // Header stays first, guidance comes before the tree body.
        let headerIdx = text.range(of: "Window: Notes")!.lowerBound
        let guidanceIdx = text.range(of: "<app_specific_instructions>")!.lowerBound
        let bodyIdx = text.range(of: "[0] button")!.lowerBound
        XCTAssertTrue(headerIdx < guidanceIdx)
        XCTAssertTrue(guidanceIdx < bodyIdx)
        // System selection appended.
        XCTAssertTrue(text.contains("Selected: hello world"))

        // Trailing image block.
        XCTAssertEqual(blocks[1], .image(base64: "QkFTRTY0UE5H", mimeType: "image/png"))
    }

    func testFormatMCPGuidanceNoHeaderBreakFallback() {
        // tree_text without a "\n\n" header break → guidance prefixes whole tree.
        let resp = ToolResponse(
            app: "X", pid: 1, snapshotId: 1,
            treeText: "single line tree",
            guidance: "hint"
        )
        let blocks = formatMCP(resp)
        guard case let .text(text) = blocks[0] else { return XCTFail() }
        XCTAssertTrue(text.contains("<app_specific_instructions>\nhint\n</app_specific_instructions>\n\nsingle line tree"))
    }

    func testFormatMCPFullResponseVersionHeaderPresent() {
        let resp = ToolResponse(app: "X", pid: 1, snapshotId: 1, treeText: "tree")
        guard case let .text(text) = formatMCP(resp)[0] else { return XCTFail() }
        XCTAssertTrue(text.contains("Desktop Automation state (version:"))
        XCTAssertEqual(text.components(separatedBy: "\n").first, Version.formatResponseHeader())
    }

    func testFormatMCPNoScreenshotNoImageBlock() {
        let resp = ToolResponse(app: "X", pid: 1, snapshotId: 1, treeText: "tree", result: "ok")
        let blocks = formatMCP(resp)
        XCTAssertEqual(blocks.count, 1)
        if case .image = blocks[0] { XCTFail("should not emit image block") }
    }

    // MARK: - PermissionsGate

    func testGateReturnsPendingUntilBothGrantedThenNil() {
        let apps = FakeAppResolver()
        let capture = FakeCapture()
        apps.accessibilityGranted = false
        capture.screenRecordingGranted = false
        let gate = PermissionsGate(apps: apps, capture: capture)

        // First call: neither granted → pending.
        XCTAssertEqual(gate.checkWithRetryGuidance(), permissionsPendingMessage)
        // AX granted, screen still pending.
        apps.accessibilityGranted = true
        XCTAssertEqual(gate.checkWithRetryGuidance(), permissionsPendingMessage)
        // Both granted → nil.
        capture.screenRecordingGranted = true
        XCTAssertNil(gate.checkWithRetryGuidance())
    }

    func testGatePromptsOnFirstCallThenChecksWithoutPrompt() {
        final class RecordingResolver: AppResolver {
            var grants: Bool
            private(set) var promptCalls: [Bool] = []
            init(grants: Bool) { self.grants = grants }
            func listRunningApps() -> [AppInfo] { [] }
            func listRecentApps() -> [AppInfo] { [] }
            func resolveApp(_ hint: String) throws -> AppInfo { throw AutomationError.automation("x") }
            func resolveRunningAppByPid(_ pid: Int) -> AppInfo? { nil }
            func launchApp(bundleId: String) throws -> Int { 0 }
            func getAXApp(bundleId: String, knownPid: Int?) throws -> (axApp: AXElementRef, pid: Int) { (FakeAXRef("a"), 0) }
            func getAXAppForPid(_ pid: Int, bundleId: String?) throws -> (axApp: AXElementRef, pid: Int) { (FakeAXRef("a"), pid) }
            func getFrontmostApp() -> AppInfo? { nil }
            func restoreFrontmostApp(_ app: AppInfo?) {}
            func checkAccessibilityPermission(prompt: Bool) -> Bool { promptCalls.append(prompt); return grants }
        }
        let apps = RecordingResolver(grants: true)
        let gate = PermissionsGate(apps: apps, capture: FakeCapture())

        XCTAssertNil(gate.checkWithRetryGuidance())
        XCTAssertNil(gate.checkWithRetryGuidance())
        // First call prompts (true), subsequent does not (false).
        XCTAssertEqual(apps.promptCalls, [true, false])
    }

    // MARK: - MCPServer

    func testMCPServerListToolsReturnsCatalogue() {
        let server = MCPServer(
            sessionManager: SessionManager(providers: makeFakeProviders()),
            permissions: PermissionsGate(apps: FakeAppResolver(), capture: FakeCapture())
        )
        XCTAssertEqual(server.listTools().map(\.name).first, "list_apps")
        XCTAssertEqual(server.listTools().count, 10)
        XCTAssertEqual(server.listTools().map(\.name).last, "batch")
    }

    func testMCPServerCallToolGateReturnsPendingMessage() {
        let apps = FakeAppResolver()
        apps.accessibilityGranted = false
        let providers = makeFakeProviders(apps: apps)
        let server = MCPServer(sessionManager: SessionManager(providers: providers), providers: providers)
        let blocks = server.callTool(name: "click", arguments: nil)
        XCTAssertEqual(blocks, [.text(permissionsPendingMessage)])
    }

    func testMCPServerCallToolWhenGrantedFormatsResponse() {
        // Spine is a stub returning errorOnly(...); verify the gate passes and we
        // get the formatted (no-tree) error block back rather than the pending msg.
        let providers = makeFakeProviders()
        let server = MCPServer(sessionManager: SessionManager(providers: providers), providers: providers)
        let blocks = server.callTool(name: "click", arguments: ["x": 1.0, "y": 2.0])
        XCTAssertFalse(blocks.isEmpty)
        if case let .text(t) = blocks[0] {
            XCTAssertNotEqual(t, permissionsPendingMessage)
        } else {
            XCTFail("expected a text block")
        }
    }
}
