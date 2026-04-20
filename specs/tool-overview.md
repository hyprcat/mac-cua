The `Computer Use` capability in this session is an accessibility-and-UI automation layer over desktop apps on macOS. Conceptually, it gives me three things:

1. App discovery: what apps exist / are running.
2. Per-turn UI introspection: a screenshot plus an accessibility tree of the active window.
3. Action primitives: click, type, keypress, scroll, drag, set control values, and invoke non-primary accessibility actions.

What follows is the deepest accurate description I can give from the actual tool interfaces I have here, plus the behavior they exhibited while controlling Apple Music.

**Mental model**

These tools are not DOM automation in the browser sense, and they are not raw OS event injection only. They sit somewhere between:
- macOS accessibility APIs, for discovering UI elements and acting on them by element identity
- screenshot-based coordinate interaction, for clicking or dragging by pixels when an element reference is not enough

That hybrid model explains why some tools accept `element_index` and others accept `x`/`y`, and why `get_app_state` is required first: it refreshes the live UI model for the current app window.

**Tool namespace**

All available tools are under `mcp__mac-cua__`:

- `list_apps`
- `get_app_state`
- `click`
- `drag`
- `press_key`
- `type_text`
- `set_value`
- `scroll`
- `perform_secondary_action`

## `list_apps`

**Official docstring**
`List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{}
```

**Purpose**
This is an inventory/discovery call. It answers:
- which apps are currently running
- which apps are known recently
- what bundle identifiers or app names I can target in later calls

**Observed response shape**
In practice, I received a text payload listing apps like:
- display name
- bundle identifier
- run state
- last-used date
- usage count

Example of the returned content style:
```text
Safari — com.apple.Safari [running, last-used=2026-04-19, uses=12]
System Settings — com.apple.systempreferences [running, last-used=2026-04-19, uses=7]
Finder — com.apple.finder [running]
Zed — dev.zed.Zed [last-used=2026-04-11, uses=1]
```

**Technical implications**
- It is not just “running processes”; it includes historical app usage metadata.
- It is useful for resolving ambiguity between a display name and a bundle id.
- If an app is absent from the running set, I can still often target it by name in `get_app_state`, which may launch or attach to it.

**When to use**
- Before first interacting with an unfamiliar app
- To find the correct `app` identifier
- To check whether an app is already open

---

## `get_app_state`

**Official docstring**
`Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string"
}
```

**Parameters**
- `app`: app name or bundle identifier

Examples:
- `"Music"`
- `"com.apple.Music"`
- `"Finder"`

**Purpose**
This is the core introspection primitive. It does several things at once:
- starts or attaches to a session for that app
- brings the app into the computer-use context
- inspects the key window
- returns a screenshot
- returns the accessibility tree with indexed elements
- may include app-specific operational hints

**Observed response structure**
A typical response includes:

1. App metadata
```text
App=com.apple.Music (pid 40054)
Window: "Music", App: Music.
```

2. Accessibility tree
Elements are listed in a hierarchy with numeric indices:
```text
0 standard window Music
  1 split group
    2 scroll area
      3 outline Description: Sidebar
        4 row (selectable) Search
        5 row (selected) Home
```

3. Element metadata
Depending on the node, it may include:
- role/type: `button`, `row`, `scroll area`, `slider`, `text`, `container`
- state: `selected`, `disabled`, `expanded`
- label-like fields: `Description`, `Value`, `Help`
- stable-ish control ids: `ID: Music.accountButton`
- secondary actions: `Scroll Up`, `Collapse`, `Raise`, `zoom the window`

4. Focus info
```text
The focused UI element is 0 standard window.
```

5. Screenshot
The UI image is rendered alongside the state payload.

6. Sometimes app-specific instructions
In Apple Music it returned a custom section explaining:
- how to search
- how to navigate
- how playback works

That suggests the plugin can attach app-specific behavior notes for certain apps.

**Why it must be called each turn**
The tool docs explicitly require one `get_app_state` per assistant turn before interaction. That makes sense because:
- UI trees become stale quickly
- element indices are snapshots, not guaranteed persistent IDs across turns
- windows may move, rerender, or change focus
- coordinate systems are tied to the fresh screenshot

