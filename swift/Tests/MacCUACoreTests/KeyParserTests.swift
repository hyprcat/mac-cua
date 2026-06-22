import XCTest
@testable import MacCUACore

// Ports tests/test_keys_modifiers.py and adds coverage for the keycode tables,
// modifier bit math, and the combo parser (all pure logic from keys.py).

final class KeyParserTests: XCTestCase {

    // Local copies of the masks, asserted independently against the parser's
    // public constants so the bit math is pinned exactly to Python's values.
    private let maskShift = 1 << 17
    private let maskControl = 1 << 18
    private let maskAlternate = 1 << 19
    private let maskCommand = 1 << 20

    // MARK: - Modifier mask bit values

    func testModifierMaskBitValues() {
        XCTAssertEqual(KeyParser.maskShift, 1 << 17)
        XCTAssertEqual(KeyParser.maskControl, 1 << 18)
        XCTAssertEqual(KeyParser.maskAlternate, 1 << 19)
        XCTAssertEqual(KeyParser.maskCommand, 1 << 20)
        // Concrete integer values
        XCTAssertEqual(KeyParser.maskShift, 131072)
        XCTAssertEqual(KeyParser.maskControl, 262144)
        XCTAssertEqual(KeyParser.maskAlternate, 524288)
        XCTAssertEqual(KeyParser.maskCommand, 1048576)
    }

    // MARK: - decomposeModifierSequence (ported from test_keys_modifiers.py)

