<p align="center">
  <img alt="mac-cua" src="assets/logo.svg" width="120">
</p>

<h1 align="center">mac-cua</h1>

<p align="center">
  <strong>The computer use agent that doesn't take over your computer.</strong><br>
  An open-source MCP server for macOS that lets AI control desktop apps<br>
  in the background — without ever touching your mouse or stealing your focus.
</p>

<p align="center">
  <a href="#quickstart"><strong>Quickstart</strong></a>  · 
  <a href="#background-first"><strong>Background-First</strong></a>  · 
  <a href="#tools"><strong>Tools</strong></a>  · 
  <a href="#setup-your-ai-tool"><strong>Setup</strong></a>  · 
  <a href="#architecture"><strong>Architecture</strong></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="License">
  <img src="https://img.shields.io/badge/python-3.13+-3776AB?logo=python&logoColor=white" alt="Python 3.13+">
  <img src="https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/protocol-MCP-8B5CF6" alt="MCP">
  <img src="https://img.shields.io/badge/tests-136%20passing-brightgreen" alt="Tests">
</p>

---

## Demo

> **Task:** Search Google for the population of Tokyo, calculate what percentage that is of the world population (8.1 billion), write the result in Notes, then open the Wikipedia page for Tokyo in Safari and find the mayor's name. Only CUA tools — no other tools allowed.

https://github.com/hyprcat/mac-cua/raw/release/assets/demo.mp4

**Result from Claude:**

