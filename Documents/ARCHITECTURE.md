# Architecture

## Repo layout (FlowDown-style)

```
iGhostVT/                    the app, one folder-synchronized Xcode group
├── main.swift               UIApplicationMain entry (no @main)
├── Application/             AppDelegate, SceneDelegate
├── Backend/Session/         TerminalTab, TabManager, TerminalSessionStore
├── Interface/               SwiftUI, grouped by feature
│   ├── Main/                RootView, SessionStatusOverlay
│   ├── Bars/                BottomBar (compact), TabStripBar (regular)
│   ├── Sidebar/             SidebarView (iPad tab list)
│   ├── TabSwitcher/         grid switcher with live snapshots
│   ├── Settings/            SettingsSheet (themes, default shell)
│   └── Support/             GlassStyle, KeyboardState
└── Resources/               Assets.xcassets, Info.plist
Shared/Protocol/             XPC wire protocol, compiled into app + daemon + CLI
Shared/Activity/             ActivityAttributes, compiled into app + appex
Shared/Screen/               ScreenRenderer + KeyNames, compiled into app + CLI
iGhostVTDaemon/              ighostvtd: the XPC proxy launchd starts
iGhostVTIO/                  ighostvtd-io: the PTYs, buffers, and shells
iGhostVTDaemonShared/        bootstrap paths, logging, the proxy <-> io wire
iGhostVTCLI/                 ighostvt-cli: the one-shot command-line client
iGhostVTWidgets/             WidgetKit appex: the Dynamic Island Live Activity
Documents/                   these notes, Research/, and Site/ (the web page)
```

`iGhostVT.xcodeproj` is checked in: objectVersion 77 with a
`PBXFileSystemSynchronizedRootGroup` over the `iGhostVT/` folder (Info.plist
excluded via membership exception) and a remote package reference to the
released `libghostty-spm`. Adding a file to the folder adds it to the
target — there is no generator step. The `TerminalTransport` seam lives in
`iGhostVT/Backend/Transport/` beside its XPC implementation.

## Ownership (multi-window)

```
SceneDelegate ──owns──> TabManager ──owns──> [TerminalTab]
   (1 per window)          │                    │
                           │                    ├─ TerminalViewState (surface)
UIHostingController        │                    └─ TerminalSessionStore
   └── RootView ──borrows──┘                          ├─ InMemoryTerminalSession
                                                      └─ XPCDaemonTransport
```

- Each `UIWindowScene` gets its own `TabManager` from its `SceneDelegate` —
  windows are independent, like Safari windows. `sceneDidDisconnect` closes
  all of that window's sessions.
- Interface views only borrow the manager (`@ObservedObject`); the single
  writer for tab lifecycle is `TabManager`.
- App-wide state is limited to the default endpoint in `UserDefaults`.
- New windows: ⌘N, or the context menu on the tab-switcher button
  (`UIApplication.requestSceneSessionActivation`).

## Data flow

The terminal never spawns a process. libghostty runs with the `inMemory`
backend: everything the surface would write to a PTY is handed to the host,
and everything the host receives is parsed by the surface.

- Keystrokes → `InMemoryTerminalSession(write:)` → `TransportRelay` →
  `TerminalTransport.send` → the daemon → the PTY.
- PTY output → the daemon pushes it → transport event → main-actor hop →
  `session.receive(_:)` → VT parser → Metal renderer.
- Grid resize → `InMemoryTerminalSession(resize:)` → relay → transport →
  `TIOCSWINSZ` on the daemon's master fd.
- A session connects only after the surface reports its first viewport:
  before that, bytes fed to the session are dropped, and a size-negotiating
  transport (SSH) wants the grid at connect time anyway.

`TransportRelay` exists because the session's write/resize closures are
captured once at init, while the transport is replaced on every reconnect.

## Interface behavior

- All of a window's surfaces stay mounted in one `ZStack` (hidden, not
  removed) so background tabs keep their grid and connection. The pane stack
  keeps one structural position across compact/regular so size-class changes
  never recreate surfaces.