    func testEmptyMaskReturnsEmptyList() {
        let result = KeyParser.decomposeModifierSequence(0)
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleModifierShift() {
        let result = KeyParser.decomposeModifierSequence(maskShift)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].keycode, 56) // shift keycode
        XCTAssertEqual(result[0].cumulativeFlags, maskShift)
    }

    func testSingleModifierCommand() {
        let result = KeyParser.decomposeModifierSequence(maskCommand)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].keycode, 55) // cmd keycode
        XCTAssertEqual(result[0].cumulativeFlags, maskCommand)
    }

    func testTwoModifiersShiftCmdReturnsOrderedWithCumulativeFlags() {
        let mask = maskShift | maskCommand
        let result = KeyParser.decomposeModifierSequence(mask)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].keycode, 56)
        XCTAssertEqual(result[0].cumulativeFlags, maskShift)
        XCTAssertEqual(result[1].keycode, 55)
        XCTAssertEqual(result[1].cumulativeFlags, maskShift | maskCommand)
    }

    func testThreeModifiersCtrlShiftCmd() {
        let mask = maskShift | maskControl | maskCommand
        let result = KeyParser.decomposeModifierSequence(mask)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].keycode, 56)
        XCTAssertEqual(result[0].cumulativeFlags, maskShift)
        XCTAssertEqual(result[1].keycode, 59)
        XCTAssertEqual(result[1].cumulativeFlags, maskShift | maskControl)
        XCTAssertEqual(result[2].keycode, 55)
        XCTAssertEqual(result[2].cumulativeFlags, maskShift | maskControl | maskCommand)
    }

    func testAllFourModifiers() {
        let mask = maskShift | maskControl | maskAlternate | maskCommand
        let result = KeyParser.decomposeModifierSequence(mask)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].keycode, 56) // shift
        XCTAssertEqual(result[1].keycode, 59) // control
        XCTAssertEqual(result[2].keycode, 58) // alt
        XCTAssertEqual(result[3].keycode, 55) // cmd
        XCTAssertEqual(result[3].cumulativeFlags, mask)
    }

    // MARK: - modifierKeycodes (canonical table order)

    func testModifierKeycodesEmpty() {
        XCTAssertTrue(KeyParser.modifierKeycodes(0).isEmpty)
    }

    func testModifierKeycodesCanonicalOrder() {
        // Table order is command, shift, alternate, control.
        let mask = maskShift | maskControl | maskAlternate | maskCommand
        let result = KeyParser.modifierKeycodes(mask)
        XCTAssertEqual(result.map { $0.keycode }, [55, 56, 58, 59])
        XCTAssertEqual(result.map { $0.flag }, [maskCommand, maskShift, maskAlternate, maskControl])
    }

    func testModifierKeycodesSubset() {
        let result = KeyParser.modifierKeycodes(maskControl | maskCommand)
        // command comes before control in table order
        XCTAssertEqual(result.map { $0.keycode }, [55, 59])
    }

    // MARK: - parseKeyCombo: modifiers

    func testParseSuperShiftC() throws {
        let (keycode, mask) = try KeyParser.parseKeyCombo("super+shift+c")
        XCTAssertEqual(keycode, 8) // 'c'
        XCTAssertEqual(mask, maskCommand | maskShift)
    }

    func testParseReturn() throws {
        let (keycode, mask) = try KeyParser.parseKeyCombo("Return")
        XCTAssertEqual(keycode, 36)
        XCTAssertEqual(mask, 0)
    }

    func testParseUppercaseLetterAutoShifts() throws {
        let (keycode, mask) = try KeyParser.parseKeyCombo("C")
        XCTAssertEqual(keycode, 8)
        XCTAssertEqual(mask, maskShift)
    }

    func testParseLowercaseLetterNoShift() throws {
        let (keycode, mask) = try KeyParser.parseKeyCombo("a")
        XCTAssertEqual(keycode, 0)
        XCTAssertEqual(mask, 0)
    }

    func testAllModifierAliases() throws {
        // Aliases that map to command
        for alias in ["super", "cmd", "command"] {
            let (_, mask) = try KeyParser.parseKeyCombo("\(alias)+a")
            XCTAssertEqual(mask, maskCommand, "alias \(alias)")
        }
        for alias in ["alt", "opt", "option"] {
            let (_, mask) = try KeyParser.parseKeyCombo("\(alias)+a")
            XCTAssertEqual(mask, maskAlternate, "alias \(alias)")
        }
        for alias in ["ctrl", "control"] {
            let (_, mask) = try KeyParser.parseKeyCombo("\(alias)+a")
            XCTAssertEqual(mask, maskControl, "alias \(alias)")
        }
        let (_, shiftMask) = try KeyParser.parseKeyCombo("shift+a")
        XCTAssertEqual(shiftMask, maskShift)
    }

    func testModifierCaseInsensitive() throws {
        let (keycode, mask) = try KeyParser.parseKeyCombo("CMD+Shift+A")
        XCTAssertEqual(keycode, 0) // 'a'
        // uppercase A auto-shifts too, but shift already set -> idempotent OR
        XCTAssertEqual(mask, maskCommand | maskShift)
    }

    func testWhitespaceAroundPartsIsStripped() throws {
        let (keycode, mask) = try KeyParser.parseKeyCombo(" cmd + c ")
        XCTAssertEqual(keycode, 8)
        XCTAssertEqual(mask, maskCommand)
    }

    // MARK: - parseKeyCombo: shifted symbols carry extra flag

    func testShiftedSymbolCarriesShiftFlag() throws {
        // "_" registered as keycode 27 with shift flag
        let (keycode, mask) = try KeyParser.parseKeyCombo("_")
        XCTAssertEqual(keycode, 27)
        XCTAssertEqual(mask, maskShift)
    }

    func testShiftedDigitSymbol() throws {
        // "!" maps to digit '1' keycode with shift
        let (keycode, mask) = try KeyParser.parseKeyCombo("!")
        XCTAssertEqual(keycode, 18)
        XCTAssertEqual(mask, maskShift)
    }

    func testPlusSymbolViaModifierBoundary() throws {
        // A lone "+" splits into ["", ""] -> both empty -> no key. But "shift++"
        // would be modifier + the "+" key. Verify the "=" / "+" keycode mapping
        // through its named alias to avoid the split ambiguity.
        let (keycode, mask) = try KeyParser.parseKeyCombo("equal")
        XCTAssertEqual(keycode, 24)
        XCTAssertEqual(mask, 0)
    }

    // MARK: - Keycode table spot checks

    func testLetterKeycodeTable() throws {
        // Alphabetical-order keycodes from keys.py _LETTER_CODES
        let expected: [Character: Int] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
            "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
            "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
            "w": 13, "x": 7, "y": 16, "z": 6,
        ]
        for (ch, code) in expected {
            let (keycode, mask) = try KeyParser.parseKeyCombo(String(ch))
            XCTAssertEqual(keycode, code, "letter \(ch)")
            XCTAssertEqual(mask, 0, "letter \(ch) mask")
        }
    }

    func testDigitKeycodeTable() throws {
        let expected = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, code) in expected.enumerated() {
            let (keycode, _) = try KeyParser.parseKeyCombo(String(i))
            XCTAssertEqual(keycode, code, "digit \(i)")
        }
    }

    func testFunctionKeyTable() throws {
        let f1to12 = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in f1to12.enumerated() {
            let (keycode, _) = try KeyParser.parseKeyCombo("f\(i + 1)")
            XCTAssertEqual(keycode, code, "f\(i + 1)")
        }
        let f13to20 = [105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in f13to20.enumerated() {
            let (keycode, _) = try KeyParser.parseKeyCombo("f\(i + 13)")
            XCTAssertEqual(keycode, code, "f\(i + 13)")
        }
    }

    func testNavigationKeyAliases() throws {
        let cases: [(String, Int)] = [
            ("return", 36), ("enter", 36), ("tab", 48), ("space", 49),
            ("backspace", 51), ("delete", 51), ("back_space", 51),
            ("escape", 53), ("esc", 53),
            ("left", 123), ("right", 124), ("down", 125), ("up", 126),
            ("home", 115), ("end", 119),
            ("page_up", 116), ("pageup", 116), ("prior", 116),
            ("page_down", 121), ("pagedown", 121), ("next", 121),
            ("forwarddelete", 117), ("forward_delete", 117),
        ]
        for (name, code) in cases {
            let (keycode, _) = try KeyParser.parseKeyCombo(name)
            XCTAssertEqual(keycode, code, name)
        }
    }

    func testKeypadTable() throws {
        let kp = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (i, code) in kp.enumerated() {
            let (keycode, _) = try KeyParser.parseKeyCombo("kp_\(i)")
            XCTAssertEqual(keycode, code, "kp_\(i)")
        }
        let named: [(String, Int)] = [
            ("kp_decimal", 65), ("kp_period", 65), ("kp_multiply", 67),
            ("kp_add", 69), ("kp_subtract", 78), ("kp_divide", 75), ("kp_enter", 76),
        ]
        for (name, code) in named {
            let (keycode, _) = try KeyParser.parseKeyCombo(name)
            XCTAssertEqual(keycode, code, name)
        }
    }

    func testMediaKeys() throws {
        let cases: [(String, Int)] = [
            ("volumeup", 72), ("volume_up", 72),
            ("volumedown", 73), ("volume_down", 73), ("mute", 74),
        ]
        for (name, code) in cases {
            let (keycode, _) = try KeyParser.parseKeyCombo(name)
            XCTAssertEqual(keycode, code, name)
        }
    }

    // MARK: - parseKeyCombo: error cases

    func testMultipleNonModifierKeysThrows() {
        XCTAssertThrowsError(try KeyParser.parseKeyCombo("a+b")) { error in
            guard case let KeyParseError.multipleNonModifierKeys(first, second, combo) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(first, "a")
            XCTAssertEqual(second, "b")
            XCTAssertEqual(combo, "a+b")
        }
    }

    func testOnlyModifiersThrows() {
        XCTAssertThrowsError(try KeyParser.parseKeyCombo("cmd+shift")) { error in
            guard case let KeyParseError.noNonModifierKeys(combo) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(combo, "cmd+shift")
        }
    }

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try KeyParser.parseKeyCombo("cmd+nope")) { error in
            guard case let KeyParseError.unknownKey(name, combo) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(name, "nope")
            XCTAssertEqual(combo, "cmd+nope")
        }
    }

    func testEmptyComboThrowsNoNonModifier() {
        // "" splits into [""], stripped empty -> no key found
        XCTAssertThrowsError(try KeyParser.parseKeyCombo("")) { error in
            guard case KeyParseError.noNonModifierKeys = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
