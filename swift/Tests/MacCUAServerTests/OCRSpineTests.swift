import XCTest
import MacCUACore
@testable import MacCUAServer

/// US-046: the OCR fallback is wired into `takeSnapshot` and fires ONLY for
/// tree-less / near-empty surfaces, merged into the model-facing tree but kept out
/// of the AX graph/refetch path.
final class OCRSpineTests: XCTestCase {
    private func flags(ocrFallback: Bool) -> FeatureFlags {
        FeatureFlags(
            treePruning: false, codexTreeStyle: true, richTextMarkdown: false,
            webContentExtraction: false, userInterruptionDetection: false,
            focusEnforcement: false, menuTracking: false, transientGraphs: false,
            axActionVerification: false, cgeventActionVerification: false,
            systemSelection: false, confirmedDelivery: false, ocrFallback: ocrFallback)
    }

    private func target() -> AppTarget {
        AppTarget(
            bundleId: "com.example.App", pid: 111, windowId: 77, windowPid: 111,
            axApp: FakeAXRef("ax-app"), axWindow: FakeAXRef("ax-window"))
    }

    private func ocrObs() -> [OCRObservation] {
        [
            OCRObservation(text: "Canvas Title", boundingBox: Rect(x: 5, y: 5, w: 100, h: 20), confidence: 0.95),
            OCRObservation(text: "Some body text", boundingBox: Rect(x: 5, y: 30, w: 200, h: 16), confidence: 0.9),
        ]
    }

    /// Near-empty AX tree + flag on → OCR runs and synthetic nodes are merged.
    func testOCRFiresOnEmptyTree() {
        let ax = FakeAccessibility()
        ax.tree = []  // tree-less canvas/PDF surface
        let ocr = FakeOCR(observations: ocrObs())
        let mgr = SessionManager(
            providers: makeFakeProviders(accessibility: ax, ocr: ocr),
            flags: flags(ocrFallback: true))
        let session = AppSession(target: target())

        let response = mgr.takeSnapshot(session, skipRefresh: true)

        XCTAssertEqual(ocr.recognizeCalls, 1)
        XCTAssertEqual(session.treeNodes.count, 2)
        XCTAssertEqual(session.treeNodes.map { $0.source }, [ocrNodeSource, ocrNodeSource])
        XCTAssertEqual(session.treeNodes.map { $0.label }, ["Canvas Title", "Some body text"])
        XCTAssertTrue((response.treeText ?? "").contains("Canvas Title"))
        // OCR nodes stay out of the RefetchableTree (they have no axRef).
        XCTAssertTrue((session.refetchableTree?.nodes ?? []).isEmpty)
    }

    /// Populated AX tree → OCR provider is NEVER called.
    func testOCRSkippedOnPopulatedTree() {
        let ax = FakeAccessibility()
        ax.tree = (0..<5).map { Node(index: $0, role: "AXButton", label: "b\($0)", depth: 0,
                                     axRef: FakeAXRef("n\($0)"), axRole: "AXButton") }
        let ocr = FakeOCR(observations: ocrObs())
        let mgr = SessionManager(
            providers: makeFakeProviders(accessibility: ax, ocr: ocr),
            flags: flags(ocrFallback: true))
        let session = AppSession(target: target())

        _ = mgr.takeSnapshot(session, skipRefresh: true)

        XCTAssertEqual(ocr.recognizeCalls, 0, "OCR must not fire on a populated AX app")
        XCTAssertEqual(session.treeNodes.count, 5)
        XCTAssertTrue(session.treeNodes.allSatisfy { $0.source == nil })
    }

    /// Flag off → OCR never runs even on an empty tree.
    func testOCRDisabledByFlag() {
        let ax = FakeAccessibility()
        ax.tree = []
        let ocr = FakeOCR(observations: ocrObs())
        let mgr = SessionManager(
            providers: makeFakeProviders(accessibility: ax, ocr: ocr),
            flags: flags(ocrFallback: false))
        let session = AppSession(target: target())

        _ = mgr.takeSnapshot(session, skipRefresh: true)

        XCTAssertEqual(ocr.recognizeCalls, 0)
        XCTAssertTrue(session.treeNodes.isEmpty)
    }

    /// No OCR provider configured (nil) → empty tree stays empty, no crash.
    func testNoOCRProvider() {
        let ax = FakeAccessibility()
        ax.tree = []
        let mgr = SessionManager(
            providers: makeFakeProviders(accessibility: ax, ocr: nil),
            flags: flags(ocrFallback: true))
        let session = AppSession(target: target())

        _ = mgr.takeSnapshot(session, skipRefresh: true)
        XCTAssertTrue(session.treeNodes.isEmpty)
    }
}
