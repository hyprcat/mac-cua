// US-037 — Transport confirmation (pure tier).
//
// Ports the LISTEN-ONLY transport-confirmation logic from
// `app/_lib/delivery_tap.py` + `app/_lib/action_verification.py`:
//
//   * `CGEventTypeNumber` — the CGEventType raw values the confirmation tap sees
//     (mouse/key/scroll), kept as plain Ints so Core stays Linux-green (no
//     CoreGraphics import). The Kit tap maps these onto `CGEventType`.
//   * `CGEventSequenceExpectation` — the ordered/unordered event-sequence match
//     ported verbatim from `CGEventSequenceExpectation.matches`.
//   * `ObservedCGEvent` / `CGEventHistory` — the per-session ring buffer the
//     listen-only tap feeds. Pure (no lock/clock here — the Kit tap owns the
//     lock + the poll loop); `mark()`/`eventsSince`/`hasEventsSince` are the
//     transport-confirmation primitives.
//   * `CGEventExpectations` — the `expectation_for_*` builders.
//
// Transport ≠ outcome (Invariants 20–21): this only confirms the synthetic event
// echoed back through the session tap (matched by source-state-id, done in Kit).
// The fresh snapshot stays ground truth; `ActionVerifier.computeVerdict`
// (Verdict.swift) consumes the transport bool. Inline post-delivery AX
// verification stays disabled on the primary paths (Invariant 21).

import Foundation

/// CGEventType raw values (mirror of `app/_lib/event_tap.py` EVENT_* constants).
/// Plain Ints so Core does not import CoreGraphics; the Kit tap bridges to
/// `CGEventType(rawValue:)`.
public enum CGEventTypeNumber {
    public static let null = 0
    public static let leftMouseDown = 1
    public static let leftMouseUp = 2
    public static let rightMouseDown = 3
    public static let rightMouseUp = 4
    public static let mouseMoved = 5
    public static let leftMouseDragged = 6
    public static let rightMouseDragged = 7
    public static let keyDown = 10
    public static let keyUp = 11
    public static let flagsChanged = 12
    public static let scrollWheel = 22
    /// The set of input events the listen-only confirmation tap subscribes to.
    public static let allInputEvents: [Int] = [
        mouseMoved, leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp,
        leftMouseDragged, rightMouseDragged, keyDown, keyUp, flagsChanged,
        scrollWheel,
    ]
}

/// CGEventField number for the source state ID (the field the tap reads to tell
/// our synthetic events apart from real user input — Invariant 4/5). Mirrors
/// `CGEventFieldNumber.eventSourceStateID` (kept here for the verification
/// surface's locality).
public let kCGEventSourceStateIDField = CGEventFieldNumber.eventSourceStateID

/// A single event observed by the listen-only tap, tagged with a monotonic
/// sequence so `eventsSince(mark)` can window without timestamps.
public struct ObservedCGEvent: Equatable, Sendable {
    public let sequence: Int
    public let eventType: Int
    public init(sequence: Int, eventType: Int) {
        self.sequence = sequence
        self.eventType = eventType
    }
}

/// Ordered/unordered CGEvent-sequence match. Port of
/// `action_verification.CGEventSequenceExpectation.matches`.
public struct CGEventSequenceExpectation: Sendable, Equatable {
    public let eventTypes: [Int]
    public let ordered: Bool
    public let minimumMatches: Int?

    public init(_ eventTypes: [Int], ordered: Bool = true, minimumMatches: Int? = nil) {
        self.eventTypes = eventTypes
        self.ordered = ordered
        self.minimumMatches = minimumMatches
    }

    public func matches(_ events: [Int]) -> Bool {
        if eventTypes.isEmpty { return true }
        if ordered {
            var cursor = 0
            var matched = 0
            for event in events where event == eventTypes[cursor] {
                cursor += 1
                matched += 1
                if cursor == eventTypes.count {
                    if let minimum = minimumMatches { return matched >= minimum }
                    return true
                }
            }
            return false
        }
        let required = minimumMatches ?? eventTypes.count
        let matched = events.filter { eventTypes.contains($0) }.count
        return matched >= required
    }
}

/// Per-session ring buffer fed by the listen-only confirmation tap. Pure: the
/// Kit `KitOutcomeMonitor` wraps every call in a lock and owns the poll loop.
/// Port of the history half of `CGEventOutcomeMonitor`.
public final class CGEventHistory {
    private let historyLimit: Int
    private var events: [ObservedCGEvent] = []
    private var sequence = 0

    public init(historyLimit: Int = 256) {
        self.historyLimit = max(1, historyLimit)
    }

    /// Record one observed event, returning its assigned sequence. The tap calls
    /// this only for events already filtered to our source-state-id.
    @discardableResult
    public func record(eventType: Int) -> Int {
        sequence += 1
        events.append(ObservedCGEvent(sequence: sequence, eventType: eventType))
        if events.count > historyLimit {
            events.removeFirst(events.count - historyLimit)
        }
        return sequence
    }

    /// Current sequence high-water mark — capture this *before* posting an event.
    public func mark() -> Int { sequence }

    /// Events recorded strictly after `since`.
    public func eventsSince(_ since: Int) -> [ObservedCGEvent] {
        events.filter { $0.sequence > since }
    }

    /// Any event observed since the mark (the simple delivery-confirmation gate,
    /// `DeliveryConfirmationTap`: a source-matched echo means transport happened).
    public func hasEventsSince(_ since: Int) -> Bool {
        events.contains { $0.sequence > since }
    }

    /// Whether the events since the mark satisfy the expectation (the richer
    /// `CGEventOutcomeMonitor.verify_transport` check, sans the time loop).
    public func matches(since: Int, expectation: CGEventSequenceExpectation) -> Bool {
        expectation.matches(eventsSince(since).map { $0.eventType })
    }

    public func clear() {
        events.removeAll(keepingCapacity: true)
        sequence = 0
    }
}

/// Per-action expectation builders. Port of the `expectation_for_*` helpers.
public enum CGEventExpectations {
    public static func click(button: String, count: Int) -> CGEventSequenceExpectation {
        let down = button == "right" ? CGEventTypeNumber.rightMouseDown : CGEventTypeNumber.leftMouseDown
        let up = button == "right" ? CGEventTypeNumber.rightMouseUp : CGEventTypeNumber.leftMouseUp
        var types: [Int] = []
        for _ in 0..<max(1, count) { types.append(contentsOf: [down, up]) }
        return CGEventSequenceExpectation(types, ordered: true)
    }

    public static func drag() -> CGEventSequenceExpectation {
        CGEventSequenceExpectation(
            [CGEventTypeNumber.leftMouseDown, CGEventTypeNumber.leftMouseDragged, CGEventTypeNumber.leftMouseUp],
            ordered: true)
    }

    public static func keypress() -> CGEventSequenceExpectation {
        CGEventSequenceExpectation([CGEventTypeNumber.keyDown, CGEventTypeNumber.keyUp], ordered: true)
    }

    public static func typing() -> CGEventSequenceExpectation {
        CGEventSequenceExpectation(
            [CGEventTypeNumber.keyDown, CGEventTypeNumber.keyUp], ordered: false, minimumMatches: 2)
    }

    public static func scroll() -> CGEventSequenceExpectation {
        CGEventSequenceExpectation([CGEventTypeNumber.scrollWheel], ordered: true)
    }
}
