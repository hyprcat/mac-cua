import XCTest
@testable import MacCUACore

// Port of tests/test_pruning.py — the golden spec for the pruning pipeline.
// Each Swift test mirrors the corresponding Python unittest case (same input
// tree, same asserted pruned output).

// MARK: - test helper mirroring tests/test_pruning.py:_node

private func makeNode(
    _ index: Int,
    role: String = "AXButton",
    label: String? = "Ok",
    depth: Int = 1,
    actions: [String]? = nil,
    states: [String]? = nil,
    value: String? = nil,
    url: String? = nil,
    webAreaUrl: String? = nil,
    description: String? = nil
) -> Node {
    // role.removeprefix("AX").lower()
    let displayRole = role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
    return Node(
        index: index,
        role: displayRole,
        label: label,
        states: states ?? [],
        description: description,
        value: value,
        axId: nil,
        secondaryActions: actions ?? [],
        depth: depth,
        axRef: nil,
        axRole: role,
        webAreaUrl: webAreaUrl,
        url: url
    )
}

// MARK: - strip_actions

final class PruningTests_StripActionsTests: XCTestCase {
    func testKeepsUsefulActions() {
        let nodes = [makeNode(0, actions: ["AXPress", "AXShowMenu", "AXRaise", "AXShowDefaultUI"])]
        stripActions(nodes)
        XCTAssertEqual(nodes[0].secondaryActions, ["AXPress", "AXShowMenu"])
    }

    func testEmptyActionsUnchanged() {
        let nodes = [makeNode(0, actions: [])]
        stripActions(nodes)
        XCTAssertEqual(nodes[0].secondaryActions, [])
    }

    func testAllUsefulKept() {
        let nodes = [makeNode(0, actions: ["AXPress", "AXPick", "AXIncrement"])]
        stripActions(nodes)
        XCTAssertEqual(nodes[0].secondaryActions, ["AXPress", "AXPick", "AXIncrement"])
    }
}

// MARK: - merge_labels_with_controls

final class PruningTests_MergeLabelsWithControlsTests: XCTestCase {
    func testMergesTextIntoAdjacentField() {
        let nodes = [
            makeNode(0, role: "AXStaticText", label: "Name:", depth: 1),
            makeNode(1, role: "AXTextField", label: nil, depth: 1),
        ]
        let removed = mergeLabelsWithControls(nodes)
        XCTAssertEqual(removed, [0])
        XCTAssertEqual(nodes[1].label, "Name:")
    }

    func testSkipsWhenFieldAlreadyLabeled() {
        let nodes = [
            makeNode(0, role: "AXStaticText", label: "Name:", depth: 1),
            makeNode(1, role: "AXTextField", label: "Existing", depth: 1),
        ]
        XCTAssertEqual(mergeLabelsWithControls(nodes), [])
    }

    func testSkipsDifferentDepth() {
        let nodes = [
            makeNode(0, role: "AXStaticText", label: "Name:", depth: 1),
            makeNode(1, role: "AXTextField", label: nil, depth: 2),
        ]
        XCTAssertEqual(mergeLabelsWithControls(nodes), [])
    }

    func testSkipsNonInteractiveTarget() {
        let nodes = [
            makeNode(0, role: "AXStaticText", label: "Title", depth: 1),
            makeNode(1, role: "AXGroup", label: nil, depth: 1),
        ]
        XCTAssertEqual(mergeLabelsWithControls(nodes), [])
    }
}

// MARK: - collapse_into_interactive_parent

