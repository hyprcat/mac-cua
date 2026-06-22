import XCTest
@testable import MacCUACore

// Covers app/_lib/errors.py: the ax_error factory, AX_ERROR_MESSAGES mapping,
// stale-reference promotion, the reason-code constants, and subtype checks.

final class ErrorsTests: XCTestCase {

    func testAxErrorKnownCode() {
        let err = axError(-25204)
        XCTAssertEqual(err.kind, .ax)
        XCTAssertEqual(err.message, "attribute unsupported")
        XCTAssertEqual(err.code, -25204)
    }

    func testAxErrorUnknownCode() {
        let err = axError(-99999)
        XCTAssertEqual(err.kind, .ax)
        XCTAssertEqual(err.message, "unknown AX error -99999")
    }

    func testAxErrorWithContext() {
        let err = axError(-25206, context: "press")
        XCTAssertEqual(err.message, "press: action unsupported")
        XCTAssertEqual(err.code, -25206)
    }

    func testStaleReferencePromotion() {
        for code in [-25205, -25212] {
            let err = axError(code)
            XCTAssertEqual(err.kind, .staleReference, "code \(code) should be stale")
            XCTAssertTrue(err.isAXError, "StaleReferenceError isa AXError")
        }
    }

    func testNonStaleCodesStayAX() {
        let err = axError(-25201)
        XCTAssertEqual(err.kind, .ax)
        XCTAssertNotEqual(err.kind, .staleReference)
    }

    func testAxErrorMessagesMapping() {
        XCTAssertEqual(axErrorMessages[-25200], "invalid argument")
        XCTAssertEqual(axErrorMessages[-25210], "API disabled")
        XCTAssertEqual(axErrorMessages[-10005], "noWindowsAvailable / cannotClickOffscreenElement")
        XCTAssertEqual(axErrorMessages.count, 12)
    }

    func testReasonCodeConstants() {
        XCTAssertEqual(KeyPressError.multipleNonModifierKeys, "multiple_non_modifier_keys")
        XCTAssertEqual(KeyPressError.noNonModifierKeys, "no_non_modifier_keys")
        XCTAssertEqual(KeyPressError.failedToTranslate, "unknown_key")
        XCTAssertEqual(CGEventError.failedToCreate, "cg_event_creation_failed")
        XCTAssertEqual(RefetchError.noInvalidationMonitor, "no_monitor")
        XCTAssertEqual(RefetchError.ambiguousBefore, "ambiguous_before_refetch")
        XCTAssertEqual(RefetchError.ambiguousAfter, "ambiguous_after_refetch")
        XCTAssertEqual(RefetchError.notFound, "not_found_after_refetch")
        XCTAssertEqual(SafetyError.appBlocked, "app_blocked_for_safety")
        XCTAssertEqual(SafetyError.urlBlocked, "url_blocked_for_safety")
        XCTAssertEqual(SafetyError.privateIPBlocked, "private_ip_address_blocked")
    }

    func testSubtypeChecks() {
        XCTAssertTrue(AutomationError.input("x").isInputError)
        XCTAssertTrue(AutomationError.keyPress("x").isInputError)
        XCTAssertTrue(AutomationError.cgEvent("x").isInputError)
        XCTAssertFalse(AutomationError.ax("x").isInputError)

        XCTAssertTrue(AutomationError.safety("x").isSafetyError)
        XCTAssertTrue(AutomationError.appBlocked("x").isSafetyError)
        XCTAssertFalse(AutomationError.focus("x").isSafetyError)
    }

    func testErrorCarriesMessageAndCode() {
        let err = AutomationError.automation("boom", code: 7)
        XCTAssertEqual(err.message, "boom")
        XCTAssertEqual(err.description, "boom")
        XCTAssertEqual(err.code, 7)
        XCTAssertNil(AutomationError.automation("no code").code)
    }

    func testKindPreservesPythonClassName() {
        XCTAssertEqual(AutomationError.staleReference("x").kind.rawValue, "StaleReferenceError")
        XCTAssertEqual(AutomationError.appBlocked("x").kind.rawValue, "AppBlockedError")
        XCTAssertEqual(AutomationError.stepLimit("x").kind.rawValue, "StepLimitError")
    }

    func testThrowsAndCatches() {
        func failing() throws { throw axError(-25205, context: "click") }
        XCTAssertThrowsError(try failing()) { error in
            guard let e = error as? AutomationError else { return XCTFail("wrong type") }
            XCTAssertEqual(e.kind, .staleReference)
            XCTAssertEqual(e.message, "click: invalid UI element")
        }
    }
}
