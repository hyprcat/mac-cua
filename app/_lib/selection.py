"""System text selection tracking and extraction.

Tracks focused UI element changes and extracts selected text using a 4-method
priority pipeline.

Output format:
  Selected text: ```
  <the selected text>
  ```
"""

from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable

logger = logging.getLogger(__name__)


class FocusedElementObserver:
    """Observe which UI element has AX focus system-wide.

    Polls kAXFocusedUIElementAttribute at 100ms intervals on a background thread.
    """

    def __init__(self) -> None:
        self.on_focused_ui_element_changed: Callable[[Any], None] | None = None
        self._pid: int = 0
        self._running = False
        self._thread: threading.Thread | None = None

    def start(self, pid: int) -> None:
        """Start observing focused element changes for a specific process."""
        self._pid = pid
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(
            target=self._poll_loop,
            name="FocusedElementObserver",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        """Stop observing."""
        self._running = False
        self._thread = None
        self._pid = 0

    def _poll_loop(self) -> None:
        """Poll kAXFocusedUIElementAttribute at 100ms intervals."""
        from ApplicationServices import (
            AXUIElementCreateApplication,
            AXUIElementCopyAttributeValue,
            kAXFocusedUIElementAttribute,
            kAXErrorSuccess,
        )

        last_ref: Any = None

        while self._running and self._pid > 0:
            try:
                ax_app = AXUIElementCreateApplication(self._pid)
                err, focused = AXUIElementCopyAttributeValue(
                    ax_app, kAXFocusedUIElementAttribute, None,
                )
                if err == kAXErrorSuccess and focused is not None:
                    # Only fire callback if element changed
                    if last_ref is None or not _cf_equal_safe(last_ref, focused):
                        last_ref = focused
                        cb = self.on_focused_ui_element_changed
                        if cb is not None:
                            try:
                                cb(focused)
                            except Exception:
                                pass
            except Exception:
                pass

            time.sleep(0.1)  # 100ms polling interval


class SelectionClient:
    """Track and extract selected text.

    Monitors focused UI element changes and extracts system text selection.

    Properties:
    - on_selection_changed: callback
    - current_selection: current selection string
    - focused_element_observer: observer instance
    - _extracting: re-entrancy guard
    - _pid: tracked process PID
    - _name: tracked app name
    """

    def __init__(self) -> None:
        self.on_system_selection_changed: Callable[[str | None], None] | None = None
        self.system_selection: str | None = None
        self._observer = FocusedElementObserver()
        self._extractor = SelectionExtractor()
        self._is_extracting = False
        self._pid: int = 0
        self._name: str | None = None
        self._lock = threading.Lock()

    @property
    def has_selection(self) -> bool:
        """Whether there is currently selected text."""
        return self.system_selection is not None and len(self.system_selection) > 0

    def start_observing(self, pid: int, app_name: str | None = None) -> None:
        """Start observing text selection in the given process."""
        self._pid = pid
        self._name = app_name
        self._observer.on_focused_ui_element_changed = self._on_focus_changed
        self._observer.start(pid)

    def stop_observing(self) -> None:
        """Stop observing text selection."""
        self._observer.stop()
        self._observer.on_focused_ui_element_changed = None
        self.system_selection = None
        self._pid = 0
        self._name = None

    def extract_selection_from(self, focused_element: Any) -> str | None:
        """Extract selection from a specific element (on-demand, not observer-driven)."""
        return self._extract_selection(focused_element)

    def _on_focus_changed(self, focused_element: Any) -> None:
        """Handle focused UI element change — extract selection."""
        self._extract_selection(focused_element)

    def _extract_selection(self, focused_element: Any) -> str | None:
        """Extract the current text selection from the focused element.

        Uses the 4-method SelectionExtractor pipeline.
        """
        with self._lock:
            if self._is_extracting:
                return self.system_selection
            self._is_extracting = True

        try:
            result = self._extractor.extract(focused_element)
            old = self.system_selection
            self.system_selection = result
            if result != old:
                cb = self.on_system_selection_changed
                if cb is not None:
                    try:
                        cb(result)
                    except Exception:
                        pass
            return result
        except Exception as exc:
            logger.warning(
                "[SelectionClient] Could not extract selection: %s", exc,
            )
            return None
        finally:
            with self._lock:
                self._is_extracting = False


class SelectionExtractor:
    """4-method extraction pipeline for system text selection.

    Tries methods in priority order until one succeeds:
    1. selectedText -- kAXSelectedTextAttribute (fastest)
    2. selectedRichText -- AXAttributedStringForTextMarkerRange -> Markdown
    3. selectedElementText -- Full text of selected element
    4. pasteboard fallback -- Simulate Cmd+C, read pasteboard (aggressive)
    """

    def __init__(self) -> None:
        self._should_try_pasteboard = True

    def extract(self, focused_element: Any) -> str | None:
        """Try extraction methods in priority order until one succeeds."""
        if focused_element is None:
            return None

        result = (
            self._try_selected_text(focused_element)
            or self._try_selected_rich_text(focused_element)
            or self._try_selected_element_text(focused_element)
        )

        if result is None and self._should_try_pasteboard:
            result = self._try_pasteboard_fallback(focused_element)

        return result

    def _try_selected_text(self, element: Any) -> str | None:
        """kAXSelectedTextAttribute -- fastest and most reliable."""
        try:
            from ApplicationServices import (
                AXUIElementCopyAttributeValue,
                kAXErrorSuccess,
            )

            err, value = AXUIElementCopyAttributeValue(
                element, "AXSelectedText", None,
            )
            if err == kAXErrorSuccess and value is not None:
                text = str(value).strip()
                if text:
                    return text
        except Exception:
            pass
        return None

    def _try_selected_rich_text(self, element: Any) -> str | None:
        """AXAttributedStringForTextMarkerRange using AXSelectedTextMarkerRange -> Markdown."""
        try:
            from ApplicationServices import (
                AXUIElementCopyAttributeValue,
                AXUIElementCopyParameterizedAttributeValue,
                kAXErrorSuccess,
            )

            # Get the selected text marker range
            err, marker_range = AXUIElementCopyAttributeValue(
                element, "AXSelectedTextMarkerRange", None,
            )
            if err != kAXErrorSuccess or marker_range is None:
                return None

            # Get attributed string for that range
            err, attributed = AXUIElementCopyParameterizedAttributeValue(
                element,
                "AXAttributedStringForTextMarkerRange",
                marker_range,
                None,
            )
            if err != kAXErrorSuccess or attributed is None:
                return None

            # Convert to Markdown
            from app._lib.markdown_writer import AttributedStringMarkdownWriter
            writer = AttributedStringMarkdownWriter()
            text = writer.write(attributed)
            if text and text.strip():
                return text.strip()

        except ImportError:
            pass
        except Exception:
            pass
        return None

    def _try_selected_element_text(self, element: Any) -> str | None:
        """Read the full text of the selected/focused element.

        Falls back to AXValue if no selected text is available.
        """
        try:
            from ApplicationServices import (
                AXUIElementCopyAttributeValue,
                kAXErrorSuccess,
            )

            # Try AXValue (the full text content of the element)
            err, value = AXUIElementCopyAttributeValue(
                element, "AXValue", None,
            )
            if err == kAXErrorSuccess and value is not None:
                text = str(value).strip()
                if text:
                    return text
        except Exception:
            pass
        return None

    def _try_pasteboard_fallback(self, element: Any) -> str | None:
        """Simulate Cmd+C, read pasteboard, restore clipboard.

        This is the most aggressive fallback -- it temporarily modifies the
        system clipboard to extract selection from apps that don't expose
        it via AX attributes.

        Note: This is intentionally conservative. We only use it when the
        focused element has a selection range but AX text extraction failed.
        """
        try:
            from ApplicationServices import (
                AXUIElementCopyAttributeValue,
                kAXErrorSuccess,
            )

            # Only attempt if there's a selection range indicating text IS selected
            err, sel_range = AXUIElementCopyAttributeValue(
                element, "AXSelectedTextRange", None,
            )
            if err != kAXErrorSuccess or sel_range is None:
                return None

            # Check if the range has nonzero length
            try:
                from Foundation import NSValue
                range_val = sel_range.rangeValue()
                if range_val.length == 0:
                    return None
            except Exception:
                # Can't verify range — skip pasteboard fallback
                return None

            import AppKit

            pb = AppKit.NSPasteboard.generalPasteboard()

            # Save current clipboard content
            old_types = pb.types()
            old_items: list[tuple[str, Any]] = []
            if old_types:
                for t in old_types:
                    data = pb.dataForType_(t)
                    if data:
                        old_items.append((str(t), data))

            try:
                # Clear and simulate Cmd+C via AX
                pb.clearContents()

                # Get the PID of the element to send key event
                from ApplicationServices import AXUIElementGetPid
                err, pid = AXUIElementGetPid(element, None)
                if err != kAXErrorSuccess:
                    return None

                from app._lib.input import key_press
                # Simulate Cmd+C
                key_press(pid, 8, flags=0x100000)  # 8 = 'c' keycode, Cmd flag
                time.sleep(0.15)  # Wait for copy to complete

                # Read pasteboard
                text = pb.stringForType_(AppKit.NSPasteboardTypeString)
                if text:
                    return str(text).strip() or None
                return None
            finally:
                # Restore clipboard
                pb.clearContents()
                if old_items:
                    for type_str, data in old_items:
                        pb.setData_forType_(data, type_str)

        except Exception:
            return None


def format_selection(text: str | None) -> str | None:
    """Format selection text for inclusion in tool responses.

    Format:
        Selected text: ```
        <the selected text>
        ```
    """
    if not text:
        return None
    return f"Selected text: ```\n{text}\n```"


def _cf_equal_safe(a: Any, b: Any) -> bool:
    """Safely compare two CF/AX objects."""
    try:
        from Foundation import CFEqual
        return bool(CFEqual(a, b))
    except Exception:
        return False
