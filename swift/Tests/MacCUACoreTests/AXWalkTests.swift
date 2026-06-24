import XCTest
@testable import MacCUACore

// Tests for the pure walker logic in Sources/MacCUACore/AXWalk.swift.
// Reference behavior: app/_lib/accessibility.py.

// MARK: - In-memory fake element

private final class FakeEl: AXElementRef {
    var attrs: AXAttributes
    var children: [FakeEl]
    var rawActions: [String]
    var valueSettable: Bool
    var selectedSettable: Bool
    var pid: Int?
    var url: String?

    init(
        attrs: [String: AXScalar] = [:],
        children: [FakeEl] = [],
        rawActions: [String] = [],
        valueSettable: Bool = false,
        selectedSettable: Bool = false,
        pid: Int? = nil,
        url: String? = nil
    ) {
        self.attrs = AXAttributes(attrs)
        self.children = children
        self.rawActions = rawActions
        self.valueSettable = valueSettable
        self.selectedSettable = selectedSettable
        self.pid = pid
        self.url = url
    }
}

private final class FakeAXReader: AXTreeReader {
    private func el(_ e: AXElementRef) -> FakeEl { e as! FakeEl }

    func readAttributes(_ element: AXElementRef) -> AXAttributes { el(element).attrs }
    func rawActionNames(_ element: AXElementRef) -> [String] { el(element).rawActions }
    func isValueSettable(_ element: AXElementRef) -> Bool { el(element).valueSettable }
    func isSelectedSettable(_ element: AXElementRef) -> Bool { el(element).selectedSettable }
    func childrenForWalk(_ element: AXElementRef, attrs: AXAttributes, role: String) -> [AXElementRef] {
        el(element).children
    }
    func elementPid(_ element: AXElementRef) -> Int? { el(element).pid }
    func linkURL(_ element: AXElementRef) -> String? { el(element).url }
}

private func role(_ r: String) -> [String: AXScalar] { [AXAttr.role: .string(r)] }

final class AXWalkTests: XCTestCase {

    // MARK: walk: DFS preorder + reverse-push order

    func testWalkPreorder() {
        let a1 = FakeEl(attrs: role("AXButton"))
        let a2 = FakeEl(attrs: role("AXCheckBox"))
        let a = FakeEl(attrs: role("AXList"), children: [a1, a2])
        let b = FakeEl(attrs: role("AXImage"))
        let root = FakeEl(attrs: role("AXWindow"), children: [a, b])

        let nodes = AXWalk.walk(root: root, reader: FakeAXReader(), targetPid: nil)
        XCTAssertEqual(nodes.map { $0.axRole }, ["AXWindow", "AXList", "AXButton", "AXCheckBox", "AXImage"])
        XCTAssertEqual(nodes.map { $0.depth }, [0, 1, 2, 2, 1])
        XCTAssertEqual(nodes.map { $0.index }, [0, 1, 2, 3, 4])
    }

    // MARK: walk: maxNodes cap

    func testMaxNodesCap() {
        let kids = (0..<10).map { _ in FakeEl(attrs: role("AXButton")) }
        let root = FakeEl(attrs: role("AXWindow"), children: kids)
        let nodes = AXWalk.walk(root: root, reader: FakeAXReader(), targetPid: nil, maxNodes: 3)
        XCTAssertEqual(nodes.count, 3)
    }

    // MARK: walk: maxDepth cap

    func testMaxDepthCap() {
        // deep chain: d0 -> d1 -> d2 -> d3
        let d3 = FakeEl(attrs: role("AXButton"))
        let d2 = FakeEl(attrs: role("AXButton"), children: [d3])
        let d1 = FakeEl(attrs: role("AXButton"), children: [d2])
        let d0 = FakeEl(attrs: role("AXWindow"), children: [d1])
        let nodes = AXWalk.walk(root: d0, reader: FakeAXReader(), targetPid: nil, maxDepth: 1)
        XCTAssertEqual(nodes.map { $0.depth }, [0, 1])
    }

    // MARK: walk: 100-children cap

