"""Shared result contract + report writers for the Tool×App verification matrix.

Stdlib only. Produces three human-skimmable artifacts:
  * matrix_results.md       — grid + failures + detail (read this first)
  * matrix_results.json     — machine-readable {meta, results}
  * observation_checklist.md — human-eye OBSERVE invariants (ghost cursor / no-flash)

See docs/superpowers/specs/2026-06-25-swift-port-tool-matrix-design.md
("Pass criteria", "Invariants", the CellResult contract).
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path


# --- Status vocabulary -------------------------------------------------------

PASS = "PASS"
FAIL = "FAIL"
NA = "N/A"
OBSERVE = "OBSERVE"

_GLYPH = {
    PASS: "✅",
    FAIL: "❌",
    NA: "➖",
    OBSERVE: "👁",
}
_BLANK = "·"  # (app, tool) combo not exercised


@dataclass
class CellResult:
    """One (app, tool) cell of the verification matrix."""

    app: str
    tool: str
    status: str  # PASS / FAIL / N/A / OBSERVE
    functional: bool
    invariant_violations: list[str] = field(default_factory=list)
    note: str = ""
    screenshot_path: str | None = None


# --- Helpers -----------------------------------------------------------------


def _counts(results: list[CellResult]) -> dict[str, int]:
    out = {PASS: 0, FAIL: 0, NA: 0, OBSERVE: 0}
    for c in results:
        out[c.status] = out.get(c.status, 0) + 1
    return out


def _cell_lookup(results: list[CellResult]) -> dict[tuple[str, str], CellResult]:
    """Map (app, tool) -> result. Last write wins on duplicates."""
    table: dict[tuple[str, str], CellResult] = {}
    for c in results:
        table[(c.app, c.tool)] = c
    return table


def _md_escape_cell(text: str) -> str:
    """Keep pipe characters from breaking Markdown table columns."""
    return text.replace("|", "\\|").replace("\n", " ")


# --- Section renderers -------------------------------------------------------


def _render_grid(
    results: list[CellResult], apps: list[str], tools: list[str]
) -> str:
    table = _cell_lookup(results)
    header = "| Tool \\ App | " + " | ".join(apps) + " |"
    sep = "|" + "---|" * (len(apps) + 1)
    lines = [header, sep]
    for tool in tools:
        cells = []
        for app in apps:
            cell = table.get((app, tool))
            cells.append(_GLYPH.get(cell.status, _BLANK) if cell else _BLANK)
        lines.append("| " + tool + " | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def _render_summary(counts: dict[str, int]) -> str:
    header = "| PASS | FAIL | N/A | OBSERVE |"
    sep = "|---|---|---|---|"
    row = (
        f"| {counts.get(PASS, 0)} | {counts.get(FAIL, 0)} "
        f"| {counts.get(NA, 0)} | {counts.get(OBSERVE, 0)} |"
    )
    return "\n".join([header, sep, row])


def _render_failures(results: list[CellResult]) -> str:
    fails = [c for c in results if c.status == FAIL]
    if not fails:
        return "_No failures. All exercised cells passed automation._"
    blocks = []
    for c in fails:
        head = f"### ❌ {c.app} · {c.tool}"
        body = []
        if c.note:
            body.append(f"- note: {c.note}")
        if c.invariant_violations:
            body.append("- invariant violations (port regressions):")
            for v in c.invariant_violations:
                body.append(f"  - **{v}**")
        else:
            body.append("- (no invariant violations — functional effect missing)")
        blocks.append(head + "\n" + "\n".join(body))
    return "\n\n".join(blocks)


def _render_detail(
    results: list[CellResult], apps: list[str], tools: list[str]
) -> str:
    table = _cell_lookup(results)
    # App ordering: given apps first (in order), then any stragglers.
    seen_apps = list(apps)
    for c in results:
        if c.app not in seen_apps:
            seen_apps.append(c.app)
    blocks = []
    for app in seen_apps:
        app_cells = [c for c in results if c.app == app]
        if not app_cells:
            continue
        # Tool ordering within app: given tools order, then stragglers.
        ordered = []
        for tool in tools:
            if (app, tool) in table and table[(app, tool)].app == app:
                # Only include if this exact app row exists
                cell = next((c for c in app_cells if c.tool == tool), None)
                if cell:
                    ordered.append(cell)
        for c in app_cells:
            if c not in ordered:
                ordered.append(c)
        lines = [f"### {app}"]
        for c in ordered:
            glyph = _GLYPH.get(c.status, _BLANK)
            line = f"- {c.app} · {c.tool} — {glyph} {c.status}"
            if c.note:
                line += f" — {c.note}"
            if c.invariant_violations:
                line += " — violations: " + "; ".join(c.invariant_violations)
            lines.append(line)
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def _render_matrix_md(
    results: list[CellResult],
    apps: list[str],
    tools: list[str],
    meta: dict,
) -> str:
    counts = _counts(results)
    total = len(results)
    parts = []
    parts.append("# Swift Port — Tool×App Verification Matrix")
    parts.append("")
    parts.append(f"- **Binary:** `{meta.get('binary_path', 'unknown')}`")
    parts.append(f"- **Timestamp:** {meta.get('timestamp', 'unknown')}")
    parts.append(f"- **macOS:** {meta.get('macos_version', 'unknown')}")
    parts.append(
        f"- **Totals:** {total} cells "
        f"({counts.get(PASS, 0)} PASS · {counts.get(FAIL, 0)} FAIL · "
        f"{counts.get(NA, 0)} N/A · {counts.get(OBSERVE, 0)} OBSERVE)"
    )
    parts.append("")
    parts.append("## Summary")
    parts.append("")
    parts.append(_render_summary(counts))
    parts.append("")
    parts.append("## Grid")
    parts.append("")
    parts.append("Legend: ✅ PASS · ❌ FAIL · ➖ N/A · 👁 OBSERVE · · not exercised")
    parts.append("")
    parts.append(_render_grid(results, apps, tools))
    parts.append("")
    parts.append("## Failures & Invariant Violations")
    parts.append("")
    parts.append(
        "_Invariant violations are **port regressions** — the highest-priority "
        "signal. Fix these first._"
    )
    parts.append("")
    parts.append(_render_failures(results))
    parts.append("")
    parts.append("## Detail")
    parts.append("")
    parts.append(_render_detail(results, apps, tools))
    parts.append("")
    return "\n".join(parts)


def _render_observation_md(results: list[CellResult]) -> str:
    observes = [c for c in results if c.status == OBSERVE]
    parts = []
    parts.append("# Observation Checklist — Human-Eye Invariants")
    parts.append("")
    parts.append(
        "These cells passed every automated probe but await human visual "
        "confirmation. The automation cannot judge them:"
    )
    parts.append("")
    parts.append(
        "- **Ghost cursor renders & looks correct** — visual judgment of the "
        "overlay cursor's appearance and position."
    )
    parts.append(
        "- **No sub-second focus flash** — only a person perceives a transient "
        "flash as the target app is driven in the background."
    )
    parts.append("")
    parts.append(
        "Check each box once you have eyeballed the linked screenshot (or watched "
        "the live run) and confirmed both invariants hold."
    )
    parts.append("")
    parts.append("## Pending observations")
    parts.append("")
    if not observes:
        parts.append("_none pending_")
    else:
        for c in observes:
            line = f"- [ ] {c.app} · {c.tool} — {c.note or '(no note)'}"
            if c.screenshot_path:
                line += f" — [screenshot]({c.screenshot_path})"
            parts.append(line)
    parts.append("")
    return "\n".join(parts)


# --- Public entry point ------------------------------------------------------


def write_reports(
    results: list[CellResult],
    out_dir: str,
    apps: list[str],
    tools: list[str],
    meta: dict,
) -> dict[str, str]:
    """Write the three matrix artifacts into out_dir. Returns {name: path}."""
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    md_path = out / "matrix_results.md"
    json_path = out / "matrix_results.json"
    obs_path = out / "observation_checklist.md"

    md_path.write_text(_render_matrix_md(results, apps, tools, meta), encoding="utf-8")

    payload = {"meta": meta, "results": [asdict(c) for c in results]}
    json_path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    obs_path.write_text(_render_observation_md(results), encoding="utf-8")

    return {
        "matrix_results.md": str(md_path),
        "matrix_results.json": str(json_path),
        "observation_checklist.md": str(obs_path),
    }


# --- Self-test ---------------------------------------------------------------

if __name__ == "__main__":
    apps = ["TextEdit", "Safari", "VS Code", "Macs Fan Control"]
    tools = [
        "list_apps",
        "get_app_state",
        "click",
        "type_text",
        "set_value",
        "scroll",
        "perform_secondary_action",
    ]

    meta = {
        "binary_path": "/usr/local/bin/mac-cua",
        "timestamp": "2026-06-25T14:30:00Z",
        "macos_version": "macOS 27.0.0 (Darwin)",
    }

    results = [
        CellResult("TextEdit", "list_apps", PASS, True, note="enumerated 42 apps"),
        CellResult(
            "TextEdit", "get_app_state", PASS, True, note="tree + screenshot returned"
        ),
        CellResult(
            "TextEdit",
            "type_text",
            FAIL,
            False,
            invariant_violations=[
                "CURSOR WARP: real cursor moved (120,80)->(640,400)",
                "FOREGROUND: frontmost changed com.apple.finder->com.apple.TextEdit",
            ],
            note="text typed but isolation invariants broke",
        ),
        CellResult(
            "Safari",
            "set_value",
            PASS,
            True,
            note="URL bar set to https://example.com",
        ),
        CellResult(
            "Safari",
            "scroll",
            OBSERVE,
            True,
            note="web-area scrolled; confirm no focus flash",
            screenshot_path="out/safari_scroll.png",
        ),
        CellResult(
            "VS Code",
            "set_value",
            NA,
            False,
            note="Electron rejects set_value (documented incompatibility)",
        ),
        CellResult(
            "VS Code",
            "click",
            OBSERVE,
            True,
            note="ghost cursor over editor; confirm overlay renders",
            screenshot_path="out/vscode_click.png",
        ),
        CellResult(
            "Macs Fan Control",
            "get_app_state",
            FAIL,
            False,
            note="Qt exposes zero AX; expected clean failure but driver crashed",
        ),
    ]

    out_dir = "/Users/affan/mac-cua/swift/manual_verify/matrix/out"
    paths = write_reports(results, out_dir, apps, tools, meta)

    # --- assertions ---
    for name, p in paths.items():
        assert os.path.exists(p), f"missing artifact: {name} ({p})"
        assert os.path.getsize(p) > 0, f"empty artifact: {name} ({p})"

    md_text = Path(paths["matrix_results.md"]).read_text(encoding="utf-8")
    assert (
        "CURSOR WARP: real cursor moved (120,80)->(640,400)" in md_text
    ), "FAIL cursor-warp violation string missing from markdown"
    assert (
        "FOREGROUND: frontmost changed com.apple.finder->com.apple.TextEdit" in md_text
    ), "FAIL foreground violation string missing from markdown"

    for glyph in ("✅", "❌", "➖", "👁"):
        assert glyph in md_text, f"grid missing glyph {glyph}"

    obs_text = Path(paths["observation_checklist.md"]).read_text(encoding="utf-8")
    assert "out/safari_scroll.png" in obs_text, "OBSERVE screenshot link missing"

    json_payload = json.loads(
        Path(paths["matrix_results.json"]).read_text(encoding="utf-8")
    )
    assert json_payload["meta"] == meta, "json meta mismatch"
    assert len(json_payload["results"]) == len(results), "json results count mismatch"

    print("=" * 72)
    print(md_text)
    print("=" * 72)
    print("\nArtifacts written:")
    for name, p in paths.items():
        print(f"  {name}: {p}")
    print("\nPASS — report.py self-test green")
