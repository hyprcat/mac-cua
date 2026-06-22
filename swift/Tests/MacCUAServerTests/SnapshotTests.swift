import XCTest
import MacCUACore
@testable import MacCUAServer

/// Linux-buildable port of the snapshot-assembly scenarios in
/// `tests/test_session.py`: previous-frontmost restore (Invariant 15),
/// transient-only snapshot (no screenshot + dismiss after capture), focused-index
/// normalization (focused-state fallback + web-area ancestor), focused-collection
/// child expansion, and node geometry annotation. Where the helper is private,
/// the behavior is exercised through the internal `takeSnapshot` / `collectTreeNodes`.
final class SnapshotTests: XCTestCase {

    private let pid = 111
    private let windowId = 77

    private func baseFlags(
        codexTreeStyle: Bool = true,
        transientGraphs: Bool = true,
        webContentExtraction: Bool = false,
        systemSelection: Bool = false
    ) -> FeatureFlags {
        FeatureFlags(
            treePruning: false,
            codexTreeStyle: codexTreeStyle,
            richTextMarkdown: false,
            webContentExtraction: webContentExtraction,
            userInterruptionDetection: false,
            focusEnforcement: false,
            menuTracking: true,
            transientGraphs: transientGraphs,
            axActionVerification: false,
            cgeventActionVerification: false,
            systemSelection: systemSelection,
            confirmedDelivery: false)
    }

    private func target(pid: Int = 111, windowId: Int = 77) -> AppTarget {
        AppTarget(
            bundleId: "com.example.App", pid: pid, windowId: windowId, windowPid: pid,
            axApp: FakeAXRef("ax-app"), axWindow: FakeAXRef("ax-window"))
    }

    private func manager(
        apps: FakeAppResolver = FakeAppResolver(),
        ax: FakeAccessibility = FakeAccessibility(),
        cap: FakeCapture = FakeCapture(),
        flags: FeatureFlags
    ) -> SessionManager {
        SessionManager(
            providers: makeFakeProviders(apps: apps, accessibility: ax, capture: cap),
            flags: flags)
    }

    // MARK: - Previous-frontmost restore (Invariant 15)

    /// Ports test_restore_previous_frontmost_app_when_target_steals_focus:
    /// if the target became frontmost, restore the user's previous frontmost.
    func testRestorePreviousFrontmostWhenTargetStealsFocus() {
        let apps = FakeAppResolver()
        apps.frontmost = AppInfo(name: "Target", bundleId: "com.target", pid: 222, running: true)
        let mgr = manager(apps: apps, flags: baseFlags())
        let session = AppSession(target: target(pid: 222))
        let previous = AppInfo(name: "Prev", bundleId: "com.prev", pid: 111, running: true)

        mgr.restorePreviousFrontmostApp(session, previous)
        XCTAssertEqual(apps.restoreCalls.count, 1)
        XCTAssertEqual(apps.restoreCalls.first??.pid, 111)
    }

    /// Ports test_restore_previous_frontmost_app_skips_when_target_was_already_frontmost:
    /// if the previous frontmost IS the target, restore is a no-op.
    func testRestorePreviousFrontmostSkipsWhenAlreadyFrontmost() {
        let apps = FakeAppResolver()
        apps.frontmost = AppInfo(name: "Target", bundleId: "com.target", pid: 222, running: true)
        let mgr = manager(apps: apps, flags: baseFlags())
        let session = AppSession(target: target(pid: 222))
        let previous = AppInfo(name: "Target", bundleId: "com.target", pid: 222, running: true)

        mgr.restorePreviousFrontmostApp(session, previous)
        XCTAssertTrue(apps.restoreCalls.isEmpty)
    }

