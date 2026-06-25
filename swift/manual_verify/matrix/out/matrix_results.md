# Swift Port — Tool×App Verification Matrix

- **Binary:** `/usr/local/bin/mac-cua`
- **Timestamp:** 2026-06-25T14:30:00Z
- **macOS:** macOS 27.0.0 (Darwin)
- **Totals:** 8 cells (3 PASS · 2 FAIL · 1 N/A · 2 OBSERVE)

## Summary

| PASS | FAIL | N/A | OBSERVE |
|---|---|---|---|
| 3 | 2 | 1 | 2 |

## Grid

Legend: ✅ PASS · ❌ FAIL · ➖ N/A · 👁 OBSERVE · · not exercised

| Tool \ App | TextEdit | Safari | VS Code | Macs Fan Control |
|---|---|---|---|---|
| list_apps | ✅ | · | · | · |
| get_app_state | ✅ | · | · | ❌ |
| click | · | · | 👁 | · |
| type_text | ❌ | · | · | · |
| set_value | · | ✅ | ➖ | · |
| scroll | · | 👁 | · | · |
| perform_secondary_action | · | · | · | · |

## Failures & Invariant Violations

_Invariant violations are **port regressions** — the highest-priority signal. Fix these first._

### ❌ TextEdit · type_text
- note: text typed but isolation invariants broke
- invariant violations (port regressions):
  - **CURSOR WARP: real cursor moved (120,80)->(640,400)**
  - **FOREGROUND: frontmost changed com.apple.finder->com.apple.TextEdit**

### ❌ Macs Fan Control · get_app_state
- note: Qt exposes zero AX; expected clean failure but driver crashed
- (no invariant violations — functional effect missing)

## Detail

### TextEdit
- TextEdit · list_apps — ✅ PASS — enumerated 42 apps
- TextEdit · get_app_state — ✅ PASS — tree + screenshot returned
- TextEdit · type_text — ❌ FAIL — text typed but isolation invariants broke — violations: CURSOR WARP: real cursor moved (120,80)->(640,400); FOREGROUND: frontmost changed com.apple.finder->com.apple.TextEdit

### Safari
- Safari · set_value — ✅ PASS — URL bar set to https://example.com
- Safari · scroll — 👁 OBSERVE — web-area scrolled; confirm no focus flash

### VS Code
- VS Code · click — 👁 OBSERVE — ghost cursor over editor; confirm overlay renders
- VS Code · set_value — ➖ N/A — Electron rejects set_value (documented incompatibility)

### Macs Fan Control
- Macs Fan Control · get_app_state — ❌ FAIL — Qt exposes zero AX; expected clean failure but driver crashed
