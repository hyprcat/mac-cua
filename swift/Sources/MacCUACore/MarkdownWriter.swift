import Foundation

// Port of `app/_lib/markdown_writer.py` — AttributedStringMarkdownWriter.
//
// PURE logic, no macOS deps. Converts AX attributed-string content (rich text
// runs) to Markdown for the model. The NSAttributedString -> [AttributedRun]
// adapter is a Kit seam (see `AttributedRunProvider`); only the run-sequence
// -> Markdown assembly and the font-trait/list parsing live here.
//
// Also ports `format_selection` from `app/_lib/selection.py`.

// MARK: - AttributedRun abstraction

/// One effective-range run of an AX attributed string, with the formatting
/// attributes already resolved by a Kit-side adapter (which may use the pure
/// `extractFontTraits`/`isMonospaceFont` helpers below). This is the injected
/// abstraction the pure writer operates over.
public struct AttributedRun: Equatable, Sendable {
    /// The plain substring for this run.
    public var text: String
    /// AXLink / NSLink URL, if any.
    public var link: String?
    /// Resolved bold trait (from NSFont symbolic traits or AXFont name).
    public var bold: Bool
    /// Resolved italic trait.
    public var italic: Bool
    /// Whether the run's font is fixed-pitch / monospace (code).
    public var monospace: Bool
    /// AXHeadingLevel, if present (only 1...6 render).
    public var headingLevel: Int?
    /// Raw list-style string (AXListStyle / NSParagraphStyle description), if any.
    public var listStyle: String?

    public init(
        text: String,
        link: String? = nil,
        bold: Bool = false,
        italic: Bool = false,
        monospace: Bool = false,
        headingLevel: Int? = nil,
        listStyle: String? = nil
    ) {
        self.text = text
        self.link = link
        self.bold = bold
        self.italic = italic
        self.monospace = monospace
        self.headingLevel = headingLevel
        self.listStyle = listStyle
    }
}

// MARK: - Kit seam

/// Adapter that turns a platform NSAttributedString (from AX parameterized
/// attributes) into an ordered `[AttributedRun]`. Implemented in MacCUAKit;
/// declared here as a seam so the pure writer stays Linux-buildable.
public protocol AttributedRunProvider {
    /// Returns nil for a non-attributed / unreadable value (caller falls back
    /// to the plain string), an empty array for empty content.
    func runs(forAttributedValue value: Any) -> [AttributedRun]?
}

// MARK: - Writer

public enum MarkdownWriter {

    /// Assemble Markdown from an ordered run sequence. Mirrors
    /// `AttributedStringMarkdownWriter.write` segment assembly.
    public static func write(runs: [AttributedRun]) -> String {
        runs.map(applyAttributes).joined()
    }

    /// Apply formatting to one run, in the exact order the Python applies it:
    /// link, then bold/italic, then heading, then monospace code, then list.
    static func applyAttributes(_ run: AttributedRun) -> String {
        // Python early-returns the text untouched when empty.
        guard !run.text.isEmpty else { return run.text }
        var result = run.text

        // Link (AXLink / NSLink).
        if let url = run.link, !url.isEmpty, url != result {
            result = "[\(result)](\(url))"
        }

        // Font traits (bold / italic).
        if run.bold && run.italic {
            result = "***\(result)***"
        } else if run.bold {
            result = "**\(result)**"
        } else if run.italic {
            result = "*\(result)*"
        }

        // Heading level (1...6 only).
        if let level = run.headingLevel, (1...6).contains(level) {
            result = String(repeating: "#", count: level) + " " + result
        }

        // Code / monospace.
        if run.monospace {
            if result.contains("\n") {
                result = "```\n\(result)\n```"
            } else {
                result = "`\(result)`"
            }
        }

        // List marker.
        if let style = run.listStyle {
            result = applyListStyle(result, style)
        }

        return result
    }

    /// Convert a list-style description to a Markdown list marker. Mirrors
    /// `_apply_list_style`.
    static func applyListStyle(_ text: String, _ style: String) -> String {
        let s = style.lowercased()
        if s.contains("ordered") || s.contains("decimal") {
            return "1. \(text)"
        }
        if s.contains("unordered") || s.contains("bullet") || s.contains("disc") {
            return "- \(text)"
        }
        return text
    }
}

// MARK: - Font-trait helpers (pure; usable by the Kit adapter)

/// Extract bold/italic from a font name, mirroring the name-based branch of
/// `_extract_font_traits`. Symbolic-trait extraction (NSFont) belongs in the
/// Kit adapter; this is the name-fallback path and AXFont-name path.
public func extractFontTraits(fontName: String?) -> (bold: Bool, italic: Bool) {
    guard let name = fontName?.lowercased() else { return (false, false) }
    let bold = name.contains("bold")
    let italic = name.contains("italic") || name.contains("oblique")
    return (bold, italic)
}

/// Whether a font name denotes a monospace font. Mirrors the name branch of
/// `_is_monospace`.
public func isMonospaceFont(fontName: String?) -> Bool {
    guard let name = fontName?.lowercased() else { return false }
    let markers = ["mono", "courier", "menlo", "consolas", "source code"]
    return markers.contains { name.contains($0) }
}

// MARK: - Selection formatting (port of selection.format_selection)

/// Format selection text for inclusion in tool responses. Returns nil for
/// empty/nil input. Mirrors `app/_lib/selection.py::format_selection`.
public func formatSelection(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return "Selected text: ```\n\(text)\n```"
}
