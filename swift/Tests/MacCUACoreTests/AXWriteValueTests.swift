import XCTest
@testable import MacCUACore

final class AXWriteValueTests: XCTestCase {
    func testDefaultIsString() {
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXValue", value: "hello"),
            .string("hello"))
    }

    func testNumericStringStaysString() {
        // Matches Python's pass-through: a text field whose value is "123" must
        // not be coerced to a number.
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXValue", value: "123"),
            .string("123"))
    }

    func testBooleanTrueVariants() {
        for v in ["true", "TRUE", "1", "yes", "Y", "on", " True "] {
            XCTAssertEqual(
                AXAttributeWrite.classify(attr: "AXFocused", value: v),
                .boolean(true), "value \(v)")
        }
    }

    func testBooleanFalseVariants() {
        for v in ["false", "0", "no", "", "anything"] {
            XCTAssertEqual(
                AXAttributeWrite.classify(attr: "AXSelected", value: v),
                .boolean(false), "value \(v)")
        }
    }

    func testAllBooleanAttributes() {
        for attr in AXAttributeWrite.booleanAttributes {
            if case .boolean = AXAttributeWrite.classify(attr: attr, value: "true") { continue }
            XCTFail("\(attr) should classify boolean")
        }
    }

    func testRangeComma() {
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXSelectedTextRange", value: "5,10"),
            .range(location: 5, length: 10))
    }

    func testRangeColonAndSpace() {
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXSelectedTextRange", value: "3:0"),
            .range(location: 3, length: 0))
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXVisibleCharacterRange", value: " 7 4 "),
            .range(location: 7, length: 4))
    }

    func testCaretZeroLengthRange() {
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXSelectedTextRange", value: "12,0"),
            .range(location: 12, length: 0))
    }

    func testUnparseableRangeFallsBackToString() {
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXSelectedTextRange", value: "not-a-range"),
            .string("not-a-range"))
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXSelectedTextRange", value: "1,2,3"),
            .string("1,2,3"))
        XCTAssertEqual(
            AXAttributeWrite.classify(attr: "AXSelectedTextRange", value: "-1,2"),
            .string("-1,2"))
    }
}
