# Fan Control status-menu submenu

**Status:** implemented  
**Parent:** [fan-control-port.md](fan-control-port.md)  
**Related:** [fan-control-ui-polish.md](fan-control-ui-polish.md) (earlier choice locked “no submenu”; this plan supersedes that for menu IA)

## Goal

Replace flat **Fan Control Window…** with a nested status-menu control surface:

```
Fan Control ▸
  System
  Manual ▸          → % presets + slider
  Curve ▸           → Apply saved curve / Edit Curve…
  ────────
  Allow Fan Control… (when needed)
  Fan Control Window…
```

Keep the existing sidebar (Fan ▸) and detached window; menu is a fast path, not a full curve editor.

## Log finding (helper unavailable)

| Evidence | Meaning |
|---|---|
| Running app = Debug DerivedData, **adhoc** (`TeamIdentifier=not set`) | Not the signed `/Applications` copy |
| Helper pid 5139 from SMAppService, signed `KETV72YBM9` | Daemon OK, owned by `/Applications/Hot.app` |
| `SMAppService … Unable to find service status … error: 22` every ~1s | Adhoc Debug cannot resolve daemon registration |
| `fan-control.log`: last good XPC at 17:41; `connection_invalidated` 18:41; `app_launch` 19:00 with **no** `connection_opened` | Current session never talked to helper |
| Helper `setCodeSigningRequirement(appCodeRequirement)` | Even direct XPC would reject adhoc client |

**Fix for control:** run signed `/Applications/Hot.app` (or Debug with Apple Development + team `KETV72YBM9`). Unsigned Debug can only probe RPM.

## Scope

| Phase | Work | Status |
|---|---|---|
| 0 | Diagnose helper unavailable; clearer unsigned/adhoc message | shipped |
| 1 | XIB: Fan Control ▸ shell (System / Manual / Curve / Window…) | shipped |
| 2 | Wire System + Manual % presets + slider → `FanControlService` | shipped |
| 3 | Curve submenu: Apply saved / Edit Curve… | shipped |
| 4 | Checkmarks + disable when helper unavailable | shipped |

## What shipped

- `FanControlStatusMenuController` — builds Fan Control ▸ hierarchy on open
- MainMenu: **Fan Control** submenu (replaces flat Window item; Window remains inside)
- `FanControlService.clientMeetsCodeRequirement` — skips SMAppService spam; UI explains signed-app requirement
- Manual: 0/10/25/50/75/100% + slider (apply on mouse-up)
- Curve: Apply Saved Curve / Edit Curve…

## Out of scope

- Full curve point editors inside NSMenu
- Replacing the Fan ▸ sidebar panel

## Verify

```bash
# Prefer signed app for control:
open /Applications/Hot.app --args --open-fan-control
open ~/Library/Logs/Hot/fan-control.log

# Expect connection_opened after launch when signed + Login Items enabled
```

1. Status menu → Fan Control ▸ System / Manual ▸ / Curve ▸  
2. Manual preset applies when helper enabled  
3. Unsigned Debug shows codesign-aware message, not a mystery failure  

## Session log

- 2026-09-18: User requested submenu + helper-unavailable review while Debug `--open-fan-control` running. Root cause: adhoc Debug vs signed system helper / SMAppService error 22.
- 2026-09-18: Implemented status-menu submenu + signing mismatch messaging; Debug `CODE_SIGNING_ALLOWED=NO` build succeeded.
- 2026-09-18: Installed sole signed Release to `/Applications/Hot.app`; purged DerivedData + `/tmp` Hot builds. Fixed `evaluateClientCodeRequirement` to use `kSecCSSigningInformation` (flags 0 omitted team ID). Relaunch shows `connection_opened`.
