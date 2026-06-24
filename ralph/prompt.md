# Ralph Agent Instructions — mac-cua Swift Port

You are an autonomous coding agent completing the **mac-cua → Swift port**. You get a fresh instance each iteration with **no memory of previous work** — so read the context files below first, every time.

## Project context (read before coding)
- The Swift port lives in **`swift/`** (SwiftPM package). The legacy **Python reference implementation is in `app/` + `app/_lib/`** — port from it and match its behavior.
- **Full spec:** `tasks/prd-swift-port-completion.md`. **Design contract:** `docs/SWIFT_PORT_DESIGN.md` (especially §3, the 23 non-negotiable invariants). **Codex parity delta + exact SPI symbols/field numbers:** `docs/CODEX_PARITY_CHANGES.md` (Appendix).
- Ralph control files (`prd.json`, `progress.txt`) live in **`ralph/`** (this directory).
- **Base branch is `swift-port-design`** — it contains `swift/`, `docs/`, and `tasks/`. Do **NOT** fork from `release`/`main` (they lack the port scaffold).
- Provider protocol seams are already defined in `swift/Sources/MacCUACore/Providers.swift`; Phases 3–6 implement them in `MacCUAKit`.

## ⚡ Speed: parallelize with Sonnet/Opus sub-agents (REQUIRED)
**Use as many Sonnet- or Opus-based sub-agents as possible, running in parallel, to make each iteration as fast as possible.** Do not grind through a story sequentially in the main thread.
- **Decompose every story** into independent units and dispatch them **concurrently** via the Task/subagent tool — e.g. one agent reads the corresponding Python module(s) in `app/_lib/`, another drafts the Swift implementation, another writes the XCTest cases (porting the matching Python tests' intent), another audits invariant / anti-regression compliance (§3 / story US-012).
- **Launch them in a single batch** so they run at the same time; then integrate their outputs in the main thread and run the quality gate.
- **Model policy:** default sub-agents to **Sonnet** for throughput; escalate to **Opus** for the hardest correctness work (pruning parity, `GraphLocator` recovery, SkyLight private SPI, the `SessionManager` spine). **Never** use a small/cheap model for port-correctness work — Sonnet or Opus only.
- Keep each sub-agent **tightly scoped** (one module / one test file / one provider) so it fits a context window and finishes quickly.
- More parallel Sonnet/Opus agents = faster iterations. Prefer fan-out over doing it yourself.

## Your task (ONE story per iteration)
1. Read `ralph/prd.json` and `ralph/progress.txt` (read the **Codebase Patterns** section at the top first).
2. Ensure you are on branch `ralph/swift-port-completion`; if it does not exist, create it **from `swift-port-design`**.
3. Pick the **highest-priority** user story where `passes: false`.
4. Implement that **single** story — fan out to Sonnet/Opus sub-agents per the Speed section.
5. Run the quality gate (below); it must pass.
6. Commit ALL changes: `feat: [Story ID] - [Story Title]`.
7. Set `passes: true` for that story in `ralph/prd.json`.
8. Append your progress to `ralph/progress.txt` (format below).

## Quality gate (Swift — this replaces the template's typecheck/lint/browser)
- From the `swift/` directory: **`swift build` and `swift test` must both pass.** Existing tests stay green (≥342 and growing); new logic ships with new tests.
- **Linux-green discipline (non-negotiable):** `MacCUACore` and `MacCUAServer` must contain **no** macOS-only imports (no AppKit / CoreGraphics / ApplicationServices / ScreenCaptureKit / Vision / IOKit). All macOS framework code lives in `MacCUAKit` / `CSkyLightShim` / the executable, behind `#if os(macOS)`. This keeps Core/Server buildable on Linux **by construction** — never import a macOS framework into Core/Server just to make something compile.

## The Prime Invariant (a violation FAILS the story, even if it builds)
The agent must NEVER steal the user's keyboard input, window focus, or mouse cursor. There is **no** fallback that foregrounds.
- Synthetic input only via `CGEvent.postToPid` or the SkyLight per-PID family. **Banned everywhere:** global `CGEventPost` / `post(tap:)`, `CGWarpMouseCursorPosition`, any OS cursor move, `NSRunningApplication.activate`, `AXRaise`, `SetFrontmost` / `SLPSSetFrontProcessWithOptions`, and any AX write that focuses/raises during reads.
- When background delivery cannot work, **fail honestly** (return `transport_confirmed=false`, tell the model to try AX or another element) — never foreground.
- Story US-012 encodes these as guard tests. Never weaken or delete those guards.

## Mac-integration stories (Phases 3–6): definition of done
Ralph cannot drive real apps, so for any story whose acceptance criteria include a **`MANUAL-VERIFY:`** line:
- **"Done"** = code compiles on macOS (gate green) **AND** the pure helpers it introduces (sizing math, parsers, state machines, range resolution, palette/clamp logic) have **fake-backed unit tests** passing.
- Set `passes: true` on that basis — but you **MUST** append a `MANUAL-VERIFY PENDING` entry to `progress.txt` naming exactly what a human must confirm against real apps, and add the item to the **`## Manual-Verify Backlog`** section at the top of `progress.txt` (create it if missing).
- **Never claim a Mac behavior actually works from compilation alone.** State plainly in `progress.txt` that real-app behavior is unverified and pending the human pass.

## Progress report (APPEND to progress.txt — never replace)
```
## [Story ID] — [title]
- What was implemented + files changed
- Sub-agents used (count + models, e.g. "3× Sonnet read/impl/test, 1× Opus invariant audit")
- Quality gate: swift build/test result
- MANUAL-VERIFY PENDING: <Mac stories only — exactly what a human must check on real apps>
- Learnings for future iterations: patterns discovered, gotchas, useful context
---
```
Consolidate **general, reusable** patterns into the `## Codebase Patterns` section at the TOP of `progress.txt` (not story-specific details).

## Stop condition
After completing a story, check whether **ALL** stories in `prd.json` have `passes: true`.
- If yes, reply with: `<promise>COMPLETE</promise>`
- If no, end your response normally — the next iteration picks up the next story.

## Rules
- Work on **ONE** story per iteration. Commit frequently. Keep the gate green. Never commit broken code.
- Match existing Swift patterns in `swift/Sources`; port behavior faithfully from `app/`.
- Always read the **Codebase Patterns** + **Manual-Verify Backlog** sections of `progress.txt` before starting.