final class PruningTests_CollapseIntoInteractiveParentTests: XCTestCase {
    func testButtonWithTextChild() {
        let nodes = [
            makeNode(0, role: "AXButton", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Save", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseIntoInteractiveParent(nodes, childrenMap)
        XCTAssertEqual(removed, [1])
        XCTAssertEqual(nodes[0].label, "Save")
    }

    func testSkipsInteractiveChildren() {
        let nodes = [
            makeNode(0, role: "AXButton", label: nil, depth: 0),
            makeNode(1, role: "AXButton", label: "Inner", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(collapseIntoInteractiveParent(nodes, childrenMap), [])
    }

    func testPreservesExistingParentLabel() {
        let nodes = [
            makeNode(0, role: "AXButton", label: "Already", depth: 0),
            makeNode(1, role: "AXStaticText", label: "Save", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseIntoInteractiveParent(nodes, childrenMap)
        XCTAssertEqual(removed, [1])
        XCTAssertEqual(nodes[0].label, "Already")
    }

    func testMultiTextChildrenJoined() {
        let nodes = [
            makeNode(0, role: "AXCell", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Hello", depth: 1),
            makeNode(2, role: "AXImage", label: nil, depth: 1),
            makeNode(3, role: "AXStaticText", label: "World", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseIntoInteractiveParent(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2, 3])
        XCTAssertEqual(nodes[0].label, "Hello World")
    }
}

// MARK: - collapse_row_children_into_row / codex helpers

final class PruningTests_CollapseRowChildrenIntoRowTests: XCTestCase {
    func testRowPromotesLeafTextAndImageToRow() {
        let nodes = [
            makeNode(0, role: "AXRow", label: nil, depth: 0),
            makeNode(1, role: "AXImage", label: nil, depth: 1, description: "Grid view"),
            makeNode(2, role: "AXStaticText", label: "New", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseRowChildrenIntoRow(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2])
        XCTAssertEqual(nodes[0].description, "Grid view")
        XCTAssertEqual(nodes[0].value, "New")
    }

    func testRowWithoutIconUsesTextAsLabel() {
        let nodes = [
            makeNode(0, role: "AXRow", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Replay 2024", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseRowChildrenIntoRow(nodes, childrenMap)
        XCTAssertEqual(removed, [1])
        XCTAssertEqual(nodes[0].label, "Replay 2024")
    }

    func testNonRowCellsKeepNestedText() {
        let nodes = [
            makeNode(0, role: "AXCell", label: nil, depth: 0, description: "Drake"),
            makeNode(1, role: "AXStaticText", label: "Drake Artist", depth: 1),
        ]
        let pruned = pruneForCodexTree(nodes)
        XCTAssertEqual(pruned.map { $0.axRole }, ["AXCell", "AXStaticText"])
        XCTAssertEqual(pruned[0].description, "Drake")
        XCTAssertEqual(pruned[1].label, "Drake Artist")
    }

    func testCodexPruningKeepsScrollbarsSplittersAndActions() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: "Music", depth: 0, actions: ["AXRaise"]),
            makeNode(1, role: "AXSplitGroup", label: nil, depth: 1),
            makeNode(2, role: "AXScrollArea", label: nil, depth: 2, actions: ["AXScrollUpByPage", "AXScrollDownByPage"]),
            makeNode(3, role: "AXScrollBar", label: nil, depth: 3, value: "0"),
            makeNode(4, role: "AXValueIndicator", label: nil, depth: 4, value: "0"),
            makeNode(5, role: "AXSplitter", label: nil, depth: 2, value: "208"),
            makeNode(6, role: "AXButton", label: "Go Back", depth: 2, actions: ["AXMoveNext", "AXRemoveFromToolbar"]),
            makeNode(7, role: "AXUnknown", label: "Browse Categories", depth: 2),
        ]
        let pruned = pruneForCodexTree(nodes)
        let axRoles = pruned.map { $0.axRole }
        XCTAssertTrue(axRoles.contains("AXSplitGroup"))
        XCTAssertTrue(axRoles.contains("AXScrollBar"))
        XCTAssertTrue(axRoles.contains("AXSplitter"))
        XCTAssertTrue(axRoles.contains("AXUnknown"))
        let button = pruned.first { $0.axRole == "AXButton" }!
        XCTAssertEqual(button.secondaryActions, ["AXMoveNext", "AXRemoveFromToolbar"])
    }

    func testOutlineRowsFlattenToDirectRowLabels() {
        let nodes = [
            makeNode(0, role: "AXOutline", label: nil, depth: 0, description: "Sidebar"),
            makeNode(1, role: "AXRow", label: nil, depth: 1),
            makeNode(2, role: "AXCell", label: nil, depth: 2),
            makeNode(3, role: "AXImage", label: nil, depth: 3, description: "playlist"),
            makeNode(4, role: "AXStaticText", label: "Replay 2024", depth: 3),
        ]
        nodes[1].subrole = "AXOutlineRow"
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = flattenOutlineRows(nodes, childrenMap)
        XCTAssertEqual(removed, [2, 3, 4])
        XCTAssertEqual(nodes[1].description, "playlist")
        XCTAssertEqual(nodes[1].value, "Replay 2024")
    }

    func testOutlineRowIdenticalIconAndTextUsesLabel() {
        let nodes = [
            makeNode(0, role: "AXRow", label: nil, depth: 0),
            makeNode(1, role: "AXCell", label: nil, depth: 1),
            makeNode(2, role: "AXImage", label: nil, depth: 2, description: "Search"),
            makeNode(3, role: "AXStaticText", label: "Search", depth: 2),
        ]
        nodes[0].subrole = "AXOutlineRow"
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = flattenOutlineRows(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2, 3])
        XCTAssertEqual(nodes[0].label, "Search")
        XCTAssertNil(nodes[0].description)
        XCTAssertNil(nodes[0].value)
    }

    func testOutlineRowPreservesExistingLabelAsDescriptionAndMergesDisclosure() {
        let nodes = [
            makeNode(0, role: "AXRow", label: "Edit", depth: 0, states: ["selectable"]),
            makeNode(1, role: "AXCell", label: nil, depth: 1),
            makeNode(2, role: "AXDisclosureTriangle", label: nil, depth: 2, actions: ["AXCollapse"], states: ["expanded"]),
            makeNode(3, role: "AXStaticText", label: "Playlists", depth: 2),
        ]
        nodes[0].subrole = "AXOutlineRow"
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = flattenOutlineRows(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2, 3])
        XCTAssertEqual(nodes[0].description, "Edit")
        XCTAssertEqual(nodes[0].value, "Playlists")
        XCTAssertTrue(nodes[0].states.contains("expanded"))
        XCTAssertTrue(nodes[0].secondaryActions.contains("AXCollapse"))
    }

    func testOutlineRowPromotesButtonTextToLabel() {
        let nodes = [
            makeNode(0, role: "AXRow", label: nil, depth: 0, states: ["selectable"]),
            makeNode(1, role: "AXCell", label: nil, depth: 1),
            makeNode(2, role: "AXStaticText", label: "Library", depth: 2),
            makeNode(3, role: "AXButton", label: "Edit", depth: 2),
        ]
        nodes[0].subrole = "AXOutlineRow"
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = flattenOutlineRows(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2, 3])
        XCTAssertEqual(nodes[0].label, "Edit")
        XCTAssertEqual(nodes[0].value, "Library")
    }

    func testOutlineRowUsesStaticTextDescriptionWhenPresent() {
        let nodes = [
            makeNode(0, role: "AXRow", label: nil, depth: 0, states: ["selectable"]),
            makeNode(1, role: "AXCell", label: nil, depth: 1),
            makeNode(2, role: "AXStaticText", label: "1", depth: 2, description: "Software Update Available, 1 new item"),
        ]
        nodes[0].subrole = "AXOutlineRow"
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = flattenOutlineRows(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2])
        XCTAssertEqual(nodes[0].label, "1")
        XCTAssertEqual(nodes[0].description, "Software Update Available, 1 new item")
    }

    func testDropEmptyOutlineRowsRemovesIconOnlyWrappers() {
        let nodes = [
            makeNode(0, role: "AXRow", label: nil, depth: 0, states: ["selectable"]),
            makeNode(1, role: "AXCell", label: nil, depth: 1),
            makeNode(2, role: "AXGroup", label: nil, depth: 2),
            makeNode(3, role: "AXRow", label: "General", depth: 0, states: ["selectable"]),
        ]
        nodes[0].subrole = "AXOutlineRow"
        nodes[3].subrole = "AXOutlineRow"
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = dropEmptyOutlineRows(nodes, childrenMap)
        XCTAssertEqual(removed, [0, 1, 2])
    }
}

final class PruningTests_CollapseButtonTitleChildrenTests: XCTestCase {
    func testCollapsesOuterButtonWithTitleButtonChild() {
        let nodes = [
            makeNode(0, role: "AXButton", label: nil, depth: 0, states: ["disabled"], description: "Apple"),
            makeNode(1, role: "AXImage", label: nil, depth: 1),
            makeNode(2, role: "AXButton", label: nil, depth: 1, value: "Apple", description: "Apple"),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseButtonTitleChildren(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2])
        XCTAssertEqual(nodes[0].label, "Apple")
    }

    func testCodexPruningKeepsDisabledSections() {
        let nodes = [
            makeNode(0, role: "AXCollection", label: nil, depth: 0),
            makeNode(1, role: "AXGroup", label: "Top Picks for You", depth: 1, states: ["disabled"]),
            makeNode(2, role: "AXStaticText", label: "R&B Now", depth: 2),
        ]
        let pruned = pruneForCodexTree(nodes)
        XCTAssertEqual(pruned.map { $0.axRole }, ["AXCollection", "AXGroup", "AXStaticText"])
    }

    func testCodexPruningKeepsDescriptiveGroupsButSkipsEmptyHostingViews() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0, description: nil),
            makeNode(1, role: "AXGroup", label: nil, depth: 1, description: "Mini Player"),
            makeNode(2, role: "AXButton", label: "Play", depth: 2),
        ]
        nodes[0].subrole = "AXHostingView"
        let pruned = pruneForCodexTree(nodes)
        XCTAssertEqual(pruned.map { $0.axRole }, ["AXGroup", "AXButton"])
        XCTAssertEqual(pruned[0].description, "Mini Player")
    }

    func testCodexPruningSkipsEmptySingleChildGroupEvenWithId() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0, description: "Mini Player"),
            makeNode(1, role: "AXGroup", label: nil, depth: 1, description: nil),
            makeNode(2, role: "AXButton", label: "Show Now Playing", depth: 2),
        ]
        nodes[1].axId = "Music.miniPlayer.metadataRegion[state=empty]"
        let pruned = pruneForCodexTree(nodes)
        XCTAssertEqual(pruned.map { $0.axRole }, ["AXGroup", "AXButton"])
        XCTAssertEqual(pruned[1].label, "Show Now Playing")
    }
}

