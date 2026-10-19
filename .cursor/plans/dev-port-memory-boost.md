# Dev-port memory boost (Hot)

Status: implemented

## Next agent turn (start here)

**Feature complete.** No further phases.

**Context:** All work uncommitted unless asked: `Hot/Classes/DevPorts/`, `Scripts/test-dev-port-stop.swift`, pbxproj, `MainMenu.xib`, `ApplicationDelegate.stopDevServers`, README note. Script 7 checks OK; DevPorts typecheck OK. Full `xcodebuild` Release blocked by pre-existing SMCKit `kIOMasterPortDefault` `-Werror` on Xcode 27 SDK (out of scope). Do not commit unless asked. Do not reopen Vorssaint.

**Already shipped:** phases 1–3 (core + menu/alerts + README + build smoke note).

## Scope

Stop leftover TCP listeners on DevGuard-style ports (`3000–3002`, `5173–5176`, `5199`) from Hot’s status menu after confirmation, to free RAM from orphan Node/Vite stacks.

Out of scope: full process browser, Command Bar, privileged helper, fake `purge`-only “boost”, changing DevGuard scripts, committing Vorssaint, fixing SMCKit SDK deprecation.

## Phases / shipped

| Phase | Deliverable | Status |
|---|---|---|
| 1 | Core `DevPorts` service + parse/kill helpers + script tests + pbxproj | done |
| 2 | Status menu “Stop Dev Servers…” / Memory boost + `NSAlert` confirm + `ApplicationDelegate` | done |
| 3 | README brief note + Release build smoke; Status → implemented | done |

## Verify

```sh
cd /Volumes/Projects/Projects/Hot
swift Scripts/test-dev-port-stop.swift
swiftc -typecheck -sdk "$(xcrun --show-sdk-path --sdk macosx)" -target arm64-apple-macos12.0 \
  Hot/Classes/DevPorts/DevPortSupport.swift Hot/Classes/DevPorts/DevPortStopService.swift
# Full app build (pre-existing SMCKit block on Xcode 27 SDK):
# xcodebuild -project Hot.xcodeproj -scheme Hot -configuration Release CODE_SIGNING_ALLOWED=NO MACOSX_DEPLOYMENT_TARGET=12.0 build
# Manual: status menu → Stop Dev Servers… → confirm → lsof ports free
```

## Session log

- 2026-10-18: User asked to port Vorssaint memory-boost into Hot after Vorssaint phases 1–5. Hot surface = menu action + confirm, not full Kill Process.
- 2026-10-18 phase 1: Added `DevPortSupport` (ports, parseLsof, group match, protected) + `DevPortStopService` (fresh lsof, start-time identity, SIGTERM / app terminate, no admin). `Scripts/test-dev-port-stop.swift` 7 checks OK. pbxproj wired. `swiftc -typecheck` OK. Full xcodebuild blocked by SMCKit deprecation-as-error on current SDK.
- 2026-10-18 phase 2: Status menu “Stop Dev Servers…” (tooltip: Memory Boost) after Detach Graph in `MainMenu.xib`. `ApplicationDelegate.stopDevServers` discovers on background → confirm alert listing PID/ports → `stopListeners()` on background → result alert. Script 7 checks OK; DevPorts typecheck OK.
- 2026-10-19 phase 3: README “Stop Dev Servers (Memory Boost)” note (ports + confirm). Script 7 + DevPorts typecheck OK. Release `xcodebuild` fails pre-existing SMCKit `kIOMasterPortDefault` deprecated-as-error (`SMC.m:161`, macOS 12+ / Xcode 27 SDK) — not expanded. Status → implemented.
