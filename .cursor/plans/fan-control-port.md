# Fan control port (Vorssaint → Hot)

**Status:** implemented (installed locally to `/Applications/Hot.app`)  
**Scope:** Add System / Manual / Curve fan control to Hot, matching Vorssaint’s safety model and curve-editor UX, without copying GPL-3.0 sources.

## Context

| | Hot (this app) | Vorssaint Utils |
|---|---|---|
| License | MIT | GPL-3.0-or-later |
| Fan RPM | Already reads + graphs | Reads + controls |
| Control | Privileged helper + AppKit panel | Privileged LaunchDaemon + XPC |
| Curve UI | Multi-sensor curves + point temp/% rows | Same behavior (SwiftUI) |
| Deploy | macOS 10.13+ (control needs 13+) | macOS 14+ |

## Approach

Reimplemented under MIT:

1. SMC client + typed encode/decode
2. Privileged helper (`SMAppService` daemon, macOS 13+)
3. Shared AppKit panel (`FanControlPanelController`) — status-menu sidebar + optional window
4. Multi-curve editor: Add Sensor, Add Point, temp + fan-speed values, drag HUD
5. Heartbeat + restore on quit/sleep

## Phases

| Phase | Work | Status |
|---|---|---|
| 1 | Plan + architecture notes | shipped |
| 2 | Models, policy, SMC, hardware, XPC, helper | shipped |
| 3 | `FanControlService` + AppKit window + menu | shipped |
| 4 | Embed helper (build phase + LaunchDaemon plist) | shipped |
| 5 | Lifecycle: recover on launch, restore on quit/sleep | shipped |
| 6 | About copy | shipped |
| 7 | Local signed install to `/Applications` | shipped |
| 8 | Multi-curve editor + point temperature/fan-speed UI | shipped |
| 9 | Fix Fan Control open crash (Auto Layout) + SMC race | shipped |
| 10 | Fix stuck **Working…** button; sidebar in status menu | shipped |
| 11 | Fix blank temperature/graphs (sidebar orphaned metrics) | shipped |
| 12 | Apply Curve hang: re-apply while cooling, XPC interrupt, temp-key cache, diagnostics | shipped |
| 13 | UI polish (RPM cards, tighter layout) — see [fan-control-ui-polish.md](./fan-control-ui-polish.md) | shipped |
| 14 | Status-menu Fan Control ▸ submenu — see [fan-control-status-menu.md](./fan-control-status-menu.md) | shipped |

## Session log

- 2026-09-14: MIT fan-control stack; helper embed; Login Items flow.
- 2026-09-14 (evening): Fixed GitHubUpdates build; signed install to `/Applications`.
- 2026-09-14 (evening): Curve UI parity — multi-sensor curves, Add Point/Sensor, Temperature + Fan speed rows, drag HUD (`°C · %`); policy helpers `nextCurvePoint` / `addingCurvePoint`; reinstalled `/Applications/Hot.app`.
- 2026-09-14 (evening): **Fan Control not opening** — crash on window init: Auto Layout constraints activated before views shared a common ancestor (slider width, curve editor / point-row widths). Also serialized `SMCKit` `readAllKeys` (`@synchronized`) after concurrent ThermalLog + InfoViewController crashes. Added `Scripts/test-fan-control.swift` + `--open-fan-control` launch hook; verified window opens and process stays alive; reinstalled `/Applications/Hot.app`.
- 2026-09-14 (evening): **Working… stuck** — status refresh bumped XPC request generation while Apply was in flight, so `isWorking` never cleared. Fixed by skipping refresh during work, always clearing `isWorking` on completion, XPC error → completion, 12s timeout. **Sidebar UX** — `FanControlPanelController` embeds beside status metrics when clicking Pressure / Temperature / Fan rows; accent bar + chevron; menu item renamed **Fan Control Window…**. Reinstalled `/Applications/Hot.app`.
- 2026-09-14 (evening): **Blank temperature/graphs** — `installFanControlSidebar` called `removeFromSuperview()` after `NSStackView(views:)` already owned `metricsStack`, orphaning temps/graphs. Fixed reparent order; lazy-load Fan Control panel on expand; defer SMC `hasControllableFan` off main; drop bad `fanRow.width` constraint.
- 2026-09-17: **Apply Curve hang** — see [fan-control-apply-hang.md](./fan-control-apply-hang.md). iOSCrashReporter is iOS-only; added `FanControlDiagnostics`; fixed re-apply-while-cooling, XPC interrupt leaving Working…, heartbeats paused during apply, full SMC key scan each temp read.


