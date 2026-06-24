import XCTest
@testable import MacCUACore

final class SelectTextRangeTests: XCTestCase {
    func testUniqueMatch() {
        let r = SelectTextResolver.resolve(text: "hello world", target: "world")
        XCTAssertEqual(r, .resolved(TextRange(location: 6, length: 5)))
    }

    func testMatchAtStart() {
        let r = SelectTextResolver.resolve(text: "hello world", target: "hello")
        XCTAssertEqual(r, .resolved(TextRange(location: 0, length: 5)))
    }

    func testNotFound() {
        XCTAssertEqual(SelectTextResolver.resolve(text: "abc", target: "xyz"), .notFound)
    }

    func testTargetLongerThanText() {
        XCTAssertEqual(SelectTextResolver.resolve(text: "ab", target: "abc"), .notFound)
    }

    func testDuplicateNeedsDisambiguation() {
        let r = SelectTextResolver.resolve(text: "go go go", target: "go")
        XCTAssertEqual(r, .ambiguous(count: 3))
    }

    func testPrefixDisambiguates() {
        let r = SelectTextResolver.resolve(text: "red car, blue car", target: "car", prefix: "blue ")
        XCTAssertEqual(r, .resolved(TextRange(location: 14, length: 3)))
    }

    func testSuffixDisambiguates() {
        let r = SelectTextResolver.resolve(text: "car park, car wash", target: "car", suffix: " wash")
        XCTAssertEqual(r, .resolved(TextRange(location: 10, length: 3)))
    }

    func testPrefixAndSuffixTogether() {
        let r = SelectTextResolver.resolve(text: "a x b, c x b, a x d", target: "x", prefix: "c ", suffix: " b")
        XCTAssertEqual(r, .resolved(TextRange(location: 9, length: 1)))
    }

    func testPrefixNoMatchIsNotFound() {
        let r = SelectTextResolver.resolve(text: "red car", target: "car", prefix: "blue ")
        XCTAssertEqual(r, .notFound)
    }

    func testCaretBeforeIsZeroLengthAtStart() {
        let r = SelectTextResolver.resolve(text: "hello world", target: "world", caret: .before)
        XCTAssertEqual(r, .resolved(TextRange(location: 6, length: 0)))
    }

    func testCaretAfterIsZeroLengthAtEnd() {
        let r = SelectTextResolver.resolve(text: "hello world", target: "world", caret: .after)
        XCTAssertEqual(r, .resolved(TextRange(location: 11, length: 0)))
    }

    func testEmptyTargetIsZeroLengthCaret() {
        let r = SelectTextResolver.resolve(text: "hello", target: "")
        XCTAssertEqual(r, .resolved(TextRange(location: 0, length: 0)))
    }

    func testUTF16OffsetsWithEmoji() {
        // "👍" is 2 UTF-16 code units, so "ok" starts at offset 2.
        let r = SelectTextResolver.resolve(text: "👍ok", target: "ok")
        XCTAssertEqual(r, .resolved(TextRange(location: 2, length: 2)))
    }

    func testStillAmbiguousAfterPrefix() {
        let r = SelectTextResolver.resolve(text: "a x, a x, b x", target: "x", prefix: "a ")
        XCTAssertEqual(r, .ambiguous(count: 2))
    }
}