// MARK: - unwrap_single_child_groups

final class PruningTests_UnwrapSingleChildGroupsTests: XCTestCase {
    func testSingleChildGroupMerged() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXButton", label: "Click", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = unwrapSingleChildGroups(nodes, childrenMap)
        XCTAssertEqual(removed, [0])
        XCTAssertEqual(nodes[1].depth, 0)
    }

    func testTransfersLabel() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: "Section", depth: 0),
            makeNode(1, role: "AXButton", label: nil, depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = unwrapSingleChildGroups(nodes, childrenMap)
        XCTAssertEqual(removed, [0])
        XCTAssertEqual(nodes[1].label, "Section")
    }

    func testMultiChildGroupKept() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXButton", label: "A", depth: 1),
            makeNode(2, role: "AXButton", label: "B", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(unwrapSingleChildGroups(nodes, childrenMap), [])
    }

    func testNonContainerRoleKept() {
        let nodes = [
            makeNode(0, role: "AXButton", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Text", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(unwrapSingleChildGroups(nodes, childrenMap), [])
    }

    func testNestedGroupDepthAdjusted() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXButton", label: "Click", depth: 1),
            makeNode(2, role: "AXStaticText", label: "text", depth: 2),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = unwrapSingleChildGroups(nodes, childrenMap)
        XCTAssertEqual(removed, [0])
        XCTAssertEqual(nodes[1].depth, 0)
        XCTAssertEqual(nodes[2].depth, 1)
    }
}

