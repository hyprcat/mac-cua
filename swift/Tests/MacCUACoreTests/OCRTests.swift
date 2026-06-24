import XCTest
@testable import MacCUACore

final class OCRTests: XCTestCase {
    // MARK: - Gating (A2): OCR fires only on tree-less / near-empty surfaces

    func testGateRunsWhenAXUnavailable() {
        XCTAssertTrue(OCRFallback.shouldRunOCR(nodeCount: 0, axAvailable: false))
        // Even a non-trivial count: if AX is flagged unavailable, OCR runs.
        XCTAssertTrue(OCRFallback.shouldRunOCR(nodeCount: 50, axAvailable: false))
    }

    func testGateRunsWhenNearEmpty() {
        XCTAssertTrue(OCRFallback.shouldRunOCR(nodeCount: 0, axAvailable: true))
        XCTAssertTrue(OCRFallback.shouldRunOCR(nodeCount: 2, axAvailable: true))
    }

    func testGateSkipsPopulatedAXApp() {
        XCTAssertFalse(OCRFallback.shouldRunOCR(nodeCount: 3, axAvailable: true))
        XCTAssertFalse(OCRFallback.shouldRunOCR(nodeCount: 200, axAvailable: true))
    }

    func testGateCustomThreshold() {
        XCTAssertTrue(OCRFallback.shouldRunOCR(nodeCount: 5, axAvailable: true, threshold: 5))
        XCTAssertFalse(OCRFallback.shouldRunOCR(nodeCount: 6, axAvailable: true, threshold: 5))
    }

    // MARK: - Observation → synthetic node conversion

    func testMakeNodesBasic() {
        let obs = [
            OCRObservation(text: "Hello", boundingBox: Rect(x: 10, y: 20, w: 30, h: 12), confidence: 0.9),
            OCRObservation(text: "World", boundingBox: Rect(x: 10, y: 40, w: 35, h: 12), confidence: 0.8),
        ]
        let nodes = OCRFallback.makeNodes(from: obs)
        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].index, 0)
        XCTAssertEqual(nodes[1].index, 1)
        XCTAssertEqual(nodes[0].role, ocrNodeRole)
        XCTAssertEqual(nodes[0].label, "Hello")
        XCTAssertEqual(nodes[0].source, ocrNodeSource)
        XCTAssertEqual(nodes[0].position, Point(x: 10, y: 20))
        XCTAssertEqual(nodes[0].size, Size(w: 30, h: 12))
        XCTAssertNil(nodes[0].axRef, "OCR nodes carry no AX ref")
    }

    func testMakeNodesStartIndexContinues() {
        let obs = [OCRObservation(text: "X", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0)]
        let nodes = OCRFallback.makeNodes(from: obs, startIndex: 7)
        XCTAssertEqual(nodes[0].index, 7)
    }

    func testMakeNodesDropsEmptyAndWhitespace() {
        let obs = [
            OCRObservation(text: "  ", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0),
            OCRObservation(text: "", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0),
            OCRObservation(text: " kept ", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0),
        ]
        let nodes = OCRFallback.makeNodes(from: obs)
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].label, "kept", "text is trimmed")
        XCTAssertEqual(nodes[0].index, 0, "dropped entries do not consume indices")
    }

    func testMakeNodesDropsBelowConfidence() {
        let obs = [
            OCRObservation(text: "low", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 0.2),
            OCRObservation(text: "high", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 0.7),
        ]
        let nodes = OCRFallback.makeNodes(from: obs, minConfidence: 0.5)
        XCTAssertEqual(nodes.map { $0.label }, ["high"])
    }

    // MARK: - Merge into existing pruned tree

    func testMergeAppendsWithDenseContinuation() {
        let existing = [
            Node(index: 0, role: "AXWebArea", depth: 0),
            Node(index: 1, role: "AXGroup", depth: 1),
        ]
        let obs = [
            OCRObservation(text: "A", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0),
            OCRObservation(text: "B", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0),
        ]
        let merged = OCRFallback.merge(existing: existing, ocr: obs)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map { $0.index }, [0, 1, 2, 3])
        XCTAssertEqual(merged[2].source, ocrNodeSource)
        XCTAssertEqual(merged[3].source, ocrNodeSource)
        XCTAssertNil(merged[0].source, "real AX nodes keep nil source")
    }

    func testMergeIntoEmptyTreeStartsAtZero() {
        let obs = [OCRObservation(text: "only", boundingBox: Rect(x: 0, y: 0, w: 1, h: 1), confidence: 1.0)]
        let merged = OCRFallback.merge(existing: [], ocr: obs)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].index, 0)
    }
}
