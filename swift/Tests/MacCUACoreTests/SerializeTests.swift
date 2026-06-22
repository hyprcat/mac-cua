import XCTest
@testable import MacCUACore

// Ports the intent of `tests/test_tree.py` plus golden-text checks for the
// model-facing serialization format, including AX-ref scrubbing (Invariant 8).
final class SerializeTests: XCTestCase {

    // MARK: - Bracketed vs plain indices

    func testSerializeUsesBracketedIndices() {
        let node = Node(index: 12, role: "row", label: "Replay 2024", depth: 0)
        let text = serialize([node], enablePruning: false)
        XCTAssertTrue(text.hasPrefix("[12] row Replay 2024"))
    }

    func testSerializeCodexStyleUsesPlainIndices() {
        let node = Node(
            index: 12, role: "row", label: "Replay 2024",
            states: ["selectable"], value: "Replay 2024", depth: 0)
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(text.hasPrefix("12 row (selectable) Replay 2024"))
    }

    // MARK: - Frame hints

    func testSerializeIncludesFrameHintsForGrounding() {
        let node = Node(
            index: 7, role: "text", label: "Replay 2023", depth: 1,
            position: Point(x: 120, y: 340), size: Size(w: 84, h: 18))
        let text = serialize([node], enablePruning: false)
        XCTAssertTrue(text.contains("Frame: (120,340 84x18)"))
    }

    // MARK: - Codex description / value separation

    func testSerializeCodexStyleSeparatesDescriptionAndValue() {
        let node = Node(
            index: 7, role: "row", label: nil, states: ["selectable"],
            description: "Grid view", value: "New", depth: 1)
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(
            text.contains("7 row (selectable) Description: Grid view, Value: New"))
    }

    func testSerializeCodexStyleAddsCommaAfterLabelBeforeExtras() {
        let node = Node(
            index: 0, role: "standard window", label: "Music",
            secondaryActions: ["AXRaise"], depth: 0)
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(
            text.hasPrefix("0 standard window Music, Secondary Actions: Raise"))
    }

    // MARK: - Menu bar item

    func testSerializeCodexStyleMenuBarItemUsesLabelOnly() {
        let node = Node(
            index: 121, role: "menu bar item", label: "Music",
            axId: "_NS:2187", secondaryActions: ["AXPick"], depth: 1)
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertEqual(text, "\t121 Music")
    }

    // MARK: - Focused summary

    func testSerializeCodexStyleFocusedSummaryIsCompact() {
        let node = Node(
            index: 0, role: "standard window", label: "Music",
            secondaryActions: ["AXRaise"], depth: 0)
        let text = serialize(
            [node], focusedIndex: 0, enablePruning: false, codexStyle: true)
        XCTAssertTrue(text.hasSuffix("The focused UI element is 0 standard window."))
    }

    // MARK: - Codex role renames

    func testSerializeCodexStyleRenamesWebAreaToHtmlContent() {
        let node = Node(
            index: 3, role: "web area", label: "workspace", depth: 0,
            webAreaUrl: "https://example.com")
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(
            text.hasPrefix("3 HTML content workspace, URL: https://example.com"))
    }

    func testSerializeCodexStyleSkipsInlineWebContentWhenChildrenExist() {
        let nodes = [
            Node(
                index: 0, role: "web area", label: "workspace", depth: 0,
                webContent: "flattened content that should stay hidden"),
            Node(index: 1, role: "button", label: "Open", depth: 1),
        ]
        let text = serialize(nodes, enablePruning: false, codexStyle: true)
        XCTAssertFalse(text.contains("flattened content that should stay hidden"))
        XCTAssertTrue(text.contains("\t1 button Open"))
    }

    func testSerializeCodexStyleUsesToggleButtonForCheckboxSubrole() {
        let node = Node(
            index: 17, role: "checkbox", label: nil,
            description: "Toggle Panel (⌘J)", depth: 0, subrole: "AXToggleButton")
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(text.hasPrefix("17 toggle button Description: Toggle Panel (⌘J)"))
    }