// MARK: - collapse_redundant_wrappers

final class PruningTests_CollapseRedundantWrappersTests: XCTestCase {
    func testSameRoleUnlabeledParentRemoved() {
        let nodes = [
            makeNode(0, role: "AXList", label: nil, depth: 0),
            makeNode(1, role: "AXList", label: "Items", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = collapseRedundantWrappers(nodes, childrenMap)
        XCTAssertEqual(removed, [0])
        XCTAssertEqual(nodes[1].depth, 0)
    }

    func testDifferentRolesKept() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXList", label: "Items", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(collapseRedundantWrappers(nodes, childrenMap), [])
    }

    func testLabeledParentKept() {
        let nodes = [
            makeNode(0, role: "AXList", label: "Outer", depth: 0),
            makeNode(1, role: "AXList", label: "Inner", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(collapseRedundantWrappers(nodes, childrenMap), [])
    }

    func testParentWithActionsKept() {
        let nodes = [
            makeNode(0, role: "AXList", label: nil, depth: 0, actions: ["AXPress"]),
            makeNode(1, role: "AXList", label: "Items", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(collapseRedundantWrappers(nodes, childrenMap), [])
    }
}

// MARK: - merge_adjacent_text

final class PruningTests_MergeAdjacentTextTests: XCTestCase {
    func testAdjacentTextMerged() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Hello", depth: 1),
            makeNode(2, role: "AXStaticText", label: "World", depth: 1),
            makeNode(3, role: "AXStaticText", label: "!", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = mergeAdjacentText(nodes, childrenMap)
        XCTAssertEqual(removed, [2, 3])
        XCTAssertEqual(nodes[1].label, "Hello World !")
    }

    func testNonTextBreaksRun() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "A", depth: 1),
            makeNode(2, role: "AXButton", label: "B", depth: 1),
            makeNode(3, role: "AXStaticText", label: "C", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(mergeAdjacentText(nodes, childrenMap), [])
    }

    func testSingleTextUnchanged() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Only", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(mergeAdjacentText(nodes, childrenMap), [])
    }
}

// MARK: - inline_links_as_markdown

final class PruningTests_InlineLinksAsMarkdownTests: XCTestCase {
    func testLinkWithTextChild() {
        let nodes = [
            makeNode(0, role: "AXLink", label: nil, depth: 0, url: "https://example.com"),
            makeNode(1, role: "AXStaticText", label: "Click here", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = inlineLinksAsMarkdown(nodes, childrenMap)
        XCTAssertEqual(removed, [1])
        XCTAssertEqual(nodes[0].label, "[Click here](https://example.com)")
    }

    func testLinkWithNoURLUsesTextOnly() {
        let nodes = [
            makeNode(0, role: "AXLink", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Click here", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = inlineLinksAsMarkdown(nodes, childrenMap)
        XCTAssertEqual(removed, [1])
        XCTAssertEqual(nodes[0].label, "Click here")
    }

    func testLinkWithInteractiveChildNotFlattened() {
        let nodes = [
            makeNode(0, role: "AXLink", label: nil, depth: 0, url: "https://example.com"),
            makeNode(1, role: "AXButton", label: "Button", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(inlineLinksAsMarkdown(nodes, childrenMap), [])
    }

    func testLinkWithImageChildSkipped() {
        let nodes = [
            makeNode(0, role: "AXLink", label: nil, depth: 0, url: "https://example.com"),
            makeNode(1, role: "AXImage", label: nil, depth: 1),
            makeNode(2, role: "AXStaticText", label: "Text", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = inlineLinksAsMarkdown(nodes, childrenMap)
        XCTAssertEqual(removed, [1, 2])
        XCTAssertEqual(nodes[0].label, "[Text](https://example.com)")
    }

    func testLinkFallbackToDescription() {
        let nodes = [
            makeNode(0, role: "AXLink", label: nil, depth: 0, description: "https://fallback.com"),
            makeNode(1, role: "AXStaticText", label: "Link", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = inlineLinksAsMarkdown(nodes, childrenMap)
        XCTAssertEqual(removed, [1])
        XCTAssertEqual(nodes[0].label, "[Link](https://fallback.com)")
    }
}

// MARK: - combine_text_siblings

final class PruningTests_CombineTextSiblingsTests: XCTestCase {
    func testAdjacentTextMerged() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "A", depth: 1),
            makeNode(2, role: "AXStaticText", label: "B", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = combineTextSiblings(nodes, childrenMap)
        XCTAssertEqual(removed, [2])
        XCTAssertEqual(nodes[1].label, "A B")
    }

    func testHeadingUsesNewlineSeparator() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "Text", depth: 1),
            makeNode(2, role: "AXHeading", label: "Title", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = combineTextSiblings(nodes, childrenMap)
        XCTAssertEqual(removed, [2])
        XCTAssertEqual(nodes[1].label, "Text\nTitle")
    }

    func testTextWithActionsNotMerged() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: nil, depth: 0),
            makeNode(1, role: "AXStaticText", label: "A", depth: 1, actions: ["AXPress"]),
            makeNode(2, role: "AXStaticText", label: "B", depth: 1),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        XCTAssertEqual(combineTextSiblings(nodes, childrenMap), [])
    }
}

// MARK: - prune_calendar_event_details

final class PruningTests_RemoveCalendarEventsTests: XCTestCase {
    func testSkipsNonCalendarApp() {
        let nodes = [
            makeNode(0, role: "AXGroup", label: "Meeting", depth: 3),
            makeNode(1, role: "AXStaticText", label: "Details", depth: 4),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = pruneCalendarEventDetails(nodes, childrenMap, "com.apple.Safari")
        XCTAssertEqual(removed, [])
    }

    func testRemovesChildrenInCalendar() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: nil, depth: 0),
            makeNode(1, role: "AXScrollArea", label: nil, depth: 1),
            makeNode(2, role: "AXGroup", label: nil, depth: 2),
            makeNode(3, role: "AXGroup", label: "Meeting at 3pm", depth: 3),
            makeNode(4, role: "AXStaticText", label: "Location", depth: 4),
            makeNode(5, role: "AXStaticText", label: "Attendees", depth: 4),
            makeNode(6, role: "AXStaticText", label: "Notes", depth: 4),
        ]
        let (childrenMap, _) = buildTreeIndex(nodes)
        let removed = pruneCalendarEventDetails(nodes, childrenMap, "com.apple.iCal")
        XCTAssertTrue(removed.contains(4))
        XCTAssertTrue(removed.contains(5))
        XCTAssertTrue(removed.contains(6))
        XCTAssertFalse(removed.contains(3))
    }
}

// MARK: - URL shortener

final class PruningTests_URLShortenerTests: XCTestCase {
    func testStripsQueryAndFragment() {
        let nodes = [makeNode(0, webAreaUrl: "https://example.com/page?q=1&r=2#section")]
        shortenURLs(nodes)
        XCTAssertEqual(nodes[0].webAreaUrl, "https://example.com/page")
    }

    func testEnforcesIndividualLimit() {
        let longPath = String(repeating: "/a", count: 100)
        let nodes = [makeNode(0, webAreaUrl: "https://example.com\(longPath)")]
        let config = URLShortenerConfig(individualLimit: 40)
        shortenURLs(nodes, config)
        XCTAssertLessThanOrEqual(nodes[0].webAreaUrl!.count, 40)
        XCTAssertTrue(nodes[0].webAreaUrl!.hasSuffix("..."))
    }

    func testShortensURLInLabel() {
        let nodes = [makeNode(0, label: "[Click](https://example.com/path?tracking=abc&utm_source=test)")]
        shortenURLs(nodes)
        XCTAssertFalse(nodes[0].label!.contains("tracking=abc"))
        XCTAssertTrue(nodes[0].label!.contains("https://example.com/path"))
    }

    func testIncludeQueryWhenConfigured() {
        let nodes = [makeNode(0, webAreaUrl: "https://example.com/page?q=search")]
        let config = URLShortenerConfig(includeQuery: true)
        shortenURLs(nodes, config)
        XCTAssertTrue(nodes[0].webAreaUrl!.contains("q=search"))
    }

    func testTotalLimitStopsShortening() {
        let nodes = [
            makeNode(0, webAreaUrl: "https://example.com/first"),
            makeNode(1, webAreaUrl: "https://example.com/second"),
        ]
        let config = URLShortenerConfig(totalLimit: 30)
        shortenURLs(nodes, config)
        XCTAssertNotNil(nodes[0].webAreaUrl)
    }

    func testShortensNodeURLField() {
        let nodes = [makeNode(0, url: "https://example.com/link?track=1#ref")]
        shortenURLs(nodes)
        XCTAssertEqual(nodes[0].url, "https://example.com/link")
    }
}

// MARK: - _build_tree_index_excluding

final class PruningTests_BuildTreeIndexExcludingTests: XCTestCase {
    func testExcludedNodesSkipped() {
        let nodes = [
            makeNode(0, depth: 0),
            makeNode(1, depth: 1),
            makeNode(2, depth: 1),
        ]
        let (children, _) = buildTreeIndexExcluding(nodes, [1])
        XCTAssertNil(children[1])
        XCTAssertEqual(children[0], [2])
    }

    func testReparentsChildren() {
        let nodes = [
            makeNode(0, depth: 0),
            makeNode(1, depth: 1),
            makeNode(2, depth: 2),
        ]
        let (children, _) = buildTreeIndexExcluding(nodes, [1])
        XCTAssertNil(children[1])
    }

    func testReparentsThroughExcludedSiblingWrapperChain() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: "Music", depth: 0),
            makeNode(1, role: "AXScrollBar", label: nil, depth: 1),
            makeNode(2, role: "AXValueIndicator", label: nil, depth: 2),
            makeNode(3, role: "AXGroup", label: nil, depth: 1),
            makeNode(4, role: "AXGroup", label: "Mini Player", depth: 2),
        ]
        let (children, parent) = buildTreeIndexExcluding(nodes, [3])
        XCTAssertEqual(parent[4] ?? nil, 0)
        XCTAssertEqual(children[0], [1, 4])
    }
}

// MARK: - Full pipeline

final class PruningTests_FullPipelineTests: XCTestCase {
    func testPipelineRunsWithoutErrors() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: "Test", depth: 0),
            makeNode(1, role: "AXGroup", label: nil, depth: 1),
            makeNode(2, role: "AXButton", label: "OK", depth: 2, actions: ["AXPress"]),
            makeNode(3, role: "AXStaticText", label: "Hello", depth: 2),
            makeNode(4, role: "AXStaticText", label: "World", depth: 2),
        ]
        let result = prune(nodes)
        XCTAssertTrue(result.nodes.count > 0)
        for (i, node) in result.nodes.enumerated() {
            XCTAssertEqual(node.index, i)
        }
    }

    func testAdvancedFalseSkipsNewPasses() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: "Test", depth: 0),
            makeNode(1, role: "AXButton", label: nil, depth: 1, actions: ["AXRaise", "AXPress"]),
        ]
        let result = prune(nodes, advanced: false)
        let btn = result.nodes.first { $0.axRole == "AXButton" }!
        XCTAssertTrue(btn.secondaryActions.contains("AXRaise"))
    }

    func testAdvancedTrueFiltersActions() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: "Test", depth: 0),
            makeNode(1, role: "AXButton", label: "OK", depth: 1, actions: ["AXRaise", "AXPress"]),
        ]
        let result = prune(nodes, advanced: true)
        let btn = result.nodes.first { $0.axRole == "AXButton" }!
        XCTAssertFalse(btn.secondaryActions.contains("AXRaise"))
        XCTAssertTrue(btn.secondaryActions.contains("AXPress"))
    }

    func testWebPageTreeReduction() {
        let nodes = [
            makeNode(0, role: "AXWebArea", label: "Page", depth: 0),
            makeNode(1, role: "AXGroup", label: nil, depth: 1),
            makeNode(2, role: "AXStaticText", label: "Lorem", depth: 2),
            makeNode(3, role: "AXStaticText", label: "ipsum", depth: 2),
            makeNode(4, role: "AXStaticText", label: "dolor", depth: 2),
            makeNode(5, role: "AXLink", label: nil, depth: 1, url: "https://example.com"),
            makeNode(6, role: "AXStaticText", label: "Click here", depth: 2),
        ]
        let result = prune(nodes)
        XCTAssertTrue(result.nodes.count < nodes.count)
    }

    func testEmptyInput() {
        let result = prune([])
        XCTAssertEqual(result.nodes.count, 0)
        XCTAssertEqual(result.collapseInfo, [:])
        XCTAssertEqual(result.depthCollapsedParents, [])
    }

    func testIndicesSequential() {
        let nodes = [
            makeNode(0, role: "AXWindow", label: "W", depth: 0),
            makeNode(1, role: "AXGroup", label: nil, depth: 1),
            makeNode(2, role: "AXButton", label: "A", depth: 2),
            makeNode(3, role: "AXGroup", label: nil, depth: 1),
            makeNode(4, role: "AXButton", label: "B", depth: 2),
        ]
        let result = prune(nodes)
        for (i, node) in result.nodes.enumerated() {
            XCTAssertEqual(node.index, i, "Node at position \(i) has index \(node.index)")
        }
    }
}

