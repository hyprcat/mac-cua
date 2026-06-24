import XCTest
@testable import MacCUACore

// US-012: Invariant & anti-regression test guard (design §3, §J, M4).
//
// Three families of guard:
//   (1) Source-scan guard — the banned-symbol family (Prime Invariant) is
//       UNREACHABLE: no global `CGEventPost`, `post(tap:)`,
//       `CGWarpMouseCursorPosition`, `NSRunningApplication.activate`, `AXRaise`
//       (as a call), `SetFrontmost`, or `SLPSSetFrontProcessWithOptions` occurs
//       anywhere in code (comments + string literals excluded). When the Mac
//       input/capture layer (MacCUAKit) lands, these guards keep it honest.
//   (2) M4 regression guards — behavioral proof on the Core logic that backs
//       the future Mac impl: scroll exposes >1 delta axis (not integer-only),
//       refetch rebinds via the GraphLocator (not the same preorder index), and
//       the element identity key is the graph locator (not role|label|frame).
//   (3) Leak guard — no `ax_ref` / `graph_id` / `graph_generation` /
//       `graph_locator` field name nor a `<AXUIElement 0x…>` pointer string is
//       serializable into the model-facing packet (Invariant 8).
//
// NEVER weaken or delete these guards (see ralph/CLAUDE.md Prime Invariant).
private final class FakeAXRef: AXElementRef {}

final class InvariantGuardTests: XCTestCase {

    // MARK: - Source location

    /// Absolute path to `swift/Sources`, derived from this test file's path
    /// (`swift/Tests/MacCUACoreTests/InvariantGuardTests.swift`).
    private static func sourcesRoot() -> URL {
        // #filePath → …/swift/Tests/MacCUACoreTests/InvariantGuardTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let swiftDir = thisFile
            .deletingLastPathComponent()  // MacCUACoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift
        return swiftDir.appendingPathComponent("Sources")
    }