**Technical caveats**
- Element indices like `77` are not global IDs. They are snapshot-local handles.
- The tree is keyed to the app’s key window, not necessarily every window the app owns.
- “Key window” matters: if a dialog, sheet, or subwindow appears, the tree can change drastically.
- Calls can be slow. In my Apple Music interaction, one `get_app_state` took over 100 seconds because the app was starting and loading its first-run UI.

**Best practices**
- Call `get_app_state` before any app interaction in a turn
- Re-run it whenever the app changes significantly
- Prefer element-based actions after inspecting the new tree
- Fall back to coordinates only when necessary

---

## `click`

**Official docstring**
`Click an element by index or pixel coordinates from screenshot. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string",
  "click_count": "integer (optional)",
  "element_index": "string (optional)",
  "mouse_button": "left | right | middle (optional)",
  "x": "number (optional)",
  "y": "number (optional)"
}
```

**Parameters**
- `app`: app name or bundle identifier
- `click_count`: optional, defaults to `1`
- `element_index`: target accessibility node index from the latest `get_app_state`
- `mouse_button`: optional, defaults to `left`
- `x`, `y`: pixel coordinates relative to the returned screenshot

**Two operating modes**
1. Accessibility-element click
```json
{
  "app": "com.apple.Music",
  "element_index": "77"
}
```

2. Coordinate click
```json
{
  "app": "Music",
  "x": 430,
  "y": 672,
  "click_count": 2
}
```

**Semantics**
- If using `element_index`, the system attempts to resolve the element in the current accessibility tree and click it.
- If using `x`/`y`, the system attempts a direct mouse click at those screenshot coordinates.
- `click_count: 2` behaves as a double-click.

**Observed response behavior**
A successful `click` often returns a refreshed app state immediately.
Example: clicking the Apple Music “Start Listening” button returned the updated window tree.

It can also fail with text errors. I observed:
- `Apple event error -10005: cannotClickOffscreenElement`
- `Apple event error -10005: noWindowsAvailable`

**What those errors imply**
- `cannotClickOffscreenElement`: accessibility knew about the element, but the OS considered it not clickable because it was outside the interactable visible bounds
- `noWindowsAvailable`: the backend could not resolve a usable target window for that click request at that moment; possibly transient window focus/session state mismatch

**Technical tradeoffs**
Element click:
- More semantic
- More robust to layout shifts
- Can fail if the element is offscreen, occluded, or stale

Coordinate click:
- Useful when the visual target is clear
- More brittle because coordinates depend on the latest screenshot and scale/layout
- Sensitive to window movement and rendering changes

**Practical pattern**
- Prefer `element_index`
- Fall back to coordinates if needed
- If either fails, call `get_app_state` again and retry on fresh state
- If targeting by app name is flaky, try the bundle id; in my Apple Music run, `com.apple.Music` worked more reliably than `Music`

---

## `drag`

**Official docstring**
`Drag from one point to another using pixel coordinates. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string",
  "from_x": "number",
  "from_y": "number",
  "to_x": "number",
  "to_y": "number"
}
```

**Purpose**
Low-level mouse drag gesture. This is for interactions like:
- moving sliders when no `set_value` exists
- selecting text or regions
- rearranging items
- scroll gestures or scrubber motion in apps that respond to drag

**Technical note**
This tool is coordinate-only. There is no element-based drag variant in the exposed interface.

**Expected response**
Usually either:
- updated app state
- or success/error text

**Caveats**
- Highly sensitive to current window position and screenshot freshness
- More brittle than `set_value` for sliders
- Best used when the exact gesture path matters

---

## `press_key`

**Official docstring**
`Press a key or key-combination on the keyboard, including modifier and navigation keys.
- This supports xdotool's 'key' syntax.
- Examples: "a", "Return", "Tab", "super+c", "Up", "KP_0" (for the numpad 0 key). This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string",
  "key": "string"
}
```

**Purpose**
Sends a keypress or chord to the target app.

**Examples**
```json
{ "app": "Music", "key": "Return" }
{ "app": "Finder", "key": "Tab" }
{ "app": "Music", "key": "super+c" }
{ "app": "Music", "key": "Up" }
```

**Technical detail**
The docstring explicitly references xdotool-style key syntax. Even though the environment is macOS, the key-string format exposed to me follows that style.

**Common uses**
- activate focused controls
- keyboard navigation
- shortcuts
- menu accelerators
- dismiss dialogs with `Escape`
- confirm actions with `Return`

**Expected response**
Usually a refreshed state or success/error payload.