// MARK: - cap_web_area_nodes

final class PruningTests_CapWebAreaNodesTests: XCTestCase {
    func testSmallWebAreaUntouched() {
        var nodes = [makeNode(0, role: "AXWebArea", label: "Page", depth: 0)]
        for i in 1..<50 {
            nodes.append(makeNode(i, role: "AXStaticText", label: "text\(i)", depth: 1))
        }
        nodes[0].isWebArea = true
        let skips = capWebAreaNodes(nodes, [], cap: 300)
        XCTAssertEqual(skips.count, 0)
    }

    func testLargeWebAreaTruncated() {
        var nodes = [makeNode(0, role: "AXWebArea", label: "Page", depth: 0)]
        for i in 1..<21 {
            nodes.append(makeNode(i, role: "AXStaticText", label: "msg\(i)", depth: 1))
        }
        nodes[0].isWebArea = true
        let skips = capWebAreaNodes(nodes, [], cap: 10)
        XCTAssertEqual(skips.count, 10)
        XCTAssertEqual(skips, Set(1...10))
        XCTAssertTrue(nodes[0].label!.contains("10 earlier elements truncated"))
    }

    func testAlreadySkippedNodesExcluded() {
        var nodes = [makeNode(0, role: "AXWebArea", label: "Page", depth: 0)]
        for i in 1..<16 {
            nodes.append(makeNode(i, role: "AXStaticText", label: "t\(i)", depth: 1))
        }
        nodes[0].isWebArea = true
        let existingSkips: Set<Int> = [1, 2, 3, 4, 5]
        let skips = capWebAreaNodes(nodes, existingSkips, cap: 10)
        XCTAssertEqual(skips.count, 0)
    }
}
