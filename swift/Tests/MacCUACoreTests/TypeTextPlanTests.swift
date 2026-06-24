import XCTest
@testable import MacCUACore

final class TypeTextPlanTests: XCTestCase {

    // MARK: keyName mapping (whitespace -> named keys)

    func testKeyNameMapsWhitespace() {
        XCTAssertEqual(TypeTextPlan.keyName(for: " "), "space")
        XCTAssertEqual(TypeTextPlan.keyName(for: "\n"), "return")
        XCTAssertEqual(TypeTextPlan.keyName(for: "\r"), "return")
        XCTAssertEqual(TypeTextPlan.keyName(for: "\t"), "tab")
        XCTAssertEqual(TypeTextPlan.keyName(for: "a"), "a")
    }

    // MARK: plain ASCII -> keycode steps

    func testPlainAsciiUsesKeycodePath() {
        let steps = TypeTextPlan.plan(for: "ab")
        XCTAssertEqual(steps.count, 2)
        for step in steps {
            if case .keycode = step { continue }
            XCTFail("expected keycode step, got \(step)")
        }
    }

    func testSpaceBecomesKeycodeNotUnicode() {
        let steps = TypeTextPlan.plan(for: "a b")
        XCTAssertEqual(steps.count, 3)
        // middle char is the space key -> keycode
        if case .unicode = steps[1] { XCTFail("space should be a keycode step") }
    }

    func testNewlineAndTabBecomeKeycodes() {
        let steps = TypeTextPlan.plan(for: "\n\t")
        XCTAssertEqual(steps.count, 2)
        for step in steps {
            if case .keycode = step { continue }
            XCTFail("newline/tab should be keycode steps, got \(step)")
        }
    }

    // MARK: emoji / accents -> single Unicode step per grapheme (C7)

    func testSingleEmojiIsOneUnicodeStep() {
        let steps = TypeTextPlan.plan(for: "😀")
        XCTAssertEqual(steps, [.unicode("😀")])
    }

    func testZWJFamilyEmojiIsOneUnicodeStep() {
        // ZWJ sequence: multiple scalars, one extended grapheme cluster.
        let family = "👨‍👩‍👧"
        XCTAssertGreaterThan(family.unicodeScalars.count, 1)
        let steps = TypeTextPlan.plan(for: family)
        XCTAssertEqual(steps, [.unicode(family)],
                       "a ZWJ emoji must be delivered as ONE unicode keystroke")
    }

    func testAccentedLetterIsUnicodeStep() {
        // 'é' is not a plain key combo -> unicode path.
        let steps = TypeTextPlan.plan(for: "é")
        XCTAssertEqual(steps, [.unicode("é")])
    }

    func testFlagEmojiIsOneUnicodeStep() {
        let flag = "🇺🇸" // two regional-indicator scalars, one grapheme
        XCTAssertEqual(flag.unicodeScalars.count, 2)
        XCTAssertEqual(TypeTextPlan.plan(for: flag), [.unicode(flag)])
    }

    // MARK: mixed sequence preserves order

    func testMixedSequenceKeepsOrderAndClassification() {
        let steps = TypeTextPlan.plan(for: "a😀")
        XCTAssertEqual(steps.count, 2)
        guard case .keycode = steps[0] else { return XCTFail("'a' should be keycode") }
        XCTAssertEqual(steps[1], .unicode("😀"))
    }

    func testEmptyTextYieldsNoSteps() {
        XCTAssertEqual(TypeTextPlan.plan(for: ""), [])
    }
}