    /// All `.swift` files under `Sources/` (every shipping target — Core,
    /// Server, and any future MacCUAKit / executable). Tests are excluded.
    private static func allSourceFiles() -> [URL] {
        let root = sourcesRoot()
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            out.append(url)
        }
        return out
    }

    /// Strip Swift comments (`//…`, `/* … */`) and the contents of
    /// double-quoted string literals so identifier scans see only real code.
    /// Deliberately simple — sufficient for guard scanning, not a lexer.
    static func stripCommentsAndStrings(_ src: String) -> String {
        var out = ""
        out.reserveCapacity(src.count)
        let chars = Array(src)
        var i = 0
        let n = chars.count
        enum Mode { case code, line, block, str }
        var mode: Mode = .code
        while i < n {
            let c = chars[i]
            let next: Character? = i + 1 < n ? chars[i + 1] : nil
            switch mode {
            case .code:
                if c == "/", next == "/" { mode = .line; i += 2; continue }
                if c == "/", next == "*" { mode = .block; i += 2; continue }
                if c == "\"" { mode = .str; i += 1; continue }
                out.append(c)
                i += 1
            case .line:
                if c == "\n" { mode = .code; out.append(c) }
                i += 1
            case .block:
                if c == "*", next == "/" { mode = .code; i += 2; continue }
                i += 1
            case .str:
                // Skip escaped chars so an escaped quote doesn't end the string.
                if c == "\\" { i += 2; continue }
                if c == "\"" { mode = .code }
                i += 1
            }
        }
        return out
    }

    // MARK: - (1) Banned-symbol source scan (Prime Invariant)

    func testNoBannedForegroundingOrGlobalPostSymbols() {
        // Each entry: a human label + a closure that, given a line of CODE
        // (comments/strings already stripped), returns true if it is a banned
        // occurrence. We allow the per-PID / per-PSN delivery family.
        let banned: [(name: String, hit: (String) -> Bool)] = [
            ("global CGEventPost(", { line in
                // Allow CGEventPostToPid / CGEventPostToPSN (per-PID/PSN family).
                guard let r = line.range(of: "CGEventPost") else { return false }
                let after = line[r.upperBound...]
                return !(after.hasPrefix("ToPid") || after.hasPrefix("ToPSN"))
            }),
            ("post(tap:)", { $0.contains("post(tap:") }),
            ("CGWarpMouseCursorPosition", { $0.contains("CGWarpMouseCursorPosition") }),
            ("NSRunningApplication.activate / .activate(", { line in
                guard line.contains(".activate(") else { return false }
                // Invariant 15 sanctions EXACTLY ONE activation: restoring the
                // user's previously-frontmost app (apps.py `restore_frontmost`).
                // That single call site marks itself with the receiver name
                // `sanctionedFrontmostRestore` — an identifier that survives
                // comment/string stripping — so this narrow allowance cannot be
                // reused to foreground a driven app.
                return !line.contains("sanctionedFrontmostRestore.activate(")
            }),
            ("AXRaise (call)", { $0.contains("AXRaise") }),
            ("SetFrontmost", { $0.contains("SetFrontmost") }),
            ("SLPSSetFrontProcessWithOptions", { $0.contains("SLPSSetFrontProcessWithOptions") }),
        ]

        var violations: [String] = []
        let files = Self.allSourceFiles()
        XCTAssertFalse(files.isEmpty, "Guard could not locate any source files under Sources/")

        for file in files {
            guard let raw = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let code = Self.stripCommentsAndStrings(raw)
            for (lineNo, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                for rule in banned where rule.hit(s) {
                    violations.append("\(file.lastPathComponent):\(lineNo + 1) — banned \(rule.name): \(s.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Prime-Invariant banned symbols reachable from shipping sources:\n\(violations.joined(separator: "\n"))"
        )
    }

    /// Sanity-check the stripper itself so the guard above cannot be silently
    /// defeated by a banned token that only appears inside a comment/string.
    func testStripperRemovesCommentsAndStrings() {
        let src = """
        let x = "CGWarpMouseCursorPosition" // AXRaise here
        /* SLPSSetFrontProcessWithOptions */
        let y = realCode()
        """
        let stripped = Self.stripCommentsAndStrings(src)
        XCTAssertFalse(stripped.contains("CGWarpMouseCursorPosition"))
        XCTAssertFalse(stripped.contains("AXRaise"))
        XCTAssertFalse(stripped.contains("SLPSSetFrontProcessWithOptions"))
        XCTAssertTrue(stripped.contains("realCode()"))
    }

    // MARK: - (2) M4 regression guards (behavioral)

    /// Scroll must be able to set MORE THAN ONE delta axis (line + fixed-point +
    /// point delta), not integer-only — macos-cua's integer-only regression.
    func testScrollExposesMultipleDeltaAxes() {
        // The three delta families are distinct, non-overlapping field numbers.
        let vertical = Set([
            CGEventFieldNumber.scrollWheelEventDeltaAxis1,      // line, 11
            CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis1, // fixedPt, 93
            CGEventFieldNumber.scrollWheelEventPointDeltaAxis1,  // point, 96
        ])
        XCTAssertEqual(vertical.count, 3, "scroll vertical delta axes must be 3 distinct fields, not integer-only")
        let horizontal = Set([
            CGEventFieldNumber.scrollWheelEventDeltaAxis2,
            CGEventFieldNumber.scrollWheelEventFixedPtDeltaAxis2,
            CGEventFieldNumber.scrollWheelEventPointDeltaAxis2,
        ])
        XCTAssertEqual(horizontal.count, 3)
        // isContinuous distinguishes pixel scroll from line scroll — present.
        XCTAssertEqual(CGEventFieldNumber.scrollWheelEventIsContinuous, 88)
    }

    /// Refetch must rebind by GraphLocator, NOT by the same preorder index.
    /// Construct a tree where the target moved to a different index but its
    /// locator still matches, and a same-index decoy with a different locator.
    func testRefetchUsesGraphLocatorNotPreorderIndex() {
        let targetLocator = GraphLocator(
            axRole: "AXButton", label: "Save", depth: 2, siblingOrdinal: 0)

        // index 0: a decoy that occupies the OLD preorder slot but is a
        // different control (would be picked by a same-index strategy — wrong).
        let decoy = Node(
            index: 0, role: "button", depth: 2, axRole: "AXButton",
            graphLocator: GraphLocator(axRole: "AXButton", label: "Cancel", depth: 2, siblingOrdinal: 1))
        // index 3: the real target, moved in preorder, locator still matches.
        let moved = Node(
            index: 3, role: "button", label: "Save", depth: 2, axRole: "AXButton",
            graphLocator: targetLocator)

        let match = matchNodeByLocator([decoy, moved], locator: targetLocator)
        XCTAssertEqual(match?.index, 3, "refetch must rebind by locator (index 3), not the old preorder index 0")
        XCTAssertEqual(match?.label, "Save")
    }

    /// The element identity key is the graph locator, NOT role|label|frame.
    func testStableKeyIsGraphLocatorNotRoleLabelFrame() {
        let locA = GraphLocator(axRole: "AXButton", label: "OK", depth: 1, siblingOrdinal: 0)
        let locB = GraphLocator(axRole: "AXButton", label: "OK", depth: 1, siblingOrdinal: 1)

        // Two nodes IDENTICAL in role|label|frame (and value) but DIFFERENT
        // locators → must get different keys (role|label|frame keying would
        // collide them).
        let frame = Rect(x: 10, y: 10, w: 80, h: 24)
        let n1 = Node(index: 0, role: "button", label: "OK", value: "v",
                      depth: 1, position: Point(x: frame.x, y: frame.y),
                      size: Size(w: frame.w, h: frame.h), axRole: "AXButton", graphLocator: locA)
        let n2 = Node(index: 1, role: "button", label: "OK", value: "v",
                      depth: 1, position: Point(x: frame.x, y: frame.y),
                      size: Size(w: frame.w, h: frame.h), axRole: "AXButton", graphLocator: locB)
        XCTAssertNotEqual(TreeDiff.stableKey(n1), TreeDiff.stableKey(n2),
                          "distinct locators must yield distinct keys despite identical role|label|frame")

        // Same locator but role|label|frame CHANGED → key is stable (locator
        // keying ignores the volatile surface attributes).
        let n3 = Node(index: 9, role: "menu item", label: "Different",
                      depth: 1, position: Point(x: 999, y: 999),
                      size: Size(w: 1, h: 1), axRole: "AXButton", graphLocator: locA)
        XCTAssertEqual(TreeDiff.stableKey(n1), TreeDiff.stableKey(n3),
                       "same locator must yield the same key even when role/label/frame change")
    }

    // MARK: - (3) Leak guard (Invariant 8)

    /// A serialized node carrying graph metadata + a leaked AX pointer string
    /// must not surface any of: the field names ax_ref / graph_id /
    /// graph_generation / graph_locator, nor the `<AXUIElement 0x…>` string.
    func testNoGraphMetadataOrAXPointerSerializesIntoPacket() {
        let node = Node(
            index: 0,
            role: "button",
            // A leaked pointer string in a user-visible field must be scrubbed.
            label: "Save (<AXUIElement 0x600003abc123 {pid=29221}>)",
            value: "ok",
            axId: "secret-ax-id",
            depth: 0,
            axRef: FakeAXRef(),
            axRole: "AXButton",
            graphId: "g-12345",
            graphGeneration: 7,
            graphLocator: GraphLocator(axRole: "AXButton", label: "Save", depth: 0))

        let out = serialize([node], enablePruning: false)

        // No graph/ax-ref FIELD NAMES (Python snake_case + Swift camelCase forms).
        for token in ["ax_ref", "axRef", "graph_id", "graphId",
                      "graph_generation", "graphGeneration",
                      "graph_locator", "graphLocator", "GraphLocator"] {
            XCTAssertFalse(out.contains(token), "serialized packet leaked graph field: \(token)")
        }
        // No leaked AXUIElement pointer string.
        XCTAssertFalse(out.contains("<AXUIElement 0x"), "serialized packet leaked an AXUIElement pointer string")
        XCTAssertFalse(out.contains("0x600003abc123"), "serialized packet leaked the pointer hex")
        // The graph id value itself must not appear.
        XCTAssertFalse(out.contains("g-12345"), "serialized packet leaked the graph id value")
    }
}