## How to use

1. Open **Hot** from `/Applications` (or Spotlight).
2. Status menu → click **Thermal Pressure**, **Temperature**, or **Fan** (▸) to open the Fan Control **sidebar**.
3. Or **Fan Control Window…** for a detached panel.
4. **Allow Fan Control…** → approve in Login Items.
5. **Curve** mode: Add Sensor / Add Point / drag graph / steppers → **Apply Curve**.
6. Use **System** to restore firmware control.

## Identifiers

- App: `com.xs-labs.Hot`
- Helper / Mach: `com.xs-labs.Hot.fan-control`
- Team ID (local machine): `KETV72YBM9`
- Lock: `/var/run/hot-fan-control.lock` / `.active`

## Files

- `Hot/Classes/FanControl/*` — models, SMC, hardware, service, UI
- `Hot/Classes/InfoViewController.swift` — status-menu sidebar host
- `Hot/FanControlHelper/main.swift` — root daemon
- `Hot/Resources/com.xs-labs.Hot.fan-control.plist`
- `Scripts/embed-fan-control-helper.sh`
- `Scripts/test-fan-control.swift` — policy + `--open-fan-control` smoke test

## Verify

```bash
swift Scripts/test-fan-control.swift
HOT_APP=/Applications/Hot.app swift Scripts/test-fan-control.swift --launch
/Applications/Hot.app/Contents/Library/LaunchServices/com.xs-labs.Hot.fan-control --selftest
codesign -dv --verbose=4 /Applications/Hot.app 2>&1 | grep TeamIdentifier
```

## Session log

- 2026-09-14: MIT fan-control stack; helper embed; Login Items flow.
- 2026-09-14 (evening): Fixed GitHubUpdates build; signed install to `/Applications`.
- 2026-09-14 (evening): Curve UI parity — multi-sensor curves, Add Point/Sensor, Temperature + Fan speed rows, drag HUD (`°C · %`); policy helpers `nextCurvePoint` / `addingCurvePoint`; reinstalled `/Applications/Hot.app`.
- 2026-09-14 (evening): **Fan Control not opening** — crash on window init: Auto Layout constraints activated before views shared a common ancestor (slider width, curve editor / point-row widths). Also serialized `SMCKit` `readAllKeys` (`@synchronized`) after concurrent ThermalLog + InfoViewController crashes. Added `Scripts/test-fan-control.swift` + `--open-fan-control` launch hook; verified window opens and process stays alive; reinstalled `/Applications/Hot.app`.
- 2026-09-14 (evening): **Working… stuck** — status refresh bumped XPC request generation while Apply was in flight, so `isWorking` never cleared. Fixed by skipping refresh during work, always clearing `isWorking` on completion, XPC error → completion, 12s timeout. **Sidebar UX** — `FanControlPanelController` embeds beside status metrics when clicking Pressure / Temperature / Fan rows; accent bar + chevron; menu item renamed **Fan Control Window…**. Reinstalled `/Applications/Hot.app`.
- 2026-09-14 (evening): **Blank temperature/graphs** — `installFanControlSidebar` called `removeFromSuperview()` after `NSStackView(views:)` already owned `metricsStack`, orphaning temps/graphs. Fixed reparent order; lazy-load Fan Control panel on expand; defer SMC `hasControllableFan` off main; drop bad `fanRow.width` constraint.
