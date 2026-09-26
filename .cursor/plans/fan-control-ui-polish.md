# Fan Control UI polish (2A)

**Status:** implemented  
**Source:** `/Users/abdulrehman/.cursor/plans/fan_control_ui_polish_c009d4ec.plan.md`  
**Choice locked (superseded):** Window polish first. Status-menu Fan Control ▸ submenu shipped in [fan-control-status-menu.md](fan-control-status-menu.md).  
**Parent:** [fan-control-port.md](fan-control-port.md)

## Goal

Make `FanControlPanelController` dense and intentional (RPM cards, clearer mode/status, less empty space). Same panel powers the detached window and compact sidebar.

## Scope

| Phase | Work | Status |
|---|---|---|
| 1 | RPM card strip + cooling status pill | shipped |
| 2 | Tighten insets/title/spacing; hide unused mode height; shrink window | shipped |
| 3 | Manual row + cleaner slider; shorten safety copy | shipped |
| 4 | Build Debug + smoke window / sidebar / Apply Curve | shipped (build OK; UI smoke manual) |

## What shipped

- `FanControlRPMCardView` — per-fan cards (icon, name, large RPM, optional target)
- Status pill (`System` / `Manual · N%` / `Curve · N%`)
- Window drops redundant title; compact sidebar keeps accent + title
- Tighter insets; curve height constraint only when Curve mode active
- Manual: “Fan speed” + `%` on one row; tick-free slider (still 5% steps)
- Safety blurb one line + full text in tooltip
- Default window ~440×420, min 400×360

## Out of scope

- New Fan Control NSMenu submenu
- Full visual theme overhaul
- Helper / XPC / Apply Curve logic changes

## Verify

```bash
xcodebuild -project Hot.xcodeproj -scheme Hot -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

1. Fan Control Window — Manual: RPM cards, tight layout, no large empty top gap
2. Switch Curve — editors work; Apply Curve completes
3. Status menu Fan row ▸ — compact panel looks good
4. Dark/light: cards use `controlBackgroundColor`

## Session log

- 2026-09-17: Implemented UI polish in `FanControlWindowController.swift`; Debug build succeeded (unsigned).
- 2026-09-17: Launched Debug `Hot.app --open-fan-control` for visual smoke (process alive). Manual check: Manual layout, Curve Apply, status-menu sidebar.