- Compact: Safari-style floating bottom cluster (title capsule: swipe to
  switch tabs, long-press for settings; hides while the keyboard is up).
- Regular: top tab strip; the sidebar replaces the chips when open.
- Liquid Glass (`glassEffect`) on iOS 26+, `.ultraThinMaterial` below,
  wrapped once in `Interface/Support/GlassStyle.swift`.
- `SessionStatusOverlay` covers a pane whose session is not usable: a pill
  while the surface starts ("Starting…") or the daemon connection opens
  ("Connecting…"), a card once it failed. Connected shows nothing — with
  one exception. `TerminalSessionStore.isAwaitingFirstOutput` turns on
  when a *connected* session has written nothing for a second, and the
  pill says "Starting shell…" until the first byte (a replay counts).
  Without it a slow shell is an empty terminal that looks exactly like a
  broken one; the first zsh after a userspace reboot takes ~30 s
  (`Research/ipad-first-surface-blank-handoff.md`).

## Transport contract

`TerminalTransport` is deliberately minimal: `connect` / `send` /
`updateViewport` / `disconnect` plus one `onEvent` stream delivered on a
transport-owned queue. `XPCDaemonTransport` is the only implementation; SSH
lands later as a second. There is no networked transport — the daemon is the
backend, and debugging happens on device.

## The daemon (device I/O)

```
iGhostVT.app                          ighostvtd  (LaunchDaemon, root)
  InMemoryTerminalSession               DaemonServer   mach service listener
        │                                     │        wiki.qaq.ighostvt.service
  XPCDaemonTransport ──── XPC ──────────► PeerAuthenticator
        ▲                                     │   audit token: entitlement +
        └──── output / sessionExit ──────┐    │   uid + root-owned exec path
                                         │  PeerSession   one per connection
                                         │        │
                                         └── SessionRegistry ── [PTYSession]
                                                                forkpty + execve
```

- **The app cannot spawn.** `ighostvtd` is the only component that creates a
  process. The app's whole vocabulary is `openSession` / `attachSession` /
  `write` / `resize` / `closeSession` over the mach service, and the daemon
  authenticates every peer from its kernel audit token before answering: the
  caller must hold `wiki.qaq.ighostvt.client`, run as root or mobile, and *be*
  the installed root-owned app binary. `Scripts/package-deb.sh` asserts the
  signed entitlements on both binaries, including that the daemon does not
  carry the client entitlement.
- **The daemon holds the data.** Sessions live in `SessionRegistry`, not on
  the connection that opened them, so quitting the app detaches instead of
  killing — `disconnect()` is a detach and `closeSession()` is the kill. Each
  session keeps a 256 KiB replay buffer; attaching replays it so the surface
  rebuilds its screen. The registry caps live sessions daemon-wide, because
  sessions outliving their connection means a per-peer limit bounds nothing
  across relaunches.
- **The daemon stays resident.** It used to idle-exit after thirty seconds
  with no peers and no sessions, relying on launchd to demand-launch it again.
  Demand launch does work on device, but the exit cannot be made atomic
  against launchd routing a new connection — and the window is exactly where
  the app lives, since the last shell exiting is what empties the registry and
  opening a new tab is what happens next. `RunAtLoad` + `KeepAlive` instead,
  which also covers the crash that demand launch cannot.
- **Resize works here.** `updateViewport` becomes `TIOCSWINSZ` on the master
  fd, so the shell always lays out at the grid actually on screen.
- The shell is chosen by the app (`Shell.path` in `UserDefaults`, empty means
  "daemon picks") but validated by the daemon: absolute path, existing,
  executable, argument count capped. Anything else is rejected. The path is
  written the way the bootstrap's own programs write one. Under rootless
  either spelling is accepted — `/var/jb/bin/zsh` and the bare `/bin/zsh` a
  user carries over from another jailbreak name the same file.