    func testSerializeCodexStyleUsesTabForRadioButtonTabSubrole() {
        let node = Node(
            index: 24, role: "radio button", label: "Explorer (⇧⌘E)",
            states: ["selected"], value: "1", depth: 0, subrole: "AXTabButton")
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(text.hasPrefix("24 tab (selected) Explorer (⇧⌘E), Value: 1"))
    }

    func testSerializeCodexStyleUsesPopUpButtonSpelling() {
        let node = Node(
            index: 13, role: "popup button", label: nil,
            description: "More Actions", depth: 0)
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertTrue(text.hasPrefix("13 pop-up button Description: More Actions"))
    }

    func testSerializeCodexStylePromotesRowDescriptionToLabelWhenValueMissing() {
        let node = Node(
            index: 63, role: "row", label: nil, description: ".claude", depth: 0)
        let text = serialize([node], enablePruning: false, codexStyle: true)
        XCTAssertEqual(text, "63 row .claude")
    }

    // MARK: - Golden full-tree output

    func testGoldenIndentedTree() {
        let nodes = [
            Node(index: 0, role: "standard window", label: "Music", depth: 0),
            Node(index: 1, role: "button", label: "Play",
                 secondaryActions: ["AXPress"], depth: 1),
            Node(index: 2, role: "text", label: "Now Playing", depth: 1),
        ]
        let text = serialize(nodes, enablePruning: false)
        let expected = """
        [0] standard window Music
          [1] button Play, Actions: [Press]
          [2] text Now Playing
        """
        XCTAssertEqual(text, expected)
    }

    func testGoldenCodexTreeWithFocus() {
        let nodes = [
            Node(index: 0, role: "standard window", label: "Music", depth: 0),
            Node(index: 1, role: "menu bar item", label: "File", depth: 1),
        ]
        let text = serialize(
            nodes, focusedIndex: 0, enablePruning: false, codexStyle: true)
        let expected = """
        0 standard window Music
        \t1 File

        The focused UI element is 0 standard window.
        """
        XCTAssertEqual(text, expected)
    }

    // MARK: - lmRole fallback (non-codex)

    func testNonCodexPrefersLmRole() {
        let node = Node(index: 5, role: "AXButton", label: "OK", depth: 0)
        node.lmRole = "button"
        let text = serialize([node], enablePruning: false)
        XCTAssertTrue(text.hasPrefix("[5] button OK"))
    }

    // MARK: - Value suppression rules

    func testValueSuppressedForValuelessRole() {
        let node = Node(
            index: 0, role: "group", label: "Container", value: "ignored", depth: 0)
        let text = serialize([node], enablePruning: false)
        XCTAssertFalse(text.contains("Value:"))
    }

    func testValueSuppressedWhenEqualToLabel() {
        let node = Node(
            index: 0, role: "button", label: "Save", value: "Save", depth: 0)
        let text = serialize([node], enablePruning: false)
        XCTAssertFalse(text.contains("Value:"))
    }

    // MARK: - Extras ordering and label comma

    func testExtrasOrderingWithLabel() {
        let node = Node(
            index: 0, role: "slider", label: "Volume", value: "50",
            depth: 0, placeholder: "0-100", helpText: "Adjust volume")
        let text = serialize([node], enablePruning: false)
        XCTAssertEqual(
            text, "[0] slider Volume, Value: 50, Placeholder: 0-100, Help: Adjust volume")
    }

    func testExtrasOrderingWithoutLabelUsesSpace() {
        let node = Node(index: 0, role: "slider", label: nil, value: "50", depth: 0)
        let text = serialize([node], enablePruning: false)
        XCTAssertEqual(text, "[0] slider Value: 50")
    }

    // MARK: - AX-ref scrubbing (Invariant 8)

