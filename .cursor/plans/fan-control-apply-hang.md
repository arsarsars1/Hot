# Fan Control Apply Curve hang

**Status:** implemented (helper daemon still needs bounce to load new binary)  
**Scope:** Diagnose stuck **Working…** on Apply Curve; add CrashReporter-style diagnostics; fix re-apply / XPC / SMC scan costs.  
**Parent:** [fan-control-port.md](./fan-control-port.md)

## Findings

| Finding | Detail |
|---|---|
| iOSCrashReporter | At `/Volumes/Projects/packages/ios-crash-reporter` — **iOS/UIKit only** (`platform :ios`). Cannot link into macOS Hot as-is. |
| Re-apply while cooling | `startCurve` always `validateAutomaticControl` + `startCooling`, which require automatic mode → fails when fans already forced. |
| XPC interrupt | `interruptionHandler` only nils `connection`; pending apply reply never completes → UI stuck on **Working…**. |
| Heartbeat pause | `tick()` skipped heartbeats while `isWorking`, so helper could restore mid-apply. |
| Helper CPU | `readTemperatures()` enumerated **all** SMC keys every heartbeat → ~10% CPU on helper. |

## Shipped

1. `FanControlDiagnostics` — breadcrumbs/report → NSLog + `~/Library/Logs/Hot/fan-control.log` (API mirrors `PluginCrashReporter`)
2. Helper: update-in-place for curve/manual when already cooling; cache temp keys; OSLog on apply paths
3. App: complete pending XPC on interrupt/invalidate; `DispatchWorkItem` 12s timeout; heartbeats continue during apply

## Verify

```bash
# Quit Hot, relaunch Debug build, Apply Curve, then:
open ~/Library/Logs/Hot/fan-control.log

# Bounce helper so helper-side fixes load:
sudo launchctl kickstart -k system/com.xs-labs.Hot.fan-control
```

## Session log

- 2026-09-17: Confirmed iOSCrashReporter is iOS-only; helper hot; cooling active with Working… stuck.
- 2026-09-17: Diagnostics + XPC/re-apply/temp-cache fixes; Debug BUILD SUCCEEDED; `/Applications` helper binary replaced; pid 180 still running old code until kickstart.
