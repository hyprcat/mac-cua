import XCTest
@testable import MacCUACore

final class ClickPrimerPolicyTests: XCTestCase {

    // MARK: ClickPrimerPolicy.shouldPrime — truth table

    // Chromium-class surfaces (.browser, .electron) with a pixel click and the
    // flag on are the ONLY combination that primes.

    func testPrimesForBrowserPixelClickWhenFlagOn() {
        XCTAssertTrue(ClickPrimerPolicy.shouldPrime(
            surface: .browser, clickKind: .pixel, flagEnabled: true))
    }

    func testPrimesForElectronPixelClickWhenFlagOn() {
        XCTAssertTrue(ClickPrimerPolicy.shouldPrime(
            surface: .electron, clickKind: .pixel, flagEnabled: true))
    }

    // Flag off — never primes, regardless of surface or click kind.

    func testFlagOffNeverPrimes() {
        for surface in AppType.allCases {
            for kind in [ClickKind.pixel, .axAction] {
                XCTAssertFalse(
                    ClickPrimerPolicy.shouldPrime(
                        surface: surface, clickKind: kind, flagEnabled: false),
                    "flag off must not prime (surface=\(surface), kind=\(kind))")
            }
        }
    }

    // AX-action clicks bypass the pointer gate — never prime even on Chromium.

    func testAXActionClickNeverPrimesEvenOnChromium() {
        XCTAssertFalse(ClickPrimerPolicy.shouldPrime(
            surface: .browser, clickKind: .axAction, flagEnabled: true))
        XCTAssertFalse(ClickPrimerPolicy.shouldPrime(
            surface: .electron, clickKind: .axAction, flagEnabled: true))
    }

    // Non-web surfaces have no Chromium gate — never prime, even pixel + flag on.

    func testNonWebSurfacesNeverPrime() {
        for surface in [AppType.nativeCocoa, .java, .qt, .unknown] {
            XCTAssertFalse(
                ClickPrimerPolicy.shouldPrime(
                    surface: surface, clickKind: .pixel, flagEnabled: true),
                "non-web surface must not prime (surface=\(surface))")
        }
    }

    // Full cross product: only {.browser,.electron} × .pixel × flag-on is true.

    func testFullTruthTable() {
        let chromium: Set<AppType> = [.browser, .electron]
        for surface in AppType.allCases {
            for kind in [ClickKind.pixel, .axAction] {
                for flag in [true, false] {
                    let expected = flag && kind == .pixel && chromium.contains(surface)
                    XCTAssertEqual(
                        ClickPrimerPolicy.shouldPrime(
                            surface: surface, clickKind: kind, flagEnabled: flag),
                        expected,
                        "surface=\(surface) kind=\(kind) flag=\(flag)")
                }
            }
        }
    }

    // MARK: ClickDelivery.sequence(count:includePrimer:)

    func testIncludePrimerFalseEqualsPlainSequence() {
        for count in [1, 2, 3] {
            XCTAssertEqual(
                ClickDelivery.sequence(count: count, includePrimer: false),
                ClickDelivery.sequence(count: count))
        }
    }

    func testPrimerIsPrependedAsExactlyOnePair() {
        let withPrimer = ClickDelivery.sequence(count: 1, includePrimer: true)
        let real = ClickDelivery.sequence(count: 1)
        // One extra pair (2 steps) ahead of the real steps.
        XCTAssertEqual(withPrimer.count, real.count + 2)
        // The trailing steps are byte-identical to the plain sequence.
        XCTAssertEqual(Array(withPrimer.suffix(real.count)), real)
    }

    func testPrimerPairOrderingAndMarking() {
        let steps = ClickDelivery.sequence(count: 2, includePrimer: true)
        // First two steps are the primer: down then up, both marked isPrimer.
        XCTAssertEqual(steps[0].phase, .down)
        XCTAssertEqual(steps[1].phase, .up)
        XCTAssertTrue(steps[0].isPrimer)
        XCTAssertTrue(steps[1].isPrimer)
        // Everything after the primer is a real (non-primer) step.
        for step in steps.dropFirst(2) {
            XCTAssertFalse(step.isPrimer)
        }
    }

    func testPrimerPairHasZeroPressureOnBothEvents() {
        let steps = ClickDelivery.sequence(count: 1, includePrimer: true)
        XCTAssertEqual(steps[0].pressure, 0.0)
        XCTAssertEqual(steps[1].pressure, 0.0)
        // Primer clickState is a lone single click.
        XCTAssertEqual(steps[0].clickState, 1)
        XCTAssertEqual(steps[1].clickState, 1)
    }

    func testRealStepsUnchangedWithPrimer() {
        // With the primer prepended, the real-click portion must be exactly the
        // same steps (phase/clickState/pressure AND isPrimer == false) as the
        // plain sequence — the primer only precedes, never alters.
        for count in [1, 2, 3] {
            let real = ClickDelivery.sequence(count: count)
            let withPrimer = ClickDelivery.sequence(count: count, includePrimer: true)
            XCTAssertEqual(Array(withPrimer.suffix(real.count)), real)
        }
    }

    func testExistingPlainSequenceStepsAreNotPrimers() {
        // Guard the default: nothing produced by the legacy entry point is ever
        // marked as a primer.
        for step in ClickDelivery.sequence(count: 3) {
            XCTAssertFalse(step.isPrimer)
        }
    }
}
