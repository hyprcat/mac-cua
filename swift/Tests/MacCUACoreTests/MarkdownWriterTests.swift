import XCTest
@testable import MacCUACore

// Covers app/_lib/markdown_writer.py (AttributedStringMarkdownWriter assembly,
// font-trait/list parsing) and app/_lib/selection.py::format_selection.
// Golden expectations captured from the Python apply-order.

final class MarkdownWriterTests: XCTestCase {

    func testPlainRun() {
        XCTAssertEqual(MarkdownWriter.write(runs: [AttributedRun(text: "hello")]), "hello")
    }

    func testEmptyRunUntouched() {
        XCTAssertEqual(MarkdownWriter.applyAttributes(AttributedRun(text: "", bold: true)), "")
    }

    func testBold() {
        XCTAssertEqual(MarkdownWriter.write(runs: [AttributedRun(text: "x", bold: true)]), "**x**")
    }

    func testItalic() {
        XCTAssertEqual(MarkdownWriter.write(runs: [AttributedRun(text: "x", italic: true)]), "*x*")
    }

    func testBoldItalic() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "x", bold: true, italic: true)]),
            "***x***")
    }

    func testLink() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "click", link: "https://a.com")]),
            "[click](https://a.com)")
    }

    func testLinkEqualToTextSkipped() {
        // Python: skips wrapping when url == result.
        let r = AttributedRun(text: "https://a.com", link: "https://a.com")
        XCTAssertEqual(MarkdownWriter.write(runs: [r]), "https://a.com")
    }

    func testLinkThenBoldNesting() {
        // Order: link first, then bold wraps the linked result.
        let r = AttributedRun(text: "go", link: "u", bold: true)
        XCTAssertEqual(MarkdownWriter.write(runs: [r]), "**[go](u)**")
    }

    func testHeading() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "Title", headingLevel: 2)]),
            "## Title")
    }

    func testHeadingOutOfRangeIgnored() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "T", headingLevel: 7)]), "T")
    }

    func testMonospaceInline() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "code", monospace: true)]), "`code`")
    }

    func testMonospaceBlock() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "a\nb", monospace: true)]),
            "```\na\nb\n```")
    }

    func testOrderedList() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "item", listStyle: "NSTextListOrdered")]),
            "1. item")
    }

    func testUnorderedList() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "item", listStyle: "bullet-disc")]),
            "- item")
    }

    func testUnknownListStyleUntouched() {
        XCTAssertEqual(
            MarkdownWriter.write(runs: [AttributedRun(text: "item", listStyle: "weird")]), "item")
    }

    func testFullSequenceJoined() {
        let runs = [
            AttributedRun(text: "Hello "),
            AttributedRun(text: "bold", bold: true),
            AttributedRun(text: " and "),
            AttributedRun(text: "link", link: "http://x"),
        ]
        XCTAssertEqual(MarkdownWriter.write(runs: runs), "Hello **bold** and [link](http://x)")
    }

    // MARK: font helpers

    func testExtractFontTraits() {
        XCTAssertEqual(extractFontTraits(fontName: "Helvetica-BoldOblique").bold, true)
        XCTAssertEqual(extractFontTraits(fontName: "Helvetica-BoldOblique").italic, true)
        XCTAssertEqual(extractFontTraits(fontName: "Helvetica").bold, false)
        XCTAssertEqual(extractFontTraits(fontName: nil).italic, false)
    }

    func testIsMonospaceFont() {
        XCTAssertTrue(isMonospaceFont(fontName: "Menlo-Regular"))
        XCTAssertTrue(isMonospaceFont(fontName: "Courier"))
        XCTAssertFalse(isMonospaceFont(fontName: "Helvetica"))
        XCTAssertFalse(isMonospaceFont(fontName: nil))
    }

    // MARK: format_selection

    func testFormatSelection() {
        XCTAssertEqual(formatSelection("hi"), "Selected text: ```\nhi\n```")
    }

    func testFormatSelectionEmptyNil() {
        XCTAssertNil(formatSelection(""))
        XCTAssertNil(formatSelection(nil))
    }
}
