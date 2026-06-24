#if os(macOS)
import Foundation
import Vision
import CoreGraphics
import MacCUACore

// Vision OCR fallback (A2, US-046) — real macOS impl.
//
// Runs `VNRecognizeTextRequest(.accurate)` over the already-captured window image
// and returns recognized text runs in captured-image PIXEL space (top-left
// origin). Read-only over an image already in hand — never captures fresh, never
// foregrounds/activates (Invariant 13). The spine gates the call strictly to
// tree-less / near-empty surfaces (`OCRFallback.shouldRunOCR`), so this never
// fires on a normal AX app.
public final class KitOCRProvider: OCRProvider {
    public init() {}

    public func recognizeText(in image: CapturedImage) -> [OCRObservation] {
        // We need the backing CGImage; only `KitCapturedImage` carries one.
        guard let kitImage = image as? KitCapturedImage else { return [] }
        let cg = kitImage.cgImage
        let width = Double(cg.width)
        let height = Double(cg.height)
        guard width > 0, height > 0 else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results else { return [] }
        var observations: [OCRObservation] = []
        for result in results {
            guard let candidate = result.topCandidates(1).first else { continue }
            // Vision boundingBox is normalized [0,1] with BOTTOM-left origin.
            // Convert to captured-image PIXEL space with TOP-left origin so the
            // synthetic node lines up with the attached screenshot.
            let bb = result.boundingBox
            let px = bb.origin.x * width
            let pw = bb.size.width * width
            let ph = bb.size.height * height
            let pyTopLeft = (1.0 - bb.origin.y - bb.size.height) * height
            observations.append(
                OCRObservation(
                    text: candidate.string,
                    boundingBox: Rect(x: px, y: pyTopLeft, w: pw, h: ph),
                    confidence: Double(candidate.confidence)))
        }
        return observations
    }
}
#endif