    func test100ChildrenCap() {
        let kids = (0..<150).map { _ in FakeEl(attrs: role("AXButton")) }
        let root = FakeEl(attrs: role("AXWindow"), children: kids)
        let nodes = AXWalk.walk(root: root, reader: FakeAXReader(), targetPid: nil, maxNodes: 100000)
        XCTAssertEqual(nodes.count, 101) // root + first 100 children
    }

    // MARK: walk: OOP detection

    func testOopDetection() {
        let foreign = FakeEl(attrs: role("AXButton"), pid: 999)
        let same = FakeEl(attrs: role("AXButton"), pid: 100)
        let noPid = FakeEl(attrs: role("AXButton"), pid: nil)
        let root = FakeEl(attrs: role("AXWindow"), children: [foreign, same, noPid], pid: 100)
        let nodes = AXWalk.walk(root: root, reader: FakeAXReader(), targetPid: 100)
        // root, foreign, same, noPid
        XCTAssertFalse(nodes[0].isOop)
        XCTAssertTrue(nodes[1].isOop)
        XCTAssertFalse(nodes[2].isOop)
        XCTAssertFalse(nodes[3].isOop)
    }

    // MARK: walk: isWebArea + linkURL

    func testWebAreaAndLinkUrl() {
        let link = FakeEl(attrs: role("AXLink"), url: "https://example.com")
        let nonLink = FakeEl(attrs: role("AXButton"), url: "https://ignored.com")
        let web = FakeEl(attrs: role("AXWebArea"), children: [link, nonLink])
        let root = FakeEl(attrs: role("AXWindow"), children: [web])
        let nodes = AXWalk.walk(root: root, reader: FakeAXReader(), targetPid: nil)
        let webNode = nodes.first { $0.axRole == "AXWebArea" }!
        let linkNode = nodes.first { $0.axRole == "AXLink" }!
        let nonLinkNode = nodes.first { $0.axRole == "AXButton" }!
        XCTAssertTrue(webNode.isWebArea)
        XCTAssertFalse(linkNode.isWebArea)
        XCTAssertEqual(linkNode.url, "https://example.com")
        XCTAssertNil(nonLinkNode.url) // only populated for AXLink role
    }

    // MARK: walk: includeStates / includeActions toggles

    func testIncludeTogglesFalse() {
        let el = FakeEl(
            attrs: [AXAttr.role: .string("AXButton"), AXAttr.enabled: .bool(false)],
            rawActions: ["AXShowMenu"]
        )
        let nodes = AXWalk.walk(
            root: el, reader: FakeAXReader(), targetPid: nil,
            includeActions: false, includeStates: false)
        XCTAssertTrue(nodes[0].states.isEmpty)
        XCTAssertTrue(nodes[0].secondaryActions.isEmpty)
    }

    // MARK: walk: A3 rich attribute population (US-018)

    func testRichAttributePopulation() {
        let slider = FakeEl(attrs: [
            AXAttr.role: .string("AXSlider"),
            AXAttr.value: .double(0.5),
            AXAttr.minValue: .double(0.0),
            AXAttr.maxValue: .double(1.0),
            AXAttr.positionInSet: .int(3),
        ])
        let field = FakeEl(attrs: [
            AXAttr.role: .string("AXTextField"),
            AXAttr.value: .string("hello world"),
            AXAttr.selectedText: .string("world"),
        ])
        let root = FakeEl(attrs: role("AXWindow"), children: [slider, field])
        let nodes = AXWalk.walk(root: root, reader: FakeAXReader(), targetPid: nil)

        let sliderNode = nodes.first { $0.axRole == "AXSlider" }!
        XCTAssertEqual(sliderNode.minValue, "0")
        XCTAssertEqual(sliderNode.maxValue, "1")
        XCTAssertEqual(sliderNode.positionInSet, 3)
        XCTAssertNil(sliderNode.selectedText)

        let fieldNode = nodes.first { $0.axRole == "AXTextField" }!
        XCTAssertEqual(fieldNode.selectedText, "world")
        XCTAssertNil(fieldNode.minValue)
        XCTAssertNil(fieldNode.positionInSet)
    }

