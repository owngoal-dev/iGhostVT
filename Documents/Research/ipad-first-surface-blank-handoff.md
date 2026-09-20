# Handoff: the first tab's surface never draws on iPad when the daemon is down at launch

**Date:** 2026-08-31  
**Status:** resolved 2026-08-31 — the surface was never the problem; the shell had not printed yet. Fix: `TerminalSessionStore.isAwaitingFirstOutput` → "Starting shell…" pill, explicit `cursor-style-blink`. Findings below; the original investigation follows for the record.  
**Affects:** iPad (jailbroken device). Seen on 0.4.1, 0.4.4, 0.4.9, 0.5.0 — it is **not** a regression from the 0.5.0 resize throttle or libghostty-spm 1.4.12 (every app tag from 0.3.9 to 0.4.9 pins lib 1.4.11 and shows it too). Earlier than 0.4.1 untested.

---

## Resolution

### What was actually happening

The pane was empty because **the shell had not written a byte yet**. Not a
second surface, not a paused coordinator, not a zero-sized surface — every
one of hypotheses (A)/(B)/(C) was checked against a file log from the
device and came up clean. The distinguishing measurement, from one
reproduction with the daemon stamping each session's first PTY read and
the app stamping its first XPC output event:

| Event | Time |
| --- | --- |
| `launchctl reboot userspace` | 02:15:08 |
| `ighostvtd` listening | 02:15:18 |
| app launched (`uiopen`), tab created | 02:15:34.34 |
| `ighostvt-cli new` control session (session 1) spawned | 02:15:34.41 |
| app's session (session 2) spawned, app `connected` | 02:15:35.65 |
| daemon: **session 1 first output** (34 bytes) | 02:16:01.66 |
| daemon: **session 2 first output** (34 bytes) | 02:16:02.20 |
| app: first XPC output event for session 2 | 02:16:02.20 (+1 ms) |
| app: `session.receive` of that chunk | 02:16:02.20 |

