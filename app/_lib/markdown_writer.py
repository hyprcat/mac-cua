"""AttributedStringMarkdownWriter — convert AX attributed strings to Markdown.

Parses NSAttributedString objects from AX APIs and converts rich text attributes
to Markdown notation.
"""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


class AttributedStringMarkdownWriter:
    """Convert AX attributed strings to Markdown.

    Processes NSAttributedString objects returned by AX APIs like
    AXAttributedStringForTextMarkerRange and converts formatting
    (bold, italic, links, etc.) into Markdown notation suitable
    for language model consumption.
    """

    def write(self, attributed_string: Any) -> str:
        """Convert an NSAttributedString to Markdown text.

        Parameters
        ----------
        attributed_string:
            An NSAttributedString (or compatible) object from AX APIs.

        Returns
        -------
        Markdown-formatted plain text.
        """
        if attributed_string is None:
            return ""

        # Get the full string content
        try:
            full_string = str(attributed_string.string())
        except (AttributeError, TypeError):
            # Not an attributed string — treat as plain string
            return str(attributed_string)

        if not full_string:
            return ""

        length = attributed_string.length()
        if length == 0:
            return full_string

        # Walk through attribute runs and build markdown
        segments: list[str] = []
        idx = 0

        while idx < length:
            try:
                attrs, effective_range = attributed_string.attributesAtIndex_effectiveRange_(
                    idx, None,
                )
            except Exception:
                # Fallback: just return the plain string
                return full_string

            start = effective_range.location
            end = start + effective_range.length
            text = full_string[start:end]

            if attrs:
                text = self._apply_attributes(text, attrs)

            segments.append(text)
            idx = end

        return "".join(segments)

    def _apply_attributes(self, text: str, attrs: Any) -> str:
        """Apply formatting attributes to a text segment."""
        if not text or not attrs:
            return text

        result = text

        # Check for link (AXLink / NSLink)
        link = _get_attr(attrs, "AXLink") or _get_attr(attrs, "NSLink")
        if link is not None:
            url = str(link)
            if url and url != result:
                result = f"[{result}]({url})"

        # Check for font traits (bold, italic)
        font = _get_attr(attrs, "NSFont") or _get_attr(attrs, "AXFont")
        if font is not None:
            traits = _extract_font_traits(font)
            if traits.get("bold") and traits.get("italic"):
                result = f"***{result}***"
            elif traits.get("bold"):
                result = f"**{result}**"
            elif traits.get("italic"):
                result = f"*{result}*"

        # Check for heading level
        heading_level = _get_attr(attrs, "AXHeadingLevel")
        if heading_level is not None:
            try:
                level = int(heading_level)
                if 1 <= level <= 6:
                    prefix = "#" * level
                    result = f"{prefix} {result}"
            except (ValueError, TypeError):
                pass

        # Check for code/monospace
        if font is not None and _is_monospace(font):
            if "\n" in result:
                result = f"```\n{result}\n```"
            else:
                result = f"`{result}`"

        # Check for list marker
        list_style = _get_attr(attrs, "AXListStyle") or _get_attr(attrs, "NSParagraphStyle")
        if list_style is not None:
            result = self._apply_list_style(result, list_style)

        # Log unknown style components
        if attrs is not None:
            try:
                for key in attrs:
                    key_str = str(key)
                    if key_str not in _KNOWN_ATTRS:
                        logger.debug(
                            "[MarkdownWriter] Unrecognized style component: %s",
                            key_str,
                        )
            except (TypeError, RuntimeError):
                pass

        return result

    def _apply_list_style(self, text: str, style: Any) -> str:
        """Convert list style attributes to markdown list markers."""
        style_str = str(style).lower() if style else ""
        if "ordered" in style_str or "decimal" in style_str:
            return f"1. {text}"
        if "unordered" in style_str or "bullet" in style_str or "disc" in style_str:
            return f"- {text}"
        return text


# Known attribute keys (don't warn about these)
_KNOWN_ATTRS = frozenset({
    "NSFont", "AXFont",
    "NSLink", "AXLink",
    "NSForegroundColor", "AXForegroundColor",
    "NSBackgroundColor", "AXBackgroundColor",
    "NSUnderline", "AXUnderline",
    "NSStrikethrough", "AXStrikethrough",
    "NSParagraphStyle", "AXParagraphStyle",
    "AXHeadingLevel",
    "AXListStyle",
    "NSAttachment",
    "NSSuperScript",
    "NSTextAlternatives",
    "NSAccessibilityMarkedMisspelledTextAttribute",
    "NSAccessibilityMisspelledTextAttribute",
    "NSAccessibilityFontTextAttribute",
    "AXNaturalSize",
})


def _get_attr(attrs: Any, key: str) -> Any:
    """Safely get an attribute value from an NSDictionary."""
    try:
        val = attrs.get(key) if hasattr(attrs, "get") else attrs.objectForKey_(key)
        return val
    except Exception:
        return None


def _extract_font_traits(font: Any) -> dict[str, bool]:
    """Extract bold/italic traits from an NSFont or AXFont dict."""
    traits: dict[str, bool] = {"bold": False, "italic": False}

    try:
        # AXFont is typically a dict with "AXFontName" and traits
        if hasattr(font, "objectForKey_"):
            # NSDictionary-style AXFont
            font_name = font.objectForKey_("AXFontName")
            if font_name:
                name_lower = str(font_name).lower()
                traits["bold"] = "bold" in name_lower
                traits["italic"] = "italic" in name_lower or "oblique" in name_lower
            return traits

        # NSFont object
        if hasattr(font, "fontDescriptor"):
            descriptor = font.fontDescriptor()
            if hasattr(descriptor, "symbolicTraits"):
                symbolic = descriptor.symbolicTraits()
                # NSFontBoldTrait = 1 << 1 = 2
                # NSFontItalicTrait = 1 << 0 = 1
                traits["bold"] = bool(symbolic & 2)
                traits["italic"] = bool(symbolic & 1)
                return traits

        # Fallback: check font name
        name = str(font)
        name_lower = name.lower()
        traits["bold"] = "bold" in name_lower
        traits["italic"] = "italic" in name_lower or "oblique" in name_lower
    except Exception:
        pass

    return traits


def _is_monospace(font: Any) -> bool:
    """Check if a font is monospace."""
    try:
        if hasattr(font, "objectForKey_"):
            font_name = font.objectForKey_("AXFontName")
            if font_name:
                name_lower = str(font_name).lower()
                return any(
                    m in name_lower
                    for m in ("mono", "courier", "menlo", "consolas", "source code")
                )

        if hasattr(font, "isFixedPitch"):
            return bool(font.isFixedPitch())

        name_lower = str(font).lower()
        return any(
            m in name_lower
            for m in ("mono", "courier", "menlo", "consolas", "source code")
        )
    except Exception:
        return False