    /// Restore is also skipped when the target never became frontmost (the user's
    /// app is still on top).
    func testRestorePreviousFrontmostSkipsWhenTargetNotFrontmost() {
        let apps = FakeAppResolver()
        apps.frontmost = AppInfo(name: "Prev", bundleId: "com.prev", pid: 111, running: true)
        let mgr = manager(apps: apps, flags: baseFlags())
        let session = AppSession(target: target(pid: 222))
        let previous = AppInfo(name: "Prev", bundleId: "com.prev", pid: 111, running: true)

        mgr.restorePreviousFrontmostApp(session, previous)
        XCTAssertTrue(apps.restoreCalls.isEmpty)
    }

    // MARK: - Transient-only snapshot

    /// Sets up an open transient surface on a session so `takeSnapshot` takes the
    /// transient fast path.
    private func sessionWithTransient(_ mgr: SessionManager, ax: FakeAccessibility) -> AppSession {
        let session = AppSession(target: target())
        // Wire the session's monitors (settle + menu tracker) the way trackSession
        // would, by registering it through the manager.
        mgr.trackSession(session)
        let root = FakeAXRef("transient-root")
        session.graphRegistry.pushTransient(
            session.graphs, rootRef: root,
            nodes: [Node(index: 0, role: "menu", depth: 0, axRef: root, axRole: "AXMenu")],
            rootLocator: nil, source: nil, transientKind: "menu")
        (session.menuTracker as? FakeMenuTracking)?.menusOpen = true
        return session
    }