    func testScrubsLeakedAXUIElementPointerInLabel() {
        let node = Node(
            index: 0, role: "button",
            label: "Save (<AXUIElement 0x600003abc123 {pid=29221}>)", depth: 0)
        let text = serialize([node], enablePruning: false)
        XCTAssertFalse(text.contains("AXUIElement"))
        XCTAssertFalse(text.contains("0x600003abc123"))
        XCTAssertEqual(text, "[0] button Save")
    }

    func testScrubsLeakedAXUIElementPointerInValue() {
        let node = Node(
            index: 2, role: "text field", label: "Field",
            value: "<AXUIElement 0x7fabc {pid=42}>", depth: 0)
        let text = serialize([node], enablePruning: false)
        XCTAssertFalse(text.contains("AXUIElement"))
    }

    // MARK: - Pruning seam: collapse + depth summaries

    func testSubtreeCollapseSummaryRendered() {
        let nodes = [Node(index: 0, role: "outline", label: "List", depth: 0)]
        let prune: PruneFunction = { ns, _, _ in
            PruneResult(nodes: ns, collapseInfo: [0: 12], depthCollapsedParents: [])
        }
        let text = serialize(nodes, enablePruning: true, prune: prune)
        XCTAssertTrue(text.contains("  ... (7 more items hidden)"))
    }

    func testDepthCollapseSummaryRendered() {
        let nodes = [Node(index: 0, role: "group", label: "Deep", depth: 0)]
        let prune: PruneFunction = { ns, _, _ in
            PruneResult(nodes: ns, collapseInfo: [:], depthCollapsedParents: [0])
        }
        let text = serialize(nodes, enablePruning: true, prune: prune)
        XCTAssertTrue(text.contains("  <summary>(collapsed content is hidden)</summary>"))
    }

    func testPruningSkippedWhenNoPruneFunction() {
        // enablePruning true but no prune function -> nodes pass through unpruned.
        let nodes = [Node(index: 0, role: "button", label: "OK", depth: 0)]
        let text = serialize(nodes, enablePruning: true, prune: nil)
        XCTAssertEqual(text, "[0] button OK")
    }

    // MARK: - Web content inlining (non-codex always inlines)

    func testNonCodexInlinesWebContent() {
        let nodes = [
            Node(index: 0, role: "web area", label: "page", depth: 0,
                 webContent: "line one\nline two"),
        ]
        let text = serialize(nodes, enablePruning: false)
        let expected = """
        [0] web area page
          line one
          line two
        """
        XCTAssertEqual(text, expected)
    }

    // MARK: - make_header

    func testMakeHeaderBasic() {
        let header = makeHeader(
            app: "com.apple.Music", pid: 123, windowTitle: "My Music")
        XCTAssertTrue(header.hasPrefix("App=com.apple.Music (pid 123)"))
        XCTAssertTrue(header.contains("Window: \"My Music\", App: Music."))
    }

    func testMakeHeaderCodexStopsAfterWindow() {
        let header = makeHeader(
            app: "com.apple.Music", pid: 1, windowTitle: "W",
            windowId: 99, codexStyle: true)
        XCTAssertFalse(header.contains("window_id"))
    }

    func testMakeHeaderWithAppState() {
        let state = AppState(
            bundleId: "com.apple.Music", isActive: true, isRunning: true,
            windowTitle: "W", visibleRect: Rect(x: 0, y: 0, w: 100, h: 200),
            scalingFactor: 2.0, scaledScreenSize: Size(w: 1440, h: 900),
            cursorPosition: Point(x: 10, y: 20))
        let header = makeHeader(
            app: "com.apple.Music", pid: 1, windowTitle: nil, appState: state)
        XCTAssertTrue(header.contains("isRunning: true, isActive: true"))
        XCTAssertTrue(header.contains("visibleRect: (0.0, 0.0, 100.0x200.0)"))
        XCTAssertTrue(header.contains("scalingFactor: 2.0"))
        XCTAssertTrue(header.contains("scaledScreenSize: (1440.0x900.0)"))
        XCTAssertTrue(header.contains("cursorPositionInScaledCoordinates: (10.0, 20.0)"))
    }
}
