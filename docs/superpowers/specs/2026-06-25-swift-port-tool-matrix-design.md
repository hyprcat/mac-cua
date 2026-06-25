# Swift Port — Cross-App Tool×App Verification Matrix

**Date:** 2026-06-25
**Branch:** ralph/swift-port-completion
**Status:** Approved design

## Goal

Verify that every action mac-cua exposes works correctly across a representative
suite of macOS apps spanning every rendering engine, **and** that the background
invisibility invariants (the whole reason for the Swift port) hold for each
action. Produce a **re-runnable harness** so the suite can be re-executed on
every build / future macOS version, plus a human-eye observation checklist for
the few invariants only a person can judge.

## Pass criteria

For each (app, tool) cell:

- **PASS** — functional assertion true (the action had its intended effect,
  proven by a before/after `get_app_state`) **and** all auto-invariant probes green.
- **FAIL** — effect missing, OR an invisibility invariant violated. An invariant
  violation is a **port regression** and the highest-priority signal.
- **N/A** — documented incompatibility (e.g. Electron rejects `set_value`,
  Qt exposes no AX). Recorded with the reason, never silently skipped.
- **OBSERVE** — passed all automation, awaiting human visual confirmation
  (ghost-cursor rendering / no-flash).

## Invariants

Auto-checked by the harness around **every** action via OS-level probes
(PyObjC / Quartz):

| Invariant | Probe |
|---|---|
| App never foregrounds | `NSWorkspace.frontmostApplication` unchanged before→after |
| Real cursor never warps | `CGEventGetLocation` unchanged before→after |
| Target window never raised | window order from `CGWindowListCopyWindowInfo` stable |

Human-eye only (collected into `observation_checklist.md` with screenshots):

| Invariant | Why human |
|---|---|
| Ghost cursor renders & looks correct | visual judgment of overlay appearance |
| No sub-second focus flash | only a person perceives a transient flash |

## App suite (representative per engine)

| App | Engine | Exercises |
|---|---|---|
| TextEdit | Native Cocoa | Gold-standard AX; all tools; settable text area |
| Notes | Native Cocoa | Real `.general` clipboard, complex toolbar |
| Finder | Native Cocoa | Sparse AX / desktop edge cases |
| Safari | WebKit | Browser AX, URL-bar set_value, web-area scroll |
| Chrome | Chromium | Distinct browser engine from WebKit |
| VS Code | Electron | set_value-rejected, double-click-fail, webview-scroll-block paths |
| Macs Fan Control | Qt | Graceful-failure path (zero AX) — assert it fails *cleanly* |

## Tools under test (13)

`list_apps`, `get_app_state`, `click`, `type_text`, `press_key`, `set_value`,
`scroll`, `drag`, `select_text`, `clipboard`, `wait`, `perform_secondary_action`,
`batch`.

Groups:
- **Trivial/automatic:** `list_apps`, `get_app_state`, `wait`
- **Action + auto-invariant probe:** `click`, `type_text`, `press_key`,
  `set_value`, `scroll`, `drag`, `select_text`, `clipboard`,
  `perform_secondary_action`
- **Meta:** `batch` — chains actions; verify sequential execution + stop-at-first-failure

## Architecture

```
swift/manual_verify/matrix/
  mcp_client.py    # MCP stdio client (adapted from manual_verify/driver.py)
  probes.py        # frontmost / cursor / window-order snapshots; diff() -> violations
  locate.py        # parse get_app_state tree -> elements; find by role/title/value/settable predicate
  scenarios.py     # per-app fixture setup + per-tool recipe + functional assertion
  runner.py        # orchestrator: launch app, per tool {probe-before, act, probe-after, assert, record}
  report.py        # write matrix_results.md + .json + per-cell screenshots + observation_checklist.md
  samples/         # captured real trees for offline unit tests of locate.py
  out/             # generated artifacts (gitignored)
```

### Data contracts (shared between modules)

```python
# locate.py
@dataclass
class Element:
    index: int          # element_index (snapshot-local)
    role: str           # "text area", "button", "combo box", ...
    label: str          # title/description text after the role
    value: str | None
    placeholder: str | None
    settable: bool
    settable_type: str | None   # "string" / "float" / ...
    secondary_actions: list[str]
    depth: int          # tab-indent depth

def parse_tree(state_text: str) -> list[Element]: ...
def find(elements, *, role=None, label=None, label_contains=None,
         settable=None, has_action=None) -> Element | None: ...

# probes.py
@dataclass
class Snapshot:
    frontmost_bundle: str
    cursor: tuple[float, float]
    window_order: list[int]   # window numbers front-to-back

def snapshot() -> Snapshot: ...
def diff(before: Snapshot, after: Snapshot) -> list[str]:  # [] == clean
    ...  # returns human-readable invariant violations

# scenarios.py
@dataclass
class CellResult:
    app: str; tool: str
    status: str          # PASS / FAIL / N/A / OBSERVE
    functional: bool
    invariant_violations: list[str]
    note: str
    screenshot_path: str | None
```

### Tree serialization format (ground truth, captured 2026-06-25)

Element line shape (tab-indented for hierarchy):
```
<index> <role> <label>[, Placeholder: <p>][ (settable, <type>)][, Value: <v>][, ID: <id>][, Secondary Actions: <a>, <b>]
```
The tree text ends with a line like `The focused UI element is <index> <role>.`
`get_app_state` returns **two** content blocks: the tree text and a screenshot
image. Fixtures must navigate apps to a known state first (e.g. TextEdit cold-starts
to an "Open" panel; the scenario clicks "New Document" to reach the editor).

## Execution model

The **build** phase parallelizes across the independent leaf modules
(`probes`, `locate`, `report`, `scenarios`) — pure Python, unit-tested offline
against `samples/`. The **run** phase is **strictly serial**: a single MCP driver
drives one real app at a time. Parallel live drivers would collide on the shared
desktop and violate the very isolation we test, so the matrix runs single-threaded.

## Out of scope (YAGNI)

No per-app deep feature testing, no performance benchmarking, no CI wiring across
macOS versions. Just the tool×app correctness + invariant grid, made re-runnable.