**Caveats**
- Success depends on focus being where we think it is
- If the wrong element/app has focus, the key can go to the wrong target
- Often best paired with `get_app_state` to confirm focused context first

---

## `type_text`

**Official docstring**
`Type literal text using keyboard input. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string",
  "text": "string"
}
```

**Purpose**
Types literal text into the currently focused input area.

**Semantics**
- This is not the same as `set_value`
- `type_text` simulates textual entry through keyboard input
- It requires the correct field/control to already have focus

**When it is preferable**
- apps that react to keystroke-by-keystroke typing
- editors or search boxes where actual input events matter
- places where `set_value` is unsupported

**When `set_value` is preferable**
- accessibility-exposed text fields that can be set directly
- when we want deterministic replacement of a field’s contents
- when the app reacts properly to value-setting without per-key events

**Expected response**
Usually updated app state or success/error info.

**Caveats**
- Focus-dependent
- Can append rather than replace existing text if field contents aren’t selected/cleared
- May trigger app shortcuts if focus is wrong

---

## `set_value`

**Official docstring**
`Set the value of a settable accessibility element. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string",
  "element_index": "string",
  "value": "string"
}
```

**Purpose**
Directly assigns a value to an accessibility element that supports being set.

**Likely target controls**
- text fields
- search boxes
- maybe sliders or numeric inputs if exposed as settable accessibility values

**Example usage pattern**
1. `get_app_state`
2. find an input field with `settable`
3. call `set_value` on its `element_index`

The Music app-specific hint explicitly recommended this flow for search:
- click the Search row
- use `set-value` on the search text field

That’s a strong signal that `set_value` is the preferred primitive for certain app search boxes.

**Difference from `type_text`**
`set_value`:
- targets a specific element by identity
- does not depend as much on keyboard focus
- is more declarative

`type_text`:
- depends on focus
- generates actual typing behavior
- is better when incremental key events matter

**Expected response**
Usually updated state or success/error text.

**Failure modes**
- element is not actually settable
- stale `element_index`
- app rejects programmatic value updates
- value assignment occurs but UI action does not auto-submit

---

## `scroll`

**Official docstring**
`Scroll an element in a direction by a number of pages. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "app": "string",
  "direction": "string",
  "element_index": "string",
  "pages": "integer (optional)"
}
```

**Parameters**
- `direction`: `up`, `down`, `left`, or `right`
- `element_index`: target scrollable accessibility element
- `pages`: optional, default `1`

**Purpose**
Performs scrolling on a particular scrollable container, not just generic wheel input.

**Why this matters**
Desktop UIs often contain multiple nested scroll regions. By targeting an element, this tool can scroll the intended pane rather than whatever happens to be under the mouse.

**Observed evidence**
In Apple Music, the accessibility tree exposed scroll areas with secondary actions:
- `Scroll Up`
- `Scroll Down`

The app-specific guidance also said navigation scrolling should target the scroll element and even suggested parallel page scrolls for speed.

**Expected response**
Usually updated app state.

**Caveats**
- You must choose the correct scrollable element
- If you scroll the wrong container, the target item may not appear
- Best to inspect the tree for `scroll area` elements first

---

## `perform_secondary_action`

**Official docstring**
`Invoke a secondary accessibility action exposed by an element. This tool is part of plugin 'Computer Use'.`

**Input**
```json
{
  "action": "string",
  "app": "string",
  "element_index": "string"
}
```

**Purpose**
This is the advanced accessibility hook. Some elements expose actions beyond the default click/press. This tool lets me invoke them by name.

**Examples of secondary actions observed in state**
- `Raise`
- `Scroll Up`
- `Scroll Down`
- `Collapse`
- `zoom the window`
- `Move next`
- `Remove from toolbar`

These were attached to various controls in Apple Music.

**Why it exists**
Many desktop UI elements expose semantic actions not representable as a simple click:
- expanding/collapsing disclosure rows
- scrolling a region directly
- raising a window
- toolbar customization operations
- special accessibility actions on controls

**Expected response**
Usually updated state or success/error text.

**Technical significance**
This tool is often more precise than coordinate gestures because it speaks the accessibility action language of the app.

---

## Common response patterns

The tool definitions give exact input schemas, but not strict output schemas. From actual use, responses typically fall into three buckets:

**1. Full refreshed state**
Most common after successful UI-affecting actions.
Contains:
- app/window metadata
- full accessibility tree
- focused element
- screenshot

