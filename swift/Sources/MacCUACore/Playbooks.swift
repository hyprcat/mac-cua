// Playbooks.swift
//
// Built-in per-app instruction playbooks (US-049, design §I). Curated Markdown
// guidance injected once-per-session into the `<app_specific_instructions>`
// block of `get_app_state` (see SessionManager `loadGuidance` +
// FormatMCP guidance splice).
//
// Pure content + lookup — lives in Core so it is Linux-testable and carries no
// macOS dependency. The Python reference ships only `com.apple.Music.md` as a
// loose file under `app/guidance/`; the Swift port has no bundled resource
// directory, so the curated set is embedded here as a static table keyed by
// bundle id. A loose on-disk file (if a future deployment adds one) still wins
// via the cache in `loadGuidance`; this table is the fallback default.

import Foundation

/// Curated per-app guidance, keyed by bundle id. Mirrors the Python
/// `GUIDANCE_DIR / "<bundle_id>.md"` convention but embedded as pure content.
public enum BuiltinPlaybooks {
    /// Returns the curated playbook for a bundle id, or nil if none is authored.
    public static func guidance(for bundleId: String) -> String? {
        playbooks[bundleId]
    }

    /// All authored bundle ids (stable order not guaranteed).
    public static var bundleIds: [String] { Array(playbooks.keys) }

