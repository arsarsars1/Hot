# Fan Control: lifecycle preferences

**Status:** implemented  
**Parent:** [fan-control-sleep-wake-resume.md](fan-control-sleep-wake-resume.md)

## Goal

- **Quit / restart:** always hand fans back to System (not optional).
- **Sleep / wake and launch:** user-selectable in Preferences.

## Scope

| Phase | Work | Status |
|---|---|---|
| 1 | Defaults keys + register defaults (resume after sleep ON; restore on launch OFF) | shipped |
| 2 | Gate wake resume on preference; optional restore on launch from saved mode | shipped |
| 3 | Preferences UI: Fan Control checkboxes | shipped |
| 4 | Update sleep-wake plan note; Debug build | shipped |

## Behavior

| Event | Behavior |
|---|---|
| Quit / app restart | Always `restoreAutomatic()` when cooling was active |
| Sleep | Always hand to System (helper loses heartbeats) |
| Wake | If **Resume fan control after sleep** is on → re-apply after ~3s |
| Launch | If **Restore fan control when Hot launches** is on → re-apply after ~2s (no prompt) |

## Preferences

Hot Preferences → **Fan Control**:
- Resume fan control after sleep (default on)
- Restore fan control when Hot launches (default off)

## Verify

```bash
xcodebuild -project Hot.xcodeproj -scheme Hot -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Session log

- 2026-09-26: User asked for System handover on restart + Preferences for other scenarios. Added resume-after-sleep + restore-on-launch toggles.