**2. Text-only status/error**
Examples I saw:
```text
Apple event error -10005: cannotClickOffscreenElement
Apple event error -10005: noWindowsAvailable
```

**3. Mixed result**
A textual header plus updated state dump.

So the safest way to think about responses is:
- they are operational, not strongly typed API-return objects
- successful action calls often behave like “act + refresh”
- failures may be direct OS/application accessibility errors

## Accessibility tree anatomy

From `get_app_state`, element records can include these fields:

- numeric index: the handle used later as `element_index`
- role/type: `button`, `text`, `container`, `row`, `scroll area`, `slider`, `menu bar`, etc.
- state flags: `selected`, `disabled`, `expanded`, `settable`
- `Description`
- `Value`
- `ID`
- `Help`
- secondary actions list

Example:
```text
77 button Play
```

More detailed example:
```text
92 container Description: Mini Player, ID: Music.miniPlayer.contentView[viewState=mini,isPlaying=false]
```

**Important nuance**
The `ID` fields are app-provided accessibility identifiers, but I do not pass those IDs directly into the tools. The tools take `element_index`, not `ID`. So the `ID` is informative for me, but the actionable handle is the numeric snapshot index.

## Window and session semantics

A few technical implications emerge from the tooling behavior:

**Per-app session**
`get_app_state` “starts an app use session if needed,” suggesting the plugin maintains some session context per target app.

**Key window targeting**
The model only sees and acts against the app’s key window. If a modal sheet opens, that may become the primary interaction surface.

**Turn-based refresh requirement**
Because I must call `get_app_state` once per assistant turn, the system is designed around fresh visual/accessibility context rather than blind action chaining across turns.

**App identity resolution**
The `app` field accepts either:
- human-readable app name
- bundle id

In practice, bundle ids can be more stable for repeated interaction.

## Reliability hierarchy

In general, from most robust to least:

1. `perform_secondary_action` on the right element
2. `set_value` on a settable control
3. `click` by `element_index`
4. `press_key` with known focus
5. `type_text` with known focus
6. `scroll` on the correct scroll area
7. `click` by coordinates
8. `drag` by coordinates

That ordering is not a formal guarantee, but it matches how semantic vs geometric automation typically behaves and how this plugin performed in practice.

## Failure modes and debugging strategy

Common classes of failure:

- stale state: element indices no longer valid after UI change
- offscreen target: accessibility knows the item, but it is not interactable
- wrong window: app has changed windows or no key window is available
- wrong focus: key presses or typing go to the wrong place
- ambiguous scroll region: correct control not revealed
- app-specific loading delay: UI not ready yet

**Typical recovery loop**
1. Re-run `get_app_state`
2. Re-identify the correct element in the new tree
3. Prefer element-based action over coordinates
4. If needed, switch from app name to bundle id
5. Use app-specific guidance if the tool returned it

That is exactly what happened with Apple Music:
- first-run sheet appeared
- I clicked through setup
- a tile click failed offscreen
- coordinate click failed with a window-resolution error
- refreshed app state
- switched to bundle id
- used an element click that navigated correctly
- clicked the `Play` button element
- verified success by observing the mini-player now showing `Pause` and track metadata

## How I would document these as operational contracts

**Strongly specified**
- tool names
- input arguments
- required/optional fields
- docstrings
- that `get_app_state` must be called first each turn

**Loosely specified**
- response schema
- stability of element indices
- exact error taxonomy
- exact screenshot encoding details
- whether actions always return a full refreshed tree

So from an API-design perspective, this is a “structured inputs, semi-structured operational outputs” system.

## Example workflows

**Search and open something**
1. `get_app_state(app)`
2. `click(element_index=search row)`
3. `set_value(element_index=search field, value="query")`
4. `get_app_state(app)` if results need to refresh
5. `click` or `double-click` result item

**Dismiss a modal**
1. `get_app_state(app)`
2. identify modal buttons or sheet controls
3. `click(element_index=...)` or `press_key("Escape")`

**Play a track in Music**
1. `get_app_state("Music")`
2. navigate via element clicks
3. if a track row must be double-clicked, use `click_count: 2`
4. verify player changed from `Play` to `Pause`

If you want, I can turn this into one of two more technical follow-ups:
- a machine-readable OpenAPI-style spec for these tools
- a “how to build a robust agent on top of them” design guide with retry logic and state-machine patterns