## Jailbreak layouts

Two are supported, from one set of binaries. They differ only in where the
package installs and how paths are spelled:

| | install root | package architecture |
| --- | --- | --- |
| **roothide** | the jbroot it picked this boot | `iphoneos-arm64e` |
| **rootless** | `/var/jb` | `iphoneos-arm64` |

`JailbreakRoot` works out which one it is running under by stripping its own
install suffix, `/usr/libexec/ighostvtd`, off its own executable path: nothing
left means no prefix, a path that `/var/jb` canonicalises to means rootless
(a rootless bootstrap may hide a randomly named directory behind that
symlink), anything else is a jbroot. No libroothide dependency, no bridging
header, and off-jailbreak everything degrades to identity so the harness runs
on macOS.

Three path vocabularies exist, and mixing them is *the* jailbreak-path bug:

| `JailbreakRoot` | who reads it | roothide | rootless |
| --- | --- | --- | --- |
| `bootstrapPath()` | bootstrap programs, for their own files | `/bin/zsh` | `/var/jb/bin/zsh` |
| `systemPath()` | bootstrap programs, for iOS's files | `/rootfs/usr/bin` | `/usr/bin` |
| `resolve()` | the kernel — `execve`, `stat`, `open` | `<jbroot>/bin/zsh` | `/var/jb/bin/zsh` |

The asymmetry is libvroot: roothide's Procursus binaries are linked against
that compile-time shim, which rewrites their path syscalls so they already
treat the jbroot as `/`. So under roothide the daemon resolves the executable
it hands to `execve` but leaves every path *inside the environment*
unprefixed — prefixing those would resolve the jbroot twice — and reaches the
untouched iOS filesystem through the jbroot's `/rootfs` bridge. A rootless
bootstrap has no shim: `/var/jb` is compiled into its binaries, so they and
the kernel speak the same real paths, and iOS's own `/usr/bin` is just
`/usr/bin`. Either way the fallback `PATH` is the bootstrap's binary
directories followed by the system's — without the second half a session
reaches everything the jailbreak installed and nothing the system ships.