    func testRichAttributesAbsentByDefault() {
        let node = AXWalk.walk(
            root: FakeEl(attrs: role("AXButton")), reader: FakeAXReader(), targetPid: nil)[0]
        XCTAssertNil(node.minValue)
        XCTAssertNil(node.maxValue)
        XCTAssertNil(node.selectedText)
        XCTAssertNil(node.positionInSet)
    }

    // MARK: intValue

    func testIntValue() {
        XCTAssertEqual(AXWalkLogic.intValue(.int(5)), 5)
        XCTAssertEqual(AXWalkLogic.intValue(.double(2.0)), 2)
        XCTAssertEqual(AXWalkLogic.intValue(.string(" 7 ")), 7)
        XCTAssertNil(AXWalkLogic.intValue(.string("abc")))
        XCTAssertNil(AXWalkLogic.intValue(.bool(true)))
        XCTAssertNil(AXWalkLogic.intValue(nil))
    }

    // MARK: cleanText

    func testCleanText() {
        XCTAssertEqual(AXWalkLogic.cleanText(.double(3.0)), "3")
        XCTAssertEqual(AXWalkLogic.cleanText(.double(3.5)), "3.5")
        XCTAssertEqual(AXWalkLogic.cleanText(.string("  hi  ")), "hi")
        XCTAssertNil(AXWalkLogic.cleanText(.string("")))
        XCTAssertNil(AXWalkLogic.cleanText(nil))
        XCTAssertEqual(AXWalkLogic.cleanText(.bool(true)), "True")
    }

    // MARK: displayRole

    func testDisplayRole() {
        // subrole override wins
        XCTAssertEqual(
            AXWalkLogic.displayRole(
                attrs: AXAttributes([AXAttr.subrole: .string("AXSearchField")]),
                role: "AXTextField"),
            "search text field")
        // role override
        XCTAssertEqual(
            AXWalkLogic.displayRole(attrs: AXAttributes(), role: "AXButton"),
            "button")
        // roleDescription fallback for unknown role
        XCTAssertEqual(
            AXWalkLogic.displayRole(
                attrs: AXAttributes([AXAttr.roleDescription: .string("custom widget")]),
                role: "AXFancyThing"),
            "custom widget")
        // roleDescription NOT used for AXWindow/AXRow/AXUnknown — but those have
        // role overrides; use AXUnknown which maps to "unknown" via override.
        XCTAssertEqual(
            AXWalkLogic.displayRole(
                attrs: AXAttributes([AXAttr.roleDescription: .string("desc")]),
                role: "AXUnknown"),
            "unknown")
        // strip-AX-lowercase fallback for unknown role with no roleDescription
        XCTAssertEqual(
            AXWalkLogic.displayRole(attrs: AXAttributes(), role: "AXFoo"),
            "foo")
    }

    // MARK: resolveLabel

    func testResolveLabel() {
        // title wins
        XCTAssertEqual(
            AXWalkLogic.resolveLabel(
                attrs: AXAttributes([
                    AXAttr.title: .string("T"), AXAttr.value: .string("V"),
                ]),
                role: "AXButton"),
            "T")
        // AXStaticText uses value (even with description present)
        XCTAssertEqual(
            AXWalkLogic.resolveLabel(
                attrs: AXAttributes([
                    AXAttr.value: .string("hello"), AXAttr.description: .string("d"),
                ]),
                role: "AXStaticText"),
            "hello")
        // AXHeading value==description returns value
        XCTAssertEqual(
            AXWalkLogic.resolveLabel(
                attrs: AXAttributes([
                    AXAttr.value: .string("H"), AXAttr.description: .string("H"),
                ]),
                role: "AXHeading"),
            "H")
        // value used when description nil
        XCTAssertEqual(
            AXWalkLogic.resolveLabel(
                attrs: AXAttributes([AXAttr.value: .string("only")]),
                role: "AXButton"),
            "only")
        // no signals -> nil
        XCTAssertNil(
            AXWalkLogic.resolveLabel(
                attrs: AXAttributes([AXAttr.description: .string("d")]),
                role: "AXButton"))
    }

    // MARK: getActions