> 1. Searched Google for "population of Tokyo" — found approximately 14.1–14.2 million residents
> 2. Calculated the percentage: 14.15 million / 8.1 billion = **0.17%** of the world's population
> 3. Wrote the result in Notes — created a new note titled "Tokyo Population vs World Population"
> 4. Opened the Wikipedia page for Tokyo in Safari and found that the leader of Tokyo is **Governor Yuriko Koike** (Tokyo has a Governor rather than a mayor, since it's officially the Tokyo Metropolitan Prefecture)

---

Most computer use agents take over your screen. They grab your cursor, steal window focus, and lock you out while they work. You sit and watch.

**mac-cua works differently.** It sends input events directly to target processes using `CGEventPostToPid` &mdash; a macOS API that delivers clicks, keystrokes, and gestures to a specific app without moving your cursor or activating any window. The AI works in the background. You keep working in the foreground. At the same time. On the same machine.

OpenAI and Perplexity both shipped computer use agents this week &mdash; locked to their platforms, behind paywalls. mac-cua is the same capability as an open MCP tool. Plug it into Claude Code, Cursor, Codex, or any MCP client. Free, open source, [Apache 2.0](LICENSE).

<br>

## Background-First

This is the core idea behind mac-cua, and it influences every design decision.

```
  Traditional computer use agent:            mac-cua:

  +----------------------------------+       +----------------------------------+
  |  YOUR SCREEN                     |       |  YOUR SCREEN                     |
  |                                  |       |                                  |
  |  +----------------------------+  |       |  +----------------------------+  |
  |  |                            |  |       |  |                            |  |
  |  |  [Agent controls this]     |  |       |  |  You're working here.      |  |
  |  |  You're locked out.        |  |       |  |  Writing code, browsing,   |  |
  |  |  Cursor hijacked.          |  |       |  |  whatever you want.        |  |
  |  |  Focus stolen.             |  |       |  |                            |  |
  |  |  Don't touch anything.     |  |       |  |  Your cursor. Your focus.  |  |
  |  |                            |  |       |  |                            |  |
  |  +----------------------------+  |       |  +----------------------------+  |
  |                                  |       |                                  |
  |  Cursor: [Agent's]               |       |  Meanwhile, in the background:   |
  |  Focus:  [Agent's]               |       |  mac-cua clicks, types, scrolls  |
  |  You:    Watching.               |       |  in Safari, Music, Finder...     |
  +----------------------------------+       +----------------------------------+
```

### How it stays invisible

| What                     | How                                                                                                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Mouse clicks**   | `CGEventPostToPid` sends click events to the target PID. Your cursor doesn't move.                                                                                      |
| **Keyboard input** | Key events are posted to the target process, not the global event stream.                                                                                                 |
| **Window focus**   | Mac-cua reads window state without activating windows. Temporary activation happens only when strictly required (e.g., key-window targeting) and is immediately released. |
| **Screenshots**    | GPU-accelerated `ScreenCaptureKit` captures specific windows by ID &mdash; works even if the window is behind other windows.                                            |
| **AX tree reads**  | Accessibility API queries are read-only and non-intrusive. They don't trigger any visual changes.                                                                         |

### A note on focus

Most operations are fully invisible, but a few macOS APIs have limitations that may cause a brief, momentary focus flash:

- **Launching an app** &mdash; macOS activates apps when they start; mac-cua yields focus back immediately
- **Scroll events** &mdash; some apps require momentary focus to receive scroll input
- **Key-window targeting** &mdash; certain actions need the window to be key window briefly

These flashes are sub-second and mac-cua restores your previous focus automatically. The vast majority of interactions &mdash; clicks, typing, value setting, screenshots, tree reads &mdash; are completely invisible.

### What this means in practice

- You can browse the web while mac-cua fills out a form in another app
- You can write code while mac-cua navigates System Settings to change a preference
- You can be in a video call while mac-cua organizes files in Finder
- The agent never interrupts you. If a conflict arises, **you win** &mdash; mac-cua detects user interruption and backs off

<br>

## Why mac-cua?

|                             | Codex CUA                                            | Perplexity Computer        | mac-cua                                                            |
| --------------------------- | ---------------------------------------------------- | -------------------------- | ------------------------------------------------------------------ |
| **Cost**              | $20&ndash;200/mo (ChatGPT tier) | $200/mo (Max only) | **Free**             |                                                                    |
| **Source**            | Closed                                               | Closed                     | **Open (Apache 2.0)**                                        |
| **LLM**               | GPT only                                             | Perplexity-routed          | **Any model**                                                |
| **Protocol**          | Proprietary (in-app)                                 | Proprietary (in-app)       | **MCP (open standard)**                                      |
| **Integration**       | Codex app only                                       | Perplexity app only        | **Claude Code, Cursor, VS Code, Codex, Zed, any MCP client** |
| **Background mode**   | Yes (virtual cursor)                                 | Unknown                    | **Yes (CGEventPostToPid)**                                   |
| **Accessibility API** | Yes (AX tree + screenshots)                          | Screenshots + AppleScript  | **Yes (AX tree + screenshots)**                              |
| **Platform**          | macOS only                                           | macOS only                 | **macOS**                                                    |
| **Availability**      | Not in EU/UK/CH                                      | Waitlist (Max subscribers) | **Everyone, everywhere**                                     |

<br>

## Quickstart

### Prerequisites

- **macOS 13+** (Ventura or later)
- **Python 3.13+**
- [**uv**](https://docs.astral.sh/uv/) package manager

### Install

```bash
git clone https://github.com/hyprcat/mac-cua.git
cd mac-cua
uv sync
```

### Run

```bash
uv run python main.py
```

On first launch, macOS will prompt for two permissions:

| Permission                 | Why                                                   |
| -------------------------- | ----------------------------------------------------- |
| **Accessibility**    | Read UI element trees and perform actions on elements |
| **Screen Recording** | Capture window screenshots without activating windows |

Grant both, and the MCP server starts on stdio &mdash; ready for your AI tool to connect.

<br>

## Setup Your AI Tool

mac-cua is a standard [MCP](https://modelcontextprotocol.io/) stdio server. It works with any tool that supports the Model Context Protocol &mdash; no plugins, no extensions, just config.

> **Note:** Replace `/path/to/mac-cua` with the actual path where you cloned the repo.

<details>
<summary><img src="https://img.shields.io/badge/Claude_Code-F97316?logo=anthropic&logoColor=white" alt="Claude Code" height="20">  <strong>Claude Code</strong></summary>

<br>

**Option A &mdash; CLI command (recommended):**

```bash
claude mcp add mac-cua -- uv run --directory /path/to/mac-cua python main.py
```

**Option B &mdash; Manual config** in `~/.claude.json` or project `.mcp.json`:

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/Claude_Desktop-F97316?logo=anthropic&logoColor=white" alt="Claude Desktop" height="20">  <strong>Claude Desktop</strong></summary>

<br>

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

Restart Claude Desktop after saving.

</details>

<details>
<summary><img src="https://img.shields.io/badge/Cursor-000000?logo=cursor&logoColor=white" alt="Cursor" height="20">  <strong>Cursor</strong></summary>

<br>

**Option A &mdash; Project-level:** Create `.cursor/mcp.json` in your project root:

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

**Option B &mdash; Global:** Create `~/.cursor/mcp.json` with the same content.

</details>

<details>
<summary><img src="https://img.shields.io/badge/VS_Code-007ACC?logo=visual-studio-code&logoColor=white" alt="VS Code" height="20">  <strong>VS Code (GitHub Copilot)</strong></summary>

<br>

Create `.vscode/mcp.json` in your project root:

```json
{
  "servers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

Requires the [GitHub Copilot](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot) extension with MCP support enabled.

</details>

<details>
<summary><img src="https://img.shields.io/badge/Windsurf-00C4B4?logoColor=white" alt="Windsurf" height="20">  <strong>Windsurf</strong></summary>

<br>

Open **Windsurf Settings** > **MCP** and add:

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

Or edit `~/.codeium/windsurf/mcp_config.json` directly.

</details>

<details>
<summary><img src="https://img.shields.io/badge/Codex_(OpenAI)-412991?logo=openai&logoColor=white" alt="Codex" height="20">  <strong>Codex (OpenAI CLI)</strong></summary>

<br>

Create or edit `~/.codex/config.json`:

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/Amp-FF6B00?logoColor=white" alt="Amp" height="20">  <strong>Amp</strong></summary>

<br>

Create `.amp/mcp.json` in your project root (or `~/.amp/mcp.json` globally):

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/Zed-084CCF?logo=zed&logoColor=white" alt="Zed" height="20">  <strong>Zed</strong></summary>

<br>

Add to your Zed `settings.json` (**Zed > Settings > Open Settings**):

```json
{
  "context_servers": {
    "mac-cua": {
      "command": {
        "path": "uv",
        "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
      }
    }
  }
}
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/Cline-5B5FC7?logoColor=white" alt="Cline" height="20">  <strong>Cline (VS Code Extension)</strong></summary>

<br>

Open Cline settings in VS Code, navigate to **MCP Servers**, and add:

```json
{
  "mcpServers": {
    "mac-cua": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/mac-cua", "python", "main.py"]
    }
  }
}
```

</details>

<details>
<summary><img src="https://img.shields.io/badge/Any_MCP_Client-gray" alt="Other" height="20">  <strong>Any other MCP client</strong></summary>

<br>

mac-cua is a standard MCP stdio server. Point your client at:

```
Command:  uv
Args:     run --directory /path/to/mac-cua python main.py
Protocol: stdio
```

No API keys, no accounts, no network calls. It runs locally on your Mac.

</details>

<br>

## How It Works

mac-cua reads apps through two complementary channels and acts through background-targeted input:

```
                        +-----------------------+
                        |      LLM Client       |
                        |  (Claude, GPT, etc.)  |
                        +-----------+-----------+
                                    |
                              MCP (stdio)
                                    |
                        +-----------+-----------+
                        |     mac-cua Server    |
                        +-----------+-----------+
                                    |
                    +---------------+---------------+
                    |                               |
          +---------+---------+           +---------+---------+
          |   Accessibility   |           |    Screenshots    |
          |    API (AXTree)   |           | (ScreenCaptureKit)|
          +---------+---------+           +---------+---------+
                    |                               |
          Structured element              Visual pixel-level
          tree with roles,                context via GPU-
          states, actions                 accelerated window
          (read-only, non-               capture (works even
           intrusive)                     behind other windows)
                    |                               |
                    +---------------+---------------+
                                    |
                        +-----------+-----------+
                        |   Background Input    |
                        |   CGEventPostToPid    |
                        |                       |
                        |  Your cursor: unmoved |
                        |  Your focus: untouched|
                        +-----------------------+
```

**Every tool call returns a fresh snapshot** &mdash; the accessibility tree and a screenshot together &mdash; so the LLM always sees the current state before deciding what to do next.

<br>

## Tools

9 MCP tools that cover the full range of desktop interaction &mdash; all operating in the background.

### Discovery

| Tool              | Description                                                                                       |
| ----------------- | ------------------------------------------------------------------------------------------------- |
| `list_apps`     | List running and recently-used apps with bundle IDs and usage stats                               |
| `get_app_state` | Capture a window's accessibility tree + screenshot.**Called each turn before interaction.** |

### Interaction

| Tool                         | Description                                                                                                                   |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `click`                    | Click by element index or pixel coordinates. Supports double-click, right-click. All clicks are background-targeted.          |
| `type_text`                | Type literal text via background keyboard input&mdash; keys go to the target process, not your focused app                    |
| `press_key`                | Send key combos in[xdotool syntax](https://linux.die.net/man/1/xdotool) (`super+c`, `Return`, `Tab`) to a specific process |
| `set_value`                | Directly set an accessibility element's value&mdash; no focus or typing needed                                                |
| `scroll`                   | Scroll a specific element by direction and page count                                                                         |
| `drag`                     | Drag between two pixel coordinates                                                                                            |
| `perform_secondary_action` | Invoke non-primary AX actions (expand, collapse, zoom, raise)                                                                 |

### Reliability Hierarchy

When multiple tools could accomplish the same thing, prefer them in this order:

```
  Most reliable                                          Least reliable
  +-------------------+------------------+-----------------+------------------+
  | AX secondary      | set_value        | click by        | click by         |
  | action            |                  | element         | coordinates      |
  +-------------------+------------------+-----------------+------------------+
```

<br>

## Example Workflow

Here's what a typical interaction looks like. Notice: every step happens in the background.

```python
# 1. Discover what's running
list_apps()
# => Safari (running), Music (running), Finder (running), ...

# 2. Get the current state of Safari (screenshot + AX tree)
get_app_state(app="Safari")
# => You don't even see Safari activate. mac-cua reads it silently.

# 3. Click the URL bar (element 12 from the tree)
click(app="Safari", element_index="12")
# => Click delivered to Safari's process. Your cursor didn't move.

# 4. Set the URL
set_value(app="Safari", element_index="12", value="https://example.com")
# => Value set directly via AX API. No typing animation. No focus change.

# 5. Press Enter
press_key(app="Safari", key="Return")
# => Key event sent to Safari. You didn't feel a thing.

# 6. Verify it worked
get_app_state(app="Safari")
# => Fresh screenshot shows the page loaded. All in the background.
```

<br>

## Architecture

Three clean layers. No framework magic.

```
Layer 1 ─ MCP Protocol         app/server.py         Thin. Validates, delegates, formats.
Layer 2 ─ Session Manager       app/session.py        Per-app lifecycle, snapshots, recovery.
Layer 3 ─ Platform Backend      app/_lib/             One module per macOS subsystem.
```

### Platform Backend Modules

| Module                | Responsibility                                                   |
| --------------------- | ---------------------------------------------------------------- |
| `accessibility.py`  | AX tree walking, batch attribute reads, element actions          |
| `screenshot.py`     | `CGWindowListCreateImage`, window ID resolution                |
| `screen_capture.py` | GPU-accelerated `ScreenCaptureKit` capture                     |
| `input.py`          | `CGEventPostToPid` &mdash; background mouse, keyboard, typing  |
| `apps.py`           | `NSWorkspace` app discovery, launch, PID/AX caching            |
| `focus.py`          | Focus tracking, user interruption detection, conflict resolution |
| `virtual_cursor.py` | Background cursor, input strategy, app-type detection            |
| `selection.py`      | Text selection extraction and formatting                         |
| `tree.py`           | AX tree&rarr; indexed text serialization                         |
| `pruning.py`        | Smart tree pruning to fit LLM context windows                    |
| `keys.py`           | xdotool syntax&rarr; CGKeyCode + modifier mapping                |
| `event_tap.py`      | `CGEventTap` wrapper with auto-reenable                        |
| `safety.py`         | App/URL blocklists, SSRF protection                              |
| `retry.py`          | Exponential backoff policies                                     |
| `elicitation.py`    | App approval store (session + persistent)                        |
| `lifecycle.py`      | Per-turn cleanup and step tracking                               |
| `errors.py`         | Typed exceptions and AX error code table                         |

### Key Design Decisions

- **`CGEventPostToPid`, never `CGEventPost`** &mdash; all input is process-targeted. The global event stream (your cursor, your keyboard) is never touched
- **Window capture without activation** &mdash; `ScreenCaptureKit` captures by window ID, even if the window is fully occluded
- **User interruption detection** &mdash; if you start using an app the agent is working in, mac-cua detects the conflict and yields to you
- **Snapshot-local indices** &mdash; element indices are valid only for the snapshot that produced them; no stale references
- **Cross-app robustness** &mdash; detects and adapts to Native Cocoa, Electron, Safari, Chrome, Java, and Qt apps
- **Event-driven settling** &mdash; `wait_for_settle` with per-tool timeouts and debounce, not fixed `sleep()` calls
- **Per-app guidance** &mdash; custom operational hints per bundle ID (e.g., `app/guidance/com.apple.Music.md`)

<br>

## Supported Apps

mac-cua works with any macOS application that exposes an accessibility tree:

- **Native Cocoa** &mdash; Finder, Safari, Music, System Settings, Notes, Calendar
- **Electron** &mdash; VS Code, Slack, Discord, Notion
- **Chromium** &mdash; Chrome, Arc, Edge
- **Java** &mdash; JetBrains IDEs (IntelliJ, PyCharm, WebStorm)
- **Qt** &mdash; Various Qt-based applications

Apps with minimal accessibility exposure fall back to screenshot-based coordinate interaction automatically.

<br>

## Safety

- **App blocklist** &mdash; prevents interaction with system security processes (Keychain, login)
- **URL blocklist** &mdash; SSRF protection for web-based interactions
- **App approval flow** &mdash; session and persistent approval gates before controlling new apps
- **Step limits** &mdash; per-turn cleanup and step tracking to prevent runaway loops
- **Background-only** &mdash; cannot inject events globally; input is always process-targeted
- **User wins** &mdash; interruption detection yields control back to you immediately

<br>

## Development

```bash
# Install dependencies
uv sync

# Run tests
uv run pytest

# Run a specific test
uv run pytest tests/test_safety.py -v

# Run the server
uv run python main.py
```

### Project Structure

```
mac-cua/
  main.py                  Entry point, permissions, logging
  app/
    server.py              MCP protocol layer
    session.py             Session lifecycle & orchestration
    response.py            Response dataclasses
    guidance/              Per-app operational hints
    _lib/                  Platform backend (17 modules, ~7300 LOC)
  tests/                   136 tests
  specs/                   Tool reference docs
```

<br>

## Contributing

Contributions are welcome! mac-cua is a community-driven project and we'd love your help.

1. **Fork** the repo
2. **Create a branch** (`git checkout -b my-feature`)
3. **Make your changes** &mdash; add tests if applicable
4. **Run the test suite** (`uv run pytest`)
5. **Open a Pull Request**

Whether it's a bug fix, new app guidance file, documentation improvement, or a whole new feature &mdash; all contributions are appreciated.

If you find mac-cua useful, consider giving it a star. It helps others discover the project.

<a href="https://star-history.com/#hyprcat/mac-cua&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=hyprcat/mac-cua&type=Date&theme=dark">
    <img alt="Star History" src="https://api.star-history.com/svg?repos=hyprcat/mac-cua&type=Date" width="600">
  </picture>
</a>

<br>

## License

[Apache License 2.0](LICENSE) &mdash; use it, fork it, ship it, sell it. No strings attached.

<br>

## Acknowledgments

mac-cua was inspired by [Codex computer use](https://openai.com/index/codex/) (OpenAI, April 2026) and [Personal Computer](https://www.perplexity.ai/personal-computer) (Perplexity, April 2026). Both showed that background desktop automation is the future &mdash; mac-cua brings that capability to everyone as an open-source MCP tool that works with any LLM.

Built with [MCP](https://modelcontextprotocol.io/) for universal LLM compatibility, [PyObjC](https://pyobjc.readthedocs.io/) for macOS integration, and [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) for GPU-accelerated background capture.