Session startup follows roothide's own terminal
([roothide/NewTerm](https://github.com/roothide/NewTerm)): prefer handing the
session to `login -fpq <user>`, which establishes the utmp entry, login class,
`PATH`, `HOME`, and `SHELL` the way every other terminal on the device gets
them — hence no hardcoded `PATH` on that route. Only when `login` is missing
does the daemon spawn a shell itself, reading `pw_shell` from the
**bootstrap's** `/etc/passwd` (`resolve(bootstrapPath("/etc/passwd"))`, not
libc's system database) and supplying the environment `login` would have.

The session runs as **mobile (501)**, not as the daemon. `ighostvtd` is root, so
a session would inherit root unless told otherwise, but root is the wrong
default to land the user on: `$HOME`, the caches a shell writes, and everything
else under `/var/mobile` belong to 501, and root-owned files left there break
the apps that own them afterwards. `sudo` covers the other direction, and it is
the direction that can be undone.

How the drop happens depends on the route. `login -fpq mobile` setuids itself,
so that route hands over the name and drops nothing. When the app names a shell
explicitly, or `login` is missing, the daemon does it in the forked child:
`fchown` the terminal to the user, then `setgroups`/`setgid`/`setuid`, then
`execve` — bare syscalls only, since nothing else is safe between fork and
exec. Any failure in that sequence is fatal to the child, because exec'ing
anyway would hand over the root shell that was just refused.
- A `.disconnected` event cannot say *why* — a detach, a dropped link, and
  `exit` typed into the shell all produce one. `XPCDaemonTransport.onSessionExit`
  reports the process exiting specifically, with the dead session's id and
  status, so a host persisting ids can forget them at the right moment
  instead of discovering the death through a failed reattach.
- On the app side, `DaemonSessionLedger` persists the IDs of sessions this
  app opened and has not killed. Closing a tab kills its shell
  (`closeSession`) and drops the ID; scene teardown only detaches. The first
  window of a cold launch claims the persisted IDs and recreates one tab per
  live session, which reattaches and replays.

## Packaging (from Inspector)

- `Configuration/Version.xcconfig` is the single version source;
  `make set-version` writes it, the Debian control and .deb filename read it.
- `make deb` builds both targets unsigned for iPhoneOS, ad-hoc signs each
  with ldid against its own entitlements (`Packaging/iGhostVT.entitlements`,
  `Packaging/iGhostVTDaemon.entitlements`), verifies the signed entitlements
  and package metadata, then emits the `.deb`:
  `/Applications/iGhostVT.app`, `/usr/libexec/ighostvtd`, and
  `/Library/LaunchDaemons/wiki.qaq.ighostvtd.plist`. `postinst` bootstraps the
  daemon, `prerm` boots it out. `ighostvt-cli` is installed inside the app
  bundle (`/Applications/iGhostVT.app/ighostvt-cli`, its own entitlements:
  the client marker and the mach lookup, nothing else) with
  `/usr/bin/ighostvt-cli` as a **relative** symlink to it — an absolute one
  would resolve against iOS's `/Applications` under roothide, not the
  bootstrap's.
- `make deb-rootless` (`PACKAGE_FLAVOR=rootless`) packages the same binaries
  with `/var/jb` in front of those three paths. The prefix is substituted for
  `@PREFIX@` in the launch daemon plist and the maintainer scripts, and the
  packager asserts the plist launches `ighostvtd` from where it was actually
  installed — the daemon recovers its install root from that path, so a
  mismatch would make every bootstrap path it derives wrong.
- `make check` guards the pbxproj's objectVersion (77) so newer Xcode
  doesn't silently rewrite the project format.

## Packaging (macOS)

The Mac has no package manager to install a daemon, so the same two programs
ship as one bundle and the app installs its own helper:

```
iGhostVT.app
  Contents/MacOS/iGhostVT                  Catalyst GUI, unsandboxed
  Contents/MacOS/ighostvtd                 the only process that forks
  Contents/MacOS/ighostvt-cli              the command-line client
  Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist   BundleProgram
```

- `make mac-zip` builds both targets unsigned and universal (arm64 +
  x86_64) for Release, then `Scripts/package-mac.sh` stages the helper and the
  agent plist into the bundle, raises `LSMinimumSystemVersion` to 13.0, signs
  inside out with Hardened Runtime, and `ditto`s the zip. Ad-hoc by default;
  `MAC_ZIP_IDENTITY` takes a Developer ID and `MAC_NOTARY_PROFILE` a notarytool
  keychain profile. Same contract as the deb packager: xcodebuild never signs.
- `MacLaunchAgent` registers the bundled agent with `SMAppService` on first
  launch, and only from `/Applications` — Login Items binds to the registering
  path, and a translocated launch out of Downloads would bind to a mount that
  disappears. `SessionStatusOverlay` reads it *before* `store.status`, so a
  pending approval says so instead of hanging on "Connecting…", and
  `SceneDelegate` holds the first connection attempt until the helper is
  running.
- `PeerAuthenticator`'s macOS branch replaces the client entitlement, which a
  Catalyst binary cannot carry, with a code-signing requirement checked against
  the caller's audit token. What it demands depends on how the daemon itself
  was signed: a Developer ID build pins identifier + Apple anchor + team, while
  an ad-hoc build pins *location* instead — the peer must be the `iGhostVT`
  binary beside the daemon in the same `Contents/MacOS`, which `BundleProgram`
  guarantees is the app that shipped with it. The branch is accept-or-deny and
  never falls through to the device checks.
- Neither Mach-O is sandboxed. Background Task Management refuses a sandboxed
  app's unsandboxed `SMAppService` job, and a sandboxed helper would pass its
  container to every shell it spawns. `mac-zip-check` fails if
  `com.apple.security.app-sandbox` turns up in either entitlements file.