    /// Ports test_take_snapshot_uses_transient_only_tree_without_screenshot +
    /// test_take_snapshot_active_transient_skips_persistent_refresh_and_enrichment:
    /// the transient path walks only the transient root, emits NO screenshot, and
    /// pushes a transient graph stamped onto the nodes.
    func testTakeSnapshotTransientOnlyTreeWithoutScreenshot() {
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "menu", label: "View", depth: 0,
                        axRef: FakeAXRef("menu-node"), axRole: "AXMenu")]
        let cap = FakeCapture()
        let mgr = manager(ax: ax, cap: cap, flags: baseFlags())
        let session = sessionWithTransient(mgr, ax: ax)

        let response = mgr.takeSnapshot(session, skipRefresh: true)

        XCTAssertNil(response.screenshot)
        // No window screenshot was captured at all on the transient path.
        XCTAssertTrue(cap.captureCalls.isEmpty)
        XCTAssertEqual(session.graphs.transientStack.count, 1)
        XCTAssertEqual(session.graphs.transientStack.last?.kind, .transient)
        // Nodes carry the transient graph id.
        XCTAssertEqual(session.treeNodes.first?.graphId, session.graphs.transientStack.last?.graphId)
        XCTAssertEqual(response.app, "com.example.App")
    }

    /// Ports test_take_snapshot_dismisses_transient_surface_after_capture:
    /// after building the transient snapshot, the surface is dismissed (a best-
    /// effort AXCancel/AXPress on the root) and the graph is marked closed.
    func testTakeSnapshotDismissesTransientSurfaceAfterCapture() {
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "menu", label: "View", depth: 0,
                        axRef: FakeAXRef("menu-node"), axRole: "AXMenu")]
        ax.actionNamesForRef = ["AXCancel"]  // root exposes a dismiss action
        let mgr = manager(ax: ax, flags: baseFlags())
        let session = sessionWithTransient(mgr, ax: ax)

        _ = mgr.takeSnapshot(session)

        // Dismiss attempted on the transient root, graph closed afterwards.
        XCTAssertTrue(ax.performedOnRef.contains("AXCancel"))
        XCTAssertEqual(session.graphs.transientStack.last?.state, .closed)
    }

    // MARK: - Focused-index normalization (through takeSnapshot)

    /// Ports test_normalize_focused_index_falls_back_to_focused_state:
    /// when the provider yields no focused element, the index falls back to the
    /// node carrying the "focused" state.
    func testNormalizeFocusedIndexFallsBackToFocusedState() {
        let ax = FakeAccessibility()
        ax.tree = [
            Node(index: 0, role: "standard window", label: "Code", depth: 0, axRole: "AXWindow"),
            Node(index: 1, role: "button", label: "Explorer", states: ["focused"], depth: 1, axRole: "AXButton"),
        ]
        ax.focusedIndex = nil  // provider can't determine focus
        let mgr = manager(ax: ax, flags: baseFlags(codexTreeStyle: false, transientGraphs: false))
        let session = AppSession(target: target())

        // skipRefresh mirrors the post-resolution call site in execute().
        let response = mgr.takeSnapshot(session, skipRefresh: true)
        XCTAssertEqual(response.focusedElement, 1)
    }

    /// Ports test_normalize_focused_index_prefers_web_area_ancestor_for_editor_focus:
    /// with codex tree style, focus on a text area inside a web area resolves to
    /// the web-area ancestor.
    func testNormalizeFocusedIndexPrefersWebAreaAncestor() {
        let ax = FakeAccessibility()
        ax.tree = [
            Node(index: 0, role: "standard window", label: "Code", depth: 0, axRole: "AXWindow"),
            Node(index: 1, role: "web area", label: "workspace", depth: 1, isWebArea: true, axRole: "AXWebArea"),
            Node(index: 2, role: "text area", label: "editor", states: ["focused"], depth: 2, axRole: "AXTextArea"),
        ]
        ax.focusedIndex = 2
        let mgr = manager(ax: ax, flags: baseFlags(codexTreeStyle: true, transientGraphs: false))
        let session = AppSession(target: target())

        let response = mgr.takeSnapshot(session, skipRefresh: true)
        XCTAssertEqual(response.focusedElement, 1)
    }

    // MARK: - Focused-collection child expansion (through collectTreeNodes)

    /// Ports test_expand_focused_collection_children_inserts_live_children:
    /// a focused collection with no meaningful direct children gets its live
    /// children inserted and the whole list re-indexed.
    func testExpandFocusedCollectionInsertsLiveChildren() {
        let childRef = FakeAXRef("child")
        let ax = FakeAccessibility()
        let root = FakeAXRef("root")
        let collectionRef = FakeAXRef("collection")
        ax.tree = [
            Node(index: 0, role: "standard window", label: "Wallpaper", depth: 0,
                 axRef: root, axRole: "AXWindow"),
            Node(index: 1, role: "collection", states: ["focused"], depth: 1,
                 axRef: collectionRef, axRole: "AXOpaqueProviderGroup"),
        ]
        ax.childrenForRef = { $0 === collectionRef ? [childRef] : [] }
        ax.nodeForRef = { ref, depth, index in
            Node(index: index, role: "button", description: "Black", depth: depth,
                 axRef: ref, axRole: "AXButton")
        }
        let mgr = manager(ax: ax, flags: baseFlags())

        let expanded = mgr.collectTreeNodes(
            root, axApp: FakeAXRef("app"), targetPid: pid, appType: .nativeCocoa)
        XCTAssertEqual(expanded.map(\.description), [nil, nil, "Black"])
        XCTAssertEqual(expanded[2].depth, 2)
        XCTAssertEqual(expanded[2].index, 2)  // re-indexed contiguously
    }

    /// Ports test_expand_focused_collection_children_skips_when_descendants_already_present:
    /// when the focused collection already has meaningful direct children, no live
    /// fetch happens.
    func testExpandFocusedCollectionSkipsWhenChildrenPresent() {
        let collectionRef = FakeAXRef("collection")
        let ax = FakeAccessibility()
        ax.tree = [
            Node(index: 0, role: "collection", states: ["focused"], depth: 0,
                 axRef: collectionRef, axRole: "AXOpaqueProviderGroup"),
            Node(index: 1, role: "button", description: "Black", depth: 1,
                 axRef: FakeAXRef("present"), axRole: "AXButton"),
        ]
        var liveFetchCount = 0
        ax.childrenForRef = { _ in liveFetchCount += 1; return [FakeAXRef("x")] }
        let mgr = manager(ax: ax, flags: baseFlags())

        let expanded = mgr.collectTreeNodes(
            collectionRef, axApp: FakeAXRef("app"), targetPid: pid, appType: .nativeCocoa)
        XCTAssertEqual(expanded.count, 2)
        XCTAssertEqual(liveFetchCount, 0)  // live-children fetch skipped
    }

    /// Ports test_expand_focused_collection_children_ignores_scrollbar_only_children:
    /// a focused collection whose only direct child is a scrollbar still triggers
    /// the live-children expansion (scrollbar is not "meaningful").
    func testExpandFocusedCollectionIgnoresScrollbarOnlyChildren() {
        let collectionRef = FakeAXRef("collection")
        let childRef = FakeAXRef("child")
        let ax = FakeAccessibility()
        ax.tree = [
            Node(index: 0, role: "collection", states: ["focused"], depth: 0,
                 axRef: collectionRef, axRole: "AXOpaqueProviderGroup"),
            Node(index: 1, role: "scroll bar", label: "0", states: ["settable"], value: "0",
                 depth: 1, axRef: FakeAXRef("scrollbar"), axRole: "AXScrollBar"),
        ]
        ax.childrenForRef = { $0 === collectionRef ? [childRef] : [] }
        ax.nodeForRef = { ref, depth, index in
            Node(index: index, role: "button", description: "Black", depth: depth,
                 axRef: ref, axRole: "AXButton")
        }
        let mgr = manager(ax: ax, flags: baseFlags())

        let expanded = mgr.collectTreeNodes(
            collectionRef, axApp: FakeAXRef("app"), targetPid: pid, appType: .nativeCocoa)
        // Scrollbar is not "meaningful" → expansion fires; the live child is
        // inserted right after the focused collection (matching Python's ordering).
        XCTAssertEqual(expanded.map(\.description), [nil, "Black", nil])
        XCTAssertEqual(expanded[1].role, "button")
    }

    // MARK: - Node geometry annotation (through takeSnapshot)

    /// Ports test_annotate_node_geometry_uses_transport_screenshot_space:
    /// an element's AX frame is mapped into screenshot space using the visible
    /// rect + screenshot size scale. Driven through takeSnapshot so the real
    /// annotate pass runs (geometry helper is private).
    func testNodeGeometryMappedIntoScreenshotSpace() {
        let nodeRef = FakeAXRef("submit")
        let ax = FakeAccessibility()
        ax.tree = [Node(index: 0, role: "button", label: "Submit", depth: 0,
                        axRef: nodeRef, axRole: "AXButton")]
        // AX frame in screen space.
        ax.frameForNode = { _ in Rect(x: 150, y: 250, w: 100, h: 40) }
        let cap = FakeCapture()
        cap.bounds = Rect(x: 100, y: 200, w: 400, h: 200)   // visible rect
        cap.image = FakeImage(width: 200, height: 100)       // screenshot size
        let mgr = manager(ax: ax, cap: cap,
                          flags: baseFlags(codexTreeStyle: false, transientGraphs: false))
        let session = AppSession(target: target())

        let response = mgr.takeSnapshot(session, skipRefresh: true)
        let n = response.treeNodes.first
        XCTAssertNotNil(n?.position)
        XCTAssertNotNil(n?.size)
        // scaleX = 200/400 = 0.5, scaleY = 100/200 = 0.5.
        // x = (150-100)*0.5 = 25, y = (250-200)*0.5 = 25, w = 100*0.5 = 50, h = 40*0.5 = 20.
        XCTAssertEqual(n?.position?.x, 25)
        XCTAssertEqual(n?.position?.y, 25)
        XCTAssertEqual(n?.size?.w, 50)
        XCTAssertEqual(n?.size?.h, 20)
    }
}
