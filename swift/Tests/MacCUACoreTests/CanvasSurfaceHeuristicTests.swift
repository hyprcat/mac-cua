import XCTest
@testable import MacCUACore

// Covers US-060: the best-effort canvas / foreground-only surface classifier
// (`CanvasSurfaceHeuristic`), the `SurfaceDescriptor` input, the no-op hint, and
// the `unsupported_canvas_surface` structured error variant.
//
// The classifier is deliberately CONSERVATIVE: false positives (wrongly flagging a
// legitimate app as canvas) are worse than false negatives, so the bulk of these
// tests pin down what does NOT get flagged.

final class CanvasSurfaceHeuristicTests: XCTestCase {

    // MARK: - isLikelyCanvasSurface: positive cases

    func testKnownBundleIdIsCanvas() {
        let blender = SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 0)
        XCTAssertTrue(CanvasSurfaceHeuristic.isLikelyCanvasSurface(blender))
    }

    func testKnownBundleIdIsCanvasEvenWithSomeAXNodes() {
        // Membership wins regardless of the (best-effort) AX count.
        let blender = SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 7)
        XCTAssertTrue(CanvasSurfaceHeuristic.isLikelyCanvasSurface(blender))
    }

    func testGameEnginePrefixIsCanvas() {
        // A Unity-built player not individually enumerated, matched by prefix.
        let game = SurfaceDescriptor(bundleId: "com.unity3d.SomeShippedGame", axRoleCount: 0)
        XCTAssertTrue(CanvasSurfaceHeuristic.isLikelyCanvasSurface(game))
    }

    func testGameEnginePrefixMatchIsCaseInsensitive() {
        let game = SurfaceDescriptor(bundleId: "COM.UNITY3D.SomeGame", axRoleCount: 0)
        XCTAssertTrue(CanvasSurfaceHeuristic.isLikelyCanvasSurface(game))
    }

    // MARK: - isLikelyCanvasSurface: negative cases (the important ones)

    func testOrdinaryAppWithAXNodesIsNotCanvas() {
        let calc = SurfaceDescriptor(bundleId: "com.apple.calculator", axRoleCount: 25)
        XCTAssertFalse(CanvasSurfaceHeuristic.isLikelyCanvasSurface(calc))
    }

    func testNilBundleIdWithNodesIsNotCanvas() {
        let s = SurfaceDescriptor(bundleId: nil, axRoleCount: 10)
        XCTAssertFalse(CanvasSurfaceHeuristic.isLikelyCanvasSurface(s))
    }

    func testEmptyAXTreeAloneDoesNotFlagUnknownApp() {
        // The crucial conservative rule: a permission-blocked / not-yet-populated
        // ordinary app exposes 0 actionable nodes but must NOT be called canvas.
        let blocked = SurfaceDescriptor(bundleId: "com.apple.Safari", axRoleCount: 0)
        XCTAssertFalse(CanvasSurfaceHeuristic.isLikelyCanvasSurface(blocked))
    }

    func testNilBundleIdWithEmptyTreeIsNotCanvas() {
        let s = SurfaceDescriptor(bundleId: nil, axRoleCount: 0)
        XCTAssertFalse(CanvasSurfaceHeuristic.isLikelyCanvasSurface(s))
    }

    func testEmptyStringBundleIdIsNotCanvas() {
        let s = SurfaceDescriptor(bundleId: "", axRoleCount: 0)
        XCTAssertFalse(CanvasSurfaceHeuristic.isLikelyCanvasSurface(s))
    }

    func testUnrelatedReverseDNSPrefixIsNotCanvas() {
        // Guard the prefix rule does not over-match (e.g. a vendor whose id merely
        // starts similarly but is not a game engine namespace).
        let s = SurfaceDescriptor(bundleId: "com.unityhealth.app", axRoleCount: 5)
        XCTAssertFalse(CanvasSurfaceHeuristic.isLikelyCanvasSurface(s))
    }

    // MARK: - knownCanvasBundleIds contents

    func testKnownSetContainsBlenderAndUnity() {
        XCTAssertTrue(CanvasSurfaceHeuristic.knownCanvasBundleIds.contains("org.blender.blender"))
        XCTAssertTrue(CanvasSurfaceHeuristic.knownCanvasBundleIds.contains("com.unity3d.UnityEditor"))
    }

    // MARK: - noEffectHint

    func testNoEffectHintMentionsCanvasAndInvariant() {
        let s = SurfaceDescriptor(bundleId: "com.example.unknown", axRoleCount: 3)
        let hint = CanvasSurfaceHeuristic.noEffectHint(s)
        XCTAssertTrue(hint.contains("canvas"), "hint should mention canvas: \(hint)")
        XCTAssertTrue(hint.contains("no-op"), "hint should mention no-op: \(hint)")
    }

    func testNoEffectHintNamesKnownCanvasBundle() {
        let blender = SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 0)
        let hint = CanvasSurfaceHeuristic.noEffectHint(blender)
        XCTAssertTrue(hint.contains("org.blender.blender"), "hint should name the bundle: \(hint)")
        XCTAssertTrue(hint.contains("known canvas surface"), "hint should be the stronger form: \(hint)")
    }

    func testNoEffectHintMentionsEmptyTreeForUnknownEmptySurface() {
        let s = SurfaceDescriptor(bundleId: "com.example.unknown", axRoleCount: 0)
        let hint = CanvasSurfaceHeuristic.noEffectHint(s)
        XCTAssertTrue(
            hint.contains("accessibility nodes"),
            "empty-tree unknown surface hint should mention the weak AX signal: \(hint)")
    }

    func testNoEffectHintAlwaysReferencesDoc() {
        for s in [
            SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 0),
            SurfaceDescriptor(bundleId: "com.example.unknown", axRoleCount: 0),
            SurfaceDescriptor(bundleId: "com.example.unknown", axRoleCount: 4),
        ] {
            XCTAssertTrue(
                CanvasSurfaceHeuristic.noEffectHint(s).contains("KNOWN_LIMITATIONS.md"),
                "every hint should point at the doc")
        }
    }

    // MARK: - SurfaceDescriptor value semantics

    func testSurfaceDescriptorEquatable() {
        let a = SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 0)
        let b = SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 0)
        let c = SurfaceDescriptor(bundleId: "org.blender.blender", axRoleCount: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - unsupported_canvas_surface structured error

    func testUnsupportedCanvasSurfaceReasonCode() {
        XCTAssertEqual(
            UnsupportedSurfaceError.unsupportedCanvasSurface, "unsupported_canvas_surface")
    }

    func testCanvasSurfaceErrorKindAndMessage() {
        let err = UnsupportedSurfaceError.canvasSurface()
        XCTAssertEqual(err.kind, .unsupportedSurface)
        XCTAssertEqual(err.kind.rawValue, "UnsupportedSurfaceError")
        // Message must explain the activation requirement + that it is by design.
        XCTAssertTrue(err.message.contains("window activation"), err.message)
        XCTAssertTrue(err.message.contains("Prime Invariant"), err.message)
        XCTAssertTrue(err.message.contains("unsupported"), err.message)
    }

    func testCanvasSurfaceErrorAppendsDetail() {
        let err = UnsupportedSurfaceError.canvasSurface(detail: "org.blender.blender")
        XCTAssertTrue(err.message.contains("org.blender.blender"), err.message)
    }

    func testCanvasSurfaceErrorIsThrowable() {
        func failing() throws { throw UnsupportedSurfaceError.canvasSurface() }
        XCTAssertThrowsError(try failing()) { error in
            guard let e = error as? AutomationError else { return XCTFail("wrong type") }
            XCTAssertEqual(e.kind, .unsupportedSurface)
        }
    }

    func testCanvasSurfaceErrorIsNotMisclassifiedAsOtherFamilies() {
        let err = UnsupportedSurfaceError.canvasSurface()
        XCTAssertFalse(err.isSafetyError)
        XCTAssertFalse(err.isInputError)
        XCTAssertFalse(err.isAXError)
    }
}
