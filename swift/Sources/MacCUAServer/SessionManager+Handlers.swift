import Foundation
import MacCUACore

// ACTION HANDLERS — the 8 tools' delivery logic + their click/scroll/input/
// verification helpers. Each handler returns a success string or throws an
// `AutomationError`; the spine's execute() turns that into a snapshot response.
//
// STATUS: STUB. The handler sub-agent replaces this whole file with the faithful
// port of `_handle_*` and helpers from `app/session.py` (2689-3672), honoring
// the InputStrategy AX-first/pointer-first order and Invariants 1-6, 9, 20-21.
// These helpers are self-contained (they call only `resolveIndex` from the
// spine); keep all click/scroll/visibility/verification helpers in THIS file.

extension SessionManager {

    func handleClick(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handleClick")
    }

    func handleTypeText(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handleTypeText")
    }

    func handleSetValue(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handleSetValue")
    }

    func handlePressKey(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handlePressKey")
    }

    func handleScroll(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handleScroll")
    }

    func handleDrag(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handleDrag")
    }

    func handleSecondaryAction(_ session: AppSession, _ params: [String: Any]) throws -> String {
        fatalError("unimplemented: handleSecondaryAction")
    }
}
