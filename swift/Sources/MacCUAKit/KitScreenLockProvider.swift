// US-047 — Lock-screen guard (Kit impl).
//
// Real impl of the Core `ScreenLockProvider` seam. Reads the current login
// session dictionary via `CGSessionCopyCurrentDictionary()` and inspects the
// `CGSSessionScreenIsLocked` key (== 1 when the screen is locked). This is a
// pure read of session state — it NEVER foregrounds, activates, raises, or
// warps the cursor (Prime Invariant). When the dictionary or key is absent the
// probe reports "not locked" (fail-open on the probe); the input blocklist
// (Safety.swift) is a separate, always-on gate.

#if os(macOS)
import Foundation
import CoreGraphics
import MacCUACore

public final class KitScreenLockProvider: ScreenLockProvider {
    public init() {}

    public func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        // "CGSSessionScreenIsLocked" is present (== 1 / true) only while locked.
        if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
            return locked == 1
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return false
    }
}
#endif
