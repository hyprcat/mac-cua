import Foundation

// Vision OCR fallback (A2, US-046) — pure tier.
//
// OCR exists ONLY for genuinely tree-less surfaces (a canvas, a rendered PDF, an
// image-only window) and lives OFF the hot path: the spine invokes the OCR
// provider strictly when the AX tree is unavailable / near-empty. A normal AX app
// must NEVER trigger OCR. This file holds the gating decision, the
// observation→synthetic-node conversion, and the merge — all pure and
// Linux-testable; the real `VNRecognizeTextRequest` pass lives in MacCUAKit.

/// One recognized text run from the Vision OCR pass. `boundingBox` is in
/// CAPTURED-IMAGE PIXEL space, top-left origin — the same space the screenshot is
/// attached in — so synthetic nodes line up with the image the model sees.
public struct OCRObservation: Equatable, Sendable {
    public var text: String
    public var boundingBox: Rect
    public var confidence: Double

    public init(text: String, boundingBox: Rect, confidence: Double) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Provenance marker placed on `Node.source` for synthetic OCR nodes.
public let ocrNodeSource = "ocr"

/// Synthetic role for OCR text nodes (mirrors a plain static-text element so the
/// serializer/model treat them as read-only text).
public let ocrNodeRole = "AXStaticText"

public enum OCRFallback {
    /// Gate (A2): OCR runs ONLY when the AX surface is effectively tree-less.
    /// `axAvailable == false` (no AX tree at all) OR the pruned interactive-node
    /// count is at/below `threshold` (near-empty). A populated AX app returns
    /// false so OCR never fires on the hot path.
    public static func shouldRunOCR(
        nodeCount: Int, axAvailable: Bool, threshold: Int = 2
    ) -> Bool {
        if !axAvailable { return true }
        return nodeCount <= threshold
    }

    /// Convert OCR observations → synthetic `source:ocr` nodes (text + bounds,
    /// NO `axRef`, NO graph metadata). `startIndex` continues the existing node
    /// numbering so the merged list stays dense `0..N-1`. Empty/whitespace text is
    /// dropped; observations below `minConfidence` are dropped.
    public static func makeNodes(
        from observations: [OCRObservation],
        startIndex: Int = 0,
        minConfidence: Double = 0.0
    ) -> [Node] {
        var nodes: [Node] = []
        var idx = startIndex
        for obs in observations {
            let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if obs.confidence < minConfidence { continue }
            let node = Node(
                index: idx,
                role: ocrNodeRole,
                label: trimmed,
                depth: 0,
                position: Point(x: obs.boundingBox.x, y: obs.boundingBox.y),
                size: Size(w: obs.boundingBox.w, h: obs.boundingBox.h),
                source: ocrNodeSource,
                axRole: ocrNodeRole)
            nodes.append(node)
            idx += 1
        }
        return nodes
    }

    /// Merge synthetic OCR nodes into an existing (pruned) tree. The OCR nodes are
    /// appended after the existing nodes and numbered as a dense continuation of
    /// the existing indices, so element-index resolution stays unambiguous.
    public static func merge(
        existing: [Node],
        ocr observations: [OCRObservation],
        minConfidence: Double = 0.0
    ) -> [Node] {
        let start = (existing.map { $0.index }.max() ?? -1) + 1
        let ocrNodes = makeNodes(
            from: observations, startIndex: start, minConfidence: minConfidence)
        return existing + ocrNodes
    }
}