26.6 s from `forkpty` to the first byte, on the app's session *and* on a
session no app ever attached to. Those 34 bytes are `[i] /var/jb/var/mobile/Documents\r\n` — the `echo` at the top of the device's `~/.zshrc`, after `source oh-my-zsh.sh`. Meanwhile `listSessions` showed the foreground process of both sessions cycling `git` → `mkdir` → `grep` → `ls` → `zsh`: the rc files running, slowly. The device's load average was 300–500 for the whole minute after the reboot (dopamine's bootstrap restarting everything), and every binary the rc executes is being exec'd for the first time since the reboot — on a jailbreak that first exec pays for trustcache/AMFI work that later execs do not. The same zsh started over SSH four minutes later took 1–4 s.

An earlier reproduction (the user's, app launched 40 s after the reboot) measured the same shape: shell spawned 02:11:50.97, first byte 02:12:22.80 (31.8 s), and the app drew it immediately — `display link acquired`, output logged, prompt on screen.

So the "bug" was in what the app *showed* during those 30 s:

- `TerminalSessionStore.status` goes `.connected` when the daemon answers `openSession` — the PTY exists and the shell is forked. `SessionStatusOverlay` shows nothing for `.connected`. Result: the "Connecting…" pill vanishes within a second of launch and the user is looking at an empty terminal, indistinguishable from the broken-surface bugs this stack has had before.
- Typing "worked" because the PTY is real — keystrokes reach the shell's input queue and are consumed once it reaches its prompt.
- A second tab "rendered fine" because by the time it was opened the first shell had warmed the caches; its zsh printed within a second.
- The two earlier "blank first terminal" bugs (born-occluded surface; 49×16 PTY) primed everyone, this one included, to look at the view stack.

### Why the daemon-down theory looked right

Both conditions come from the same event — a userspace reboot — and both
recover on their own. Unloading the LaunchDaemon by hand (`launchctl
bootout`) without a reboot does **not** reproduce it (confirmed on
device): the caches are warm, the shell prints at once. Only the reboot
does, and after a reboot the daemon is up (RunAtLoad) ~10 s after SSH is
back, well before the user reaches the home screen. The daemon's state at
app launch was never the variable.

### The fix

1. `TerminalSessionStore.isAwaitingFirstOutput`: armed on `.connected`,
   set after `firstOutputGrace` (1 s) if no byte has arrived, cleared by
   the first byte (a replay counts, and so does a status line the store
   prints itself) and by any state change. `SessionStatusOverlay` shows a
   "Starting shell…" pill while it is on. The grace keeps a normal launch
   from flashing it.
2. `GhosttyAppConfiguration` sets `cursor-style-blink = true` explicitly,
   so even without the pill a silent-but-live terminal shows something
   moving.
3. Diagnostics that would have found this in one pass: `PTYSession` logs
   `session N first output, M byte(s)` to the daemon file log; the app's
   `XPCDaemonTransport` and `TerminalSessionStore` stamp their first
   output into `TerminalDebugFileLog` (`Documents/ighostvt-debug.log`,
   opened when Settings ▸ Advanced ▸ Detailed Terminal Log is on).

### Capturing on the device, revised

The unified-log relay is not usable for this: `pymobiledevice3 syslog
live` delivered a handful of the app's lines during the post-reboot
minute (the good-run capture minutes later was complete), and a userspace
reboot drops the lockdown tunnel regardless. `pymobiledevice3 syslog
collect` produced a logarchive `log show` called corrupt. What worked:

- **App side:** the file log above, pulled with `scp` over `iproxy 2222 22`
  from `/var/mobile/Containers/Data/Application/<uuid>/Documents/ighostvt-debug.log`.
- **Daemon side:** `/var/mobile/Library/Logs/ighostvtd.log` (root-owned
  directory listing; the file is world-readable).
- **Control session:** `ighostvt-cli new` right after the reboot, then
  `ighostvt-cli capture N | wc -c` in a loop with timestamps. A buffer that
  stays at 0 bytes while `list` shows the foreground changing is the whole
  story in one command.
- **Reproducing:** `sudo launchctl reboot userspace` over SSH; poll until
  SSH answers again (~20 s); `uiopen --bundleid wiki.qaq.iGhostVT` at once.
  The bug window is roughly the first two minutes after the reboot.

---

## The original investigation (kept for the record)

## The symptom, exactly as observed

1. Launch the app while `ighostvtd` is **not yet reachable** (fresh boot before the LaunchDaemon is up, or the daemon otherwise not answering). The first tab is created and its connection waits / fails.
2. The daemon comes up; the tab connects normally: the sidebar dot goes green, the title becomes `zsh`, **typing works, `htop` runs, and event 102 keeps retitling the tab** (`htop` shows in the sidebar). `ighostvt-cli capture` shows the session drawing fine on the daemon side.
3. The pane itself shows **nothing** — and it was empty the whole time: not even the grey `[iGhostVT] Connection lost. Reconnecting…` status lines that `TerminalSessionStore.printStatusLine` feeds into the session *before* the connection succeeds.
4. Resizing the window (Stage Manager) does not fix it. Switching tabs in the sidebar does not fix it.
5. **A brand-new tab opened afterwards renders fine.** So this is not process-wide state (the shared display link, the ghostty runtime, the GPU entitlement): it is *this tab's* surface.
6. Quit and relaunch (daemon now up) → everything is fine.

## What that narrows it to

The visible `UITerminalView` for the first tab **has** a ghostty surface — key encoding needs one, and typing reaches the shell. The session side works. So one of:

- **(A) The session's bytes go to a surface other than the one on screen.** `InMemoryTerminalSession` holds exactly one `ghostty_surface_t` (`InMemoryTerminalSurfaceAccess.setSurface`, replaced on every surface creation that names this session; `clearSurface(ifMatches:)` on teardown is identity-guarded). If SwiftUI ever made *two* platform views for the one `TerminalViewState` (a rebuilt representable, a pane inserted twice during a transition), the session ends up bound to whichever surface was created last, and the visible one never receives output. Input still works from the visible one — it goes *out* through the store, not through the session's surface.
- **(B) The visible surface exists but its coordinator never renders.** `TerminalSurfaceCoordinator.canRenderFrame` = `isDisplayVisible && isApplicationActive && isAttached()`. A view attached while `UIApplication.shared.applicationState != .active` records `isApplicationActive = false` (`syncApplicationActiveState` in `didMoveToWindow`) and only `applicationDidBecomeActive` / `UIScene.didActivateNotification` clears it; a tab whose `TerminalViewState.isSurfaceVisible` was stamped false and never re-stamped true has `isDisplayVisible = false`. Both leave the surface alive and silent. Against (B): a resize calls `synchronizeMetrics`, not `renderImmediately`, so it would not help — consistent with what was seen; but a new tab's coordinator would be fine — also consistent.
- **(C) The surface never got a usable size** (born while the view was zero-sized; `rebuildIfReady` keeps `pendingRebuild` and waits for a layout). Against (C): a later resize would deliver one, and it did not help. Least likely.

The distinguishing fact between (A) and (B) is in the library's lifecycle log, which the app already sends to the unified log — see below.

## What has been ruled out

- **The daemon.** `ighostvt-cli` sees the session working; the proxy/io split (0.4.5) and the CLI admission changes (0.5.0) are not involved. The device packaging (`Scripts/package-deb.sh`) did not touch the app's entitlements — the GPU `iokit-user-client-class` list is still on the app, and a missing one would blank *every* launch, not the first.
- **The 0.5.0 resize throttle** (`TerminalTab.resizeThrottle`, 128 ms until the shell is verifiably at its prompt) and **libghostty-spm 1.4.12** (UIKit layer held at `syncedViewSize` while throttled). Both post-date the bug. Do not spend time there for this issue.
- **Simulator reproductions — all render correctly** (iPad Pro 11-inch (M5) simulator, Debug build of `db359d0`):
  1. Plain launch: no daemon → the reconnect cycle → "Terminal Unavailable" card; the status lines are visible under the card.
  2. `DaemonSessionDirectory.claimResumable` delayed 6 s (emulating the `listSessions` timeout, so the first tab is created well after the scene is active): renders.
  3. A simulator-only fake `TerminalTransport` that emits `.interrupted` on the first connect and `.connected` + `.processName("zsh", isShell: true)` + a prompt on the second: renders, prompt visible.
  4. Same as 3 with the software keyboard enabled (`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`): renders.
  So the app-side state machine (failed → connected, late tab creation, the alert card claiming first responder) does not reproduce it on its own. Something in the device's timing or the real daemon's path is required.

## What to capture on the device (the one thing that will settle it)

`AppDelegate` already routes `TerminalDebugLog` (`.lifecycle` + `.metrics`) into os_log — subsystem `wiki.qaq.iGhostVT`, category `ghostty`, lines prefixed `[GhosttyTerminal]`. Nothing needs enabling for those two categories.

Capture one bad launch and one good launch:

- USB + Console.app on the Mac: select the iPad, search `process:iGhostVT`, Start, reproduce, Select All → Copy → save.
- Or over SSH on the device: `log stream --process iGhostVT --style compact > /tmp/ighostvt.log`.
- For input/output tracing on top (logs keystrokes — opt-in): `defaults write wiki.qaq.iGhostVT Debug.verboseTerminalLog -bool true` on the device, or Settings ▸ Advanced ▸ Detailed Terminal Log; relaunch. The `.render` category ("tick" per drawn frame) is not in `.standard`; enable `TerminalDebugLog.enable(.all)` temporarily in `AppDelegate` if frame-level evidence is needed.

Then read, for the first tab, in order:

| Line | What it tells |
| --- | --- |
| `surface rebuild succeeded` / `surface rebuild failed` / `surface rebuild skipped: …` | how many surfaces were made for the tab, and whether any creation failed |
| `in-memory session surface=set` / `surface=nil` / `in-memory session clear skipped expected=… current=…` | which surface the session is bound to; **two `surface=set` for one tab, or a `clear skipped`, is hypothesis (A)** |
| `didMoveToWindow attached=true/false` | attach/detach churn — a detach + reattach pair around the connect is a second-view smell |
| `application did become active` / `application did enter background` | whether the view ever learned the app is active — **`setApplicationActive(false)` with no later active is hypothesis (B)**; note there is no log line for the inactive read in `syncApplicationActiveState` itself, so look for the absence of `display link acquired` after the surface exists |
| `display link acquired` / `display link released` | whether this coordinator ever had a link; a surface that never acquires one never draws |
| `sync view=… pixels=…` / `sync updated …` / `synchronizeMetrics skipped: invalid view size` | whether the surface was ever sized (hypothesis (C)) |
| `wakeup suspended` | the controller refusing ticks because no observer's `shouldProcess` (`isApplicationActive && isAttached()`) held |

Compare with the same lines from the good launch. Time-align with the `session` category lines (`connecting via …`, `connected to …`, `link lost: …`) to see where in the connect cycle the divergence is.

## Reproducing the daemon-down launch on the device

The LaunchDaemon has `KeepAlive = true`, so killing `ighostvtd` only restarts it. Unload the job first, launch the app, then load it again once the app is sitting on its card / pill (paths for rootless carry the `/var/jb` prefix; roothide's `launchctl` is vroot-linked and takes them unprefixed):

```sh
launchctl bootout system/wiki.qaq.ighostvtd
# launch iGhostVT from the home screen, wait for the "Connecting…" pill or the card
launchctl bootstrap system /Library/LaunchDaemons/wiki.qaq.ighostvtd.plist
```

Whether the app is left on the pill (hello queued by launchd until the daemon answers) or reaches the card (the connection errored) is itself worth noting: on the simulator the mach lookup fails instantly and the card appears; on the device the observed behaviour ("empty the whole time") suggests the surface never drew even before any of that.

## Code map for whoever picks this up

App (this repo):

- `iGhostVT/Backend/Session/TabManager.swift` — `init` → `DaemonSessionDirectory.claimResumable` (a `listSessions` with a 6 s timeout; nil → `[]` → `newTab()`); `activeTabID.didSet` → `syncSurfaceVisibility()` (the only writer of `TerminalViewState.isSurfaceVisible`).
- `iGhostVT/Backend/Session/TerminalSessionStore.swift` — `connectWhenReady` (needs the surface's first viewport *and* scene active), `apply(_:)` (the `.interrupted` → `scheduleReconnect` cycle, `printStatusLine` into the session), `TransportRelay`.
- `iGhostVT/Backend/Session/TerminalTab.swift` — one `TerminalViewState` (and therefore one `TerminalController` / ghostty app) per tab; `makePlatformView` → `LockableTerminalView`.
- `iGhostVT/Interface/Main/RootView.swift` — `panes` `ZStack` + `ForEach` → `TerminalPane` → `TerminalSurfaceView(context:)`, `.opacity(isActive ? 1 : 0)`; `refocus()`; `SessionStatusOverlay` (card + `AlertFirstResponder`, 0.4.8).
- `iGhostVT/Application/AppDelegate.swift` — the `TerminalDebugLog.sink` into os_log.
- `iGhostVT/Application/SceneDelegate.swift` — `sceneDidBecomeActive` → `tabManager.noteSceneActive()`.

Library (`../libghostty-spm`, tag 1.4.11 / 1.4.12):

- `Sources/GhosttyTerminal/Surface/TerminalSurfaceCoordinator.swift` — `rebuildIfReady`, `synchronizeMetrics` / `performMetricsSync`, `setDisplayVisible`, `setApplicationActive`, `tick`, `ensureDisplayLink` / `releaseDisplayLink`, `canRenderFrame`.
- `Sources/GhosttyTerminal/Platform/UIKit/UITerminalView+Lifecycle.swift` — `didMoveToWindow` (`syncApplicationActiveState`, rebuild-or-sync, the deferred `fitToSize`), the app-active notification observers, `layoutSubviews`.
- `Sources/GhosttyTerminal/View/TerminalViewRepresentable.swift` + `…@UIKit.swift` — `configureView` (forwards `isSurfaceVisible` only on change via `hostDeclaredDisplayVisible`), `makeUIView` / `dismantleUIView`.
- `Sources/GhosttyTerminal/InMemory/InMemoryTerminalSession.swift` + `InMemoryTerminalSurfaceAccess.swift` — the one-surface binding, `pendingWrites` flushed on `setSurface`.
- `Sources/GhosttyTerminal/Controller/TerminalController.swift` — `handleWakeup` and the per-surface `WakeupObserver`s.
- `MSDisplayLink` 2.2.0 (`DerivedData/SourcePackages/checkouts/MSDisplayLink`) — one shared `CADisplayLink` per process, stopped on `didEnterBackground`, restarted on `willEnterForeground`. Read; nothing found that would silence a single coordinator while another draws.

## Simulator harness used (to re-create quickly)

Build and run: see the `sim-ui-check-loop` recipe — `xcodebuild -project iGhostVT.xcodeproj -scheme iGhostVT -configuration Debug -derivedDataPath /private/tmp/ighostvt-deriveddata -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -skipMacroValidation -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build`, then `simctl install` / `launch` / `io … screenshot`. Screenshots come out rotated for a landscape iPad; the content is fine.

The fake transport (not committed; ~30 lines, simulator-only): a `TerminalTransport` whose `connect()` emits `.state(.connecting)`, then after 1.5 s either `.state(.interrupted(reason:))` (first attempt) or `.state(.connected)`, `.processName("zsh", isShell: true)`, `.received("…fake$ ")`; `send` echoes; `updateViewport` no-op. Wire it at the top of the `makeTransport` closure in `TerminalTab.init` behind `#if targetEnvironment(simulator)` and a `Debug.experimentTransport` default. The 6 s launch delay is a `try? await Task.sleep(nanoseconds: 6_000_000_000)` at the top of the `Task` in `DaemonSessionDirectory.claimResumable`.

## Next steps

1. Capture the two logs (bad launch, good launch) and diff the first tab's `[GhosttyTerminal]` lines as in the table above. That decides (A) vs (B) vs (C).
2. If (A): find what makes SwiftUI build a second `UITerminalView` for the tab on the device (look at `didMoveToWindow attached=` pairs and `surface rebuild succeeded` counts); the fix is in the app's view structure, or the library's session binding should prefer the view that is attached.
3. If (B): find which of `isApplicationActive` / `isDisplayVisible` is stuck and why the notification or the representable's forwarding never reached that coordinator; the defensive fix is to re-stamp both on `.connected` (and on any resize), the real fix is at whichever path dropped the update.
4. Write the answer into `Documents/ARCHITECTURE.md` / `AGENTS.md` gotchas once known — this is the third "first terminal of a cold launch sits blank" bug in this stack, and the previous two (the born-occluded surface; the 49×16 PTY) are recorded there.