    func testGetActions() {
        // non-actionable role
        XCTAssertEqual(AXWalkLogic.getActions(role: "AXStaticText", rawActionNames: ["AXPress"]), [])
        // suppresses AXPress/AXConfirm etc.; keeps AXShowMenu only when no primary activation
        XCTAssertEqual(
            AXWalkLogic.getActions(role: "AXButton", rawActionNames: ["AXShowMenu", "AXScrollToVisible"]),
            ["AXShowMenu", "AXScrollToVisible"])
        // with primary activation, AXShowMenu is dropped and AXPress suppressed
        XCTAssertEqual(
            AXWalkLogic.getActions(role: "AXButton", rawActionNames: ["AXPress", "AXShowMenu", "AXScrollToVisible"]),
            ["AXScrollToVisible"])
        // AXShowMenu suppressed when primary activation present
        XCTAssertEqual(
            AXWalkLogic.getActions(role: "AXButton", rawActionNames: ["AXPress", "AXShowMenu"]),
            [])
        // scroll-container role keeps only scroll page actions
        XCTAssertEqual(
            AXWalkLogic.getActions(
                role: "AXScrollArea",
                rawActionNames: ["AXScrollUpByPage", "AXScrollDownByPage", "AXScrollToVisible"]),
            ["AXScrollUpByPage", "AXScrollDownByPage"])
        // normalizeActionName: "Move next" -> AXMoveNext, unknown non-AX dropped
        XCTAssertEqual(
            AXWalkLogic.getActions(role: "AXButton", rawActionNames: ["Move next", "Bogus"]),
            ["AXMoveNext"])
    }

    // MARK: buildStates

    func testBuildStatesDisabled() {
        let attrs = AXAttributes([
            AXAttr.role: .string("AXButton"), AXAttr.enabled: .bool(false),
        ])
        XCTAssertEqual(
            AXWalkLogic.buildStates(attrs: attrs, valueSettable: false, rowSelectable: false),
            ["disabled"])
    }

    func testBuildStatesTruthyFlags() {
        let attrs = AXAttributes([
            AXAttr.role: .string("AXButton"),
            AXAttr.selected: .bool(true),
            AXAttr.expanded: .bool(true),
            AXAttr.focused: .bool(true),
        ])
        XCTAssertEqual(
            AXWalkLogic.buildStates(attrs: attrs, valueSettable: false, rowSelectable: false),
            ["selected", "expanded", "focused"])
    }

    func testBuildStatesSettableWithValueType() {
        let attrs = AXAttributes([
            AXAttr.role: .string("AXSlider"),
            AXAttr.value: .double(0.5),
        ])
        XCTAssertEqual(
            AXWalkLogic.buildStates(attrs: attrs, valueSettable: true, rowSelectable: false),
            ["settable", "float"])
    }

    func testBuildStatesRowSelectable() {
        let attrs = AXAttributes([AXAttr.role: .string("AXRow")])
        XCTAssertEqual(
            AXWalkLogic.buildStates(attrs: attrs, valueSettable: false, rowSelectable: true),
            ["selectable"])
    }

    func testBuildStatesRowSelectableSuppressedWhenSelected() {
        let attrs = AXAttributes([
            AXAttr.role: .string("AXRow"), AXAttr.selected: .bool(true),
        ])
        XCTAssertEqual(
            AXWalkLogic.buildStates(attrs: attrs, valueSettable: false, rowSelectable: true),
            ["selected"])
    }

    func testBuildStatesSortOrder() {
        // Provide every category; assert canonical order:
        // disabled, selected, selectable(n/a here), expanded, focused, settable, type
        let attrs = AXAttributes([
            AXAttr.role: .string("AXSlider"),
            AXAttr.enabled: .bool(false),
            AXAttr.selected: .bool(true),
            AXAttr.expanded: .bool(true),
            AXAttr.focused: .bool(true),
            AXAttr.value: .string("x"),
        ])
        XCTAssertEqual(
            AXWalkLogic.buildStates(attrs: attrs, valueSettable: true, rowSelectable: false),
            ["disabled", "selected", "expanded", "focused", "settable", "string"])
    }
}