    public static let playbooks: [String: String] = [
        // Apple Safari
        "com.apple.Safari": """
        ## Safari Tips

        - **Web content is pointer-first:** clickable web elements (links, buttons, \
        inputs) are best driven with `click` — AXPress under-triggers web controls. \
        Use `set_value` on a focused field, or `type_text` after clicking into it.
        - **Address bar:** click the unified URL/search field, then `set_value` the URL \
        (more reliable than `type_text`), then `press_key` Return.
        - **Tabs:** tab buttons live in the toolbar/tab bar; click to switch. New tab is \
        Cmd-T via `press_key`.
        - **Scrolling:** target the web area (the large scrollable element), not an \
        individual link; web content uses point-delta scrolling.
        - **Selecting text:** prefer `select_text` with the visible phrase; web/rich \
        content selection goes through the text-marker tier automatically.
        - **Waiting:** after navigation, use `wait` to let the page settle before \
        reading the tree — content loads asynchronously.
        """,

        // Google Chrome
        "com.google.Chrome": """
        ## Google Chrome Tips

        - **Pointer-first:** Chrome is Chromium — drive web controls with `click`, not \
        AXPress. AX actions frequently no-op on web buttons/links.
        - **Enable accessibility:** the tree may be empty on first read; it is populated \
        after enhanced-accessibility attach + a re-walk. If empty, `wait` then re-read.
        - **Omnibox:** click the address/search field, `set_value` the URL or query, \
        then `press_key` Return.
        - **Tabs:** click a tab in the tab strip to switch; Cmd-T / Cmd-W via `press_key`.
        - **Scrolling:** target the web content area; uses point-delta (pixel) scrolling. \
        Use multiple page scrolls for long pages.
        - **Profiles/menus:** the three-dot menu and profile button are toolbar controls; \
        click them directly.
        """,

        // Slack
        "com.tinyspeck.slackmacgap": """
        ## Slack Tips

        - **Electron app — pointer-first:** Slack is Electron; click web-style controls \
        rather than relying on AXPress. The tree is populated only after the \
        enhanced-accessibility attach; if the first read is empty, `wait` then re-read.
        - **Sending a message:** click the message input box (bottom of the channel), \
        `type_text` the message, then `press_key` Return to send. Shift-Return inserts a \
        newline without sending.
        - **Switching channels:** use the sidebar rows, or the Quick Switcher (Cmd-K) — \
        click the search field, `type_text` the channel name, then select the result.
        - **Threads/reactions:** hover-driven controls appear via pointer interaction; \
        click directly on the message row's actions.
        - **Scrolling:** target the message-list scroll area; use page scrolls to load \
        older history.
        """,

        // Apple Mail
        "com.apple.mail": """
        ## Apple Mail Tips

        - **Three-pane layout:** mailbox sidebar, message list, and message/compose pane. \
        Click a mailbox row to switch, click a message row to open it.
        - **Composing:** Cmd-N (`press_key`) opens a new message; click the To/Subject/body \
        fields and `type_text` or `set_value`. Send with Cmd-Shift-D.
        - **Search:** click the search field in the toolbar, `set_value` the query, \
        `press_key` Return.
        - **Reading order:** the message list is a table — target rows by their visible \
        sender/subject. Use `select_text` to grab a phrase from the open message body.
        - **Scrolling:** target the message-list scroll area or the message body scroll \
        area specifically, not the whole window.
        """,

        // Xcode
        "com.apple.dt.Xcode": """
        ## Xcode Tips

        - **Native Cocoa controls:** toolbar buttons, navigator rows, and menus are \
        AX-first — `click` resolves to AXPress reliably. The source editor is a text view.
        - **Navigators:** the left navigator (Project/Find/etc.) is a sidebar of rows; \
        click a row to select. Toggle navigators via the toolbar segmented control.
        - **Editing source:** click into the editor then `type_text`; for precise edits \
        use `select_text` to select a phrase, then `type_text` to replace it.
        - **Build/Run:** the Run (▶) and Stop buttons are in the toolbar; click directly. \
        Cmd-B builds, Cmd-R runs via `press_key`.
        - **Build waits:** after triggering a build/run, `wait` for the activity to settle \
        before reading status — indicators animate during compilation.
        - **Inspectors:** the right-hand inspector pane is a stack of disclosure groups; \
        expand by clicking the disclosure triangle.
        """,

        // Visual Studio Code
        "com.microsoft.VSCode": """
        ## Visual Studio Code Tips

        - **Electron — pointer-first:** VS Code is Electron; click web-style controls. \
        The tree may be empty until enhanced-accessibility attach + re-walk; if empty, \
        `wait` then re-read.
        - **Command Palette:** Cmd-Shift-P (`press_key`) opens it; `type_text` the command, \
        then Return — often the most reliable way to invoke an action.
        - **Editor:** click into the editor area then `type_text`. Use `select_text` to \
        target a phrase for replacement. The editor is a virtualized surface — only \
        on-screen lines are in the tree; scroll to reach off-screen content.
        - **Activity bar / sidebar:** the left icons (Explorer, Search, Source Control) \
        are clickable; the panel below shows the tree of files/results.
        - **Scrolling:** target the editor or explorer scroll area; uses point-delta \
        scrolling. Use page scrolls for long files.
        """,

        // System Settings
        "com.apple.systempreferences": """
        ## System Settings Tips

        - **Sidebar navigation:** the left sidebar is a list of categories (Wi-Fi, \
        Displays, etc.). Click a category row to switch the detail pane.
        - **Search:** click the search field at the top of the sidebar, `set_value` the \
        setting name, then select the matching result to jump directly.
        - **Detail pane controls:** toggles, pop-up buttons, and steppers are native \
        AX controls — `click` resolves to the right action. Use `set_value` for text \
        fields, and `perform_secondary_action` for menus where needed.
        - **Disclosure:** some sections expand via a disclosure triangle or an "info" \
        (ⓘ) button — click it to reveal nested controls.
        - **Settling:** switching panes animates; `wait` for settle before reading the \
        new pane's tree.
        """,

        // Apple Music — parity with the Python reference (app/guidance/com.apple.Music.md)
        "com.apple.Music": """
        ## Apple Music Tips

        - **Search:** Click the Search row in the sidebar, then use `set_value` on the \
        search text field (more reliable than `type_text`).
        - **Play a track:** Double-click (`click_count: 2`) on a track row, or click the \
        Play button.
        - **Navigation:** Use sidebar rows to switch between Home, Browse, Library sections.
        - **Scrolling:** Target the scroll area element, not individual rows. Use multiple \
        page scrolls for large lists.
        - **Mini Player:** The mini player container shows current track info and playback \
        controls. Check for Play/Pause button state to verify playback.
        """,
    ]
}
