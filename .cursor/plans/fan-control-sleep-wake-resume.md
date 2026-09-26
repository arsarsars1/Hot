# Fan Control: resume selection after sleep/wake

**Status:** implemented  
**Parent:** [fan-control-port.md](fan-control-port.md)

## Problem

After lid close / system sleep, Manual or Curve fan control was lost on wake; the menu showed System.

## Root cause

`FanControlService.systemWillSleep` restores automatic (SMC) control before sleep — intentional, since the helper
loses heartbeats while asleep. There was no `didWake` handler, so the user's configuration was never re-applied.

## Scope

| Phase | Work | Status |
|---|---|---|
| 1 | Capture active configuration (snapshot, fallback to saved defaults) on `willSleep` | shipped |
| 2 | Observe `NSWorkspace.didWakeNotification`; re-apply after 3s if helper is `.enabled` (never prompts) | shipped |
| 3 | Cancel pending resume when user applies/restores anything in the meantime | shipped |
| 4 | Status menu **System** now persists `fanControlMode = system` | shipped |

## Verify

```bash
xcodebuild -project Hot.xcodeproj -scheme Hot -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Manual (signed `/Applications/Hot.app`):
1. Fan Control ▸ Manual ▸ 50% (or Apply Saved Curve)
2. `pmset sleepnow` or close lid; wake
3. Within ~3s fans return to the selection; menu checkmark shows Manual/Curve
4. `~/Library/Logs/Hot/fan-control.log` shows `sleep_restore` then `wake_resume`

## Session log

- 2026-09-26: User reported selection forgotten after sleep. Added wake resume + System persistence; Debug build succeeded.
- 2026-09-26: Follow-up — quit/restart stays System-only; sleep/launch resume is optional in Preferences. See [fan-control-lifecycle-preferences.md](fan-control-lifecycle-preferences.md).
