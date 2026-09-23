# iGhostVT — Agent Notes

Ghostty-powered terminal for jailbroken iOS 15+ — roothide and rootless
bootstraps both. The app renders; the bundled `ighostvtd` LaunchDaemon owns
every terminal session. `ighostvtd` is a thin XPC proxy under launchd's 6 MB
jetsam limit; it spawns one child, `ighostvtd-io`, and forwards the wire to
it. The PTYs, the replay buffers, and every shell live in `ighostvtd-io`,
which launchd never sized — so a session's buffers cannot jetsam the daemon.

## Hard rules

- **No project generators.** `iGhostVT.xcodeproj/project.pbxproj` is
  hand-written and checked in (objectVersion 77, file-system-synchronized
  groups — files added under `iGhostVT/`, `iGhostVTDaemon/`, `Shared/Protocol/`
  join
  their target automatically). Never introduce XcodeGen/Tuist/etc.
- **Versions live in `Configuration/Version.xcconfig` only** (edit via
  `make set-version`). xcconfigs attach at project level; a target-level
  `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the pbxproj silently
  shadows them and ships the wrong build number. `make check` rejects this —
  keep it that way, and watch for Xcode injecting these keys back.
- **The app never spawns processes.** Only `ighostvtd-io` forks
  (`forkpty`+`execve`); `ighostvtd` forks exactly one thing — `ighostvtd-io`
  itself, via `posix_spawn` (`IOSupervisor`). Peer authentication is still
  the daemon's, gated by the kernel audit token before a byte is forwarded.
  Keep that boundary; don't add process APIs to the app or to the proxy.
- **`ighostvtd` must stay small.** It is the launchd job, and launchd caps a
  daemon at 6 MB on the device (jetsam) — a replay buffer or an XPC send
  queue growing there is what this split exists to prevent. Everything with a
  buffer belongs in `ighostvtd-io`. The proxy interprets no request field but
  the operation code, so the protocol grows without it changing; it counts
  output in flight per peer (`xpc_connection_send_barrier`) and stops reading
  the socket — stalling the io side's PTYs — rather than queue without bound,
  and cuts a peer that will not drain (the app reconnects and replays). The
  other direction is bounded the same way: when the io socket's write
  backlog passes 1 MiB the proxy `xpc_connection_suspend`s every peer (a
  peer arriving mid-pause is suspended at registration) and resumes them,
  balanced, once it drains below 256 KiB — a paste into a program that is
  not reading stalls the pasters, not the proxy's memory. Keep
  Foundation out of it: `DaemonFileLog` uses `strftime`, not `DateFormatter`,
  for exactly this reason.
- Depends on the **released**
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm) package
  (`upToNextMajor` from 1.6.20260922, Ghostty 3c47ca15 on Zig 0.16). This
  revision fixes resize flicker from stale IOSurfaces, synchronized clears,
  and semantic prompt redraws. The text primitive is `paste(text:)`; the
  `sendText` spellings it replaced are
  gone, and they never typed keystrokes anyway. Below that: generated configs
  are scoped to the host's bundle id; the `<major.minor>.<YYYYMMDD>` track
  began in 1.5.20260903, Ghostty c4e16970a, with
  precision scroll, pointer style via `UIPointerInteraction`, and clipboard
  reads through the shared pasteboard reader; below 1.5.2 the UIKit view's resize
  throttle is armed before any size was sent and a surface keeps the
  session it was built with past teardown, the host-managed backend
  ignores LNM, and the shipped shell-integration scripts put the OSC 133;B
  mark before the user's `PROMPT_COMMAND`; below 1.5.0 the XCFramework has no
  visionOS slice and the wrapper does not compile for xros; below 1.4.9, `TerminalViewState` publishes
  from inside SwiftUI's update pass; below 1.4.10, a hardware Escape drops
  the keyboard on iOS instead of reaching the shell; below 1.4.11 it does
  the same on Catalyst, where it resigns the terminal and every key after
  it is lost until the next click; below 1.4.12 the UIKit view stretches
  the engine's layer to the new bounds while a resize throttle still
  holds the surface at the old size, and the whole pane flickers for the
  length of every throttled resize — which `TerminalTab`'s throttle, on
  for a tab with a program in front of its shell, opens on every drag).
  Since 1.4.0 the package's bare-semver tags are its own release sequence,
  decoupled from ghostty's;
  the `upstream.X.Y.Z` tags hold the XCFramework binaries. Terminal-library
  changes land in that repo and ship via a new package release — don't
  reintroduce a local path reference to a sibling checkout.
- **CI builds; Release publishes what CI built.** `ci.yml` compiles, packages
  and verifies all four flavours on every push and pull request, and keeps
  `build/Packages/` as the artifact `ighostvt-<sha>` for thirty days.
  `release.yml` runs on the tag, **compiles nothing**, waits for that commit's
  CI run, refuses to publish unless it passed, and attaches the bytes CI
  verified. Never rebuild at tag time: a second build is a different build
  number, a different runner image and bytes no test ever ran against. The
  workflow stays named `Release` — `pages.yml` watches for it, and
  `Scripts/release.sh` finds the run by that name and then checks all ten
  assets by name, so an asset that is renamed breaks the cut.
- **The release note is a file in the repo**, `Documents/Releases/<version>.md`,
  written before the tag: one headline sentence, one bullet per user-visible
  change with the symptom first, and a closing line naming which package to
  choose and `SHA256SUMS`. Never `--generate-notes`; the compare link it
  produces says nothing, and this text is what the Pages depiction serves as
  the changelog.

Generated Ghostty configs live under `tmp/wiki.qaq.iGhostVT/`, using the
library's `TerminalController.managedConfigDirectory`. `AppDelegate` calls
`GhosttyAppConfiguration.removeTemporaryFiles()` before creating terminals
at launch and on termination. Startup handles leftovers from force-quits
that receive no termination callback. Controllers still remove their own
files on replacement and destruction; old loose configs in shared tmp are
left alone.

## Layout

FlowDown-style: `iGhostVT/main.swift` (manual `UIApplicationMain`, which on
iOS first deletes this bundle's `.savedState` through `SceneRestorationReset`
— never on the Mac, where that folder holds AppKit's window frames) +
`Application/` (delegates) + `Backend/` (sessions, theme, transport) +
`Interface/<feature>/` + `Resources/`. The daemon is two programs:

- `iGhostVTDaemon/` builds `ighostvtd`, the proxy: `main.swift` +
  `Server/` (`DaemonServer` listener, `PeerAuthenticator`, `PeerRelay` per
  connection, `IOSupervisor` owning the child and the socket).
- `iGhostVTIO/` builds `ighostvtd-io`, the session host: `main.swift` +
  `Link/` (`IOHost`, and `PeerSession` — the old connection handler, now
  reached over the socket) + `Session/` (registry, PTY) + `Shell/`.
- `iGhostVTDaemonShared/` is compiled into **both**: `System/`
  (`RuntimeEnvironment` bootstrap paths, `PrivateSystem` C shims, `DescriptorIO`,
  `DaemonError`), `Logging/`, and `Link/` — `IOWire` (the frame format and
  the XPC ⇄ bytes codec) and `IOChannel` (the framed non-blocking socket with
  the read-pause / write-backpressure hooks flow control needs).

`iGhostVTCLI/` builds `ighostvt-cli`, a second *client* of the daemon —
one-shot commands (`list`, `capture`, `send`, `new`, `kill`), never an
interactive attach, so it neither holds a session nor touches the terminal
it was run from. It compiles `Shared/Protocol/` and nothing else the daemon
uses: its own XPC client (`DaemonClient`), the `capture` screen model
(`ScreenRenderer`), and the `send` key vocabulary (`KeyNames`). `ighostvtd`
depends on it, so every `-scheme ighostvtd` build produces it beside
`ighostvtd-io`. It ships *inside the app bundle* on both platforms
(`/Applications/iGhostVT.app/ighostvt-cli`, with a relative `/usr/bin`
symlink in the deb; `Contents/MacOS/ighostvt-cli` on the Mac) because the
daemon admits a peer by its executable path, and one rule then covers both
clients.

Shared XPC protocol in `Shared/Protocol/`, `ActivityAttributes` in
`Shared/Activity/`, the `TerminalTransport` seam in
`iGhostVT/Backend/Transport/` beside its XPC implementation (a plain file
in the app target — it was a local package once, and the module boundary
bought nothing). Prose lives in
`Documents/` — `ARCHITECTURE.md`, `Research/`, `CaseStudy/`, and `Web/`, which is the
GitHub Pages source: `.github/workflows/pages.yml` publishes `Web/`, so
the repo's Pages setting is **GitHub Actions**, not the legacy `/docs`
branch folder. Keep the site's `index.html` and `icon.png` at `Web/` root —
`manifest.json` and the AltStore-style clients fetch
`https://owngoal-dev.github.io/iGhostVT/icon.png`.

Settings ▸ About ▸ Licenses (`LicensesView`) is generated, not written: the
app target's **Collect Licenses** build phase runs
`Scripts/collect-licenses.py`, which writes `Licenses.json` into the bundle
from the repository's `LICENSE`, the vendored notices under `Licenses/`
(one folder per component, `LICENSE` + `notice.json`), and every package
pinned in `Package.resolved` — its checkout under DerivedData's
`SourcePackages` is walked for LICENSE / COPYING / NOTICE files, nested ones
included (that is how the iTerm2 color schemes and bash-preexec notices
inside libghostty-spm get in). `Licenses/ghostty/` exists because
libghostty-spm ships Ghostty as a prebuilt XCFramework and a binary carries
no license file; its version is read from the checkout's `Ghostty.ref` (the
pinned Ghostty commit — the package dropped `Ghostty.version` when it moved
to commit-only pins in 1.5.20260903).
A pin without a checkout, a checkout without a license, or GPL-family text
anywhere in the set fails the build — the .deb once shipped Ghostty's GPLv3
shell integration by accident, and this is the last check that it stays out.
The phase runs under Xcode's script sandbox, so every file it reads under
`SRCROOT` is a declared input; a new vendored folder must be added to the
phase's `inputPaths` in the pbxproj or an edit to it will not re-run the
phase. `make check` requires the phase and the Ghostty notice; both
packagers refuse a bundle without `Licenses.json`.

The `ighostvtd` target depends on `ighostvtd-io`, so `-scheme ighostvtd`
builds both and they land side by side (`/usr/libexec` on device,
`Contents/MacOS` in the Mac bundle); the proxy finds the child beside its own
executable. All three folders are file-system-synchronized groups, so a new
subfolder joins its target on its own — but `make harness` compiles by hand
and has to find them, so it globs `iGhostVTDaemonShared iGhostVTIO
iGhostVTDaemon` recursively; keep it that way.

The proxy ⇄ io wire: `[u32 len][u8 kind][u64 peer][u64 tag] payload`, kinds
request / reply / event / peerGone, payload a self-describing encoding of the
XPC types the protocol uses (a descriptor or mach port is refused, not
half-forwarded). `tag` 0 means a request that wants no reply, and every
event. The proxy stamps a unique peer id per connection; io makes a
`PeerSession` on first sight of one and retires it on `peerGone`.

Data flow: one `TabManager` per `UIWindowScene` (owned by `SceneDelegate`);
each `TerminalTab` owns a `TerminalSessionStore`, which drives a
`TerminalTransport`. Daemon sessions outlive the app —
`disconnect()` = detach, `closeSession()` = kill; `DaemonSessionLedger`
persists session IDs so a cold launch reattaches (256 KiB replay).
SSH later = another `TerminalTransport` implementation; don't collapse the
seam.

The CLI reaches those same sessions without disturbing them. Attach is
exclusive — one peer per session, a second gets `sessionBusy` — so
`ighostvt-cli` never attaches: `snapshotSession` (op 11) answers with the
size, the foreground process, and the replay buffer, exactly as an attach
reply does but leaving the attachment alone, and `injectInput` (op 12) is
`write` without the attachment gate. Neither is any new trust — every peer
is already past audit-token authentication and can `closeSession` anything
it can list. `listSessions` rows carry the live `proc`/`fgshell` and the
shell's `cwd` (the same kernel read `inheritDirectoryFrom` uses) so a
session can be named by something better than its id. The app sends neither
op; the daemon's `write` and attach paths are untouched.

The app's Shortcuts actions (`iGhostVT/Backend/Shortcuts/`, iOS 16+ behind
`#available`) are the CLI's verbs a third time. `ShortcutDaemonClient` is
the CLI's one-shot client with `async` in place of the semaphore — every
headless intent opens a connection, makes its requests, and cancels; none
attaches. One thing to know: the daemon attaches a *new* session to the
peer that opened it, so an intent that opens a session for a tab must
cancel its connection before `TabManager.openTab(attachingTo:)` — that is
why `OpenNewTabIntent` goes through `withConnection` first. Foreground
intents (`openAppWhenRun`) go through `ShortcutBridge`, which picks a
scene (the one showing the session, else the frontmost) because there is
one `TabManager` per window; it also answers `ighostvt://session/<id>` and
`ighostvt://new`, and nothing in a URL ever reaches a shell. Run Terminal
Command decides "done" as *foreground is the shell again and the transcript
changed* — a fast command can finish between two polls, so the shell flag
alone would report the old prompt as the result. Intent strings live in
`Localizable.xcstrings` like every other string (keys are the English text;
parameter summaries keep their `${param}` placeholders);
`Scripts/xcstrings-dump.py` writes the catalog in Xcode's own layout so a
scripted edit diffs as its additions only. `ScreenRenderer` and `KeyNames`
moved to `Shared/Screen/` for this, synced into the app and the CLI.

`capture` renders the replay itself (`ScreenRenderer`): the daemon keeps
bytes, not a grid, and libghostty could only turn them into a screen through
a live surface with a renderer attached. It is the subset that decides where
text lands — cursor, scroll region, erase, insert/delete, alternate screen,
character width — with attributes parsed and dropped, no reflow, and a
resync at the first byte that cannot continue a sequence (the replay buffer
is trimmed from the front, so its first bytes are routinely a fragment).
`Tests/CLIRenderer` is its own harness, run by `make test`.

Quitting is the app's decision, made in `applicationWillTerminate` from the
tabs of every connected scene: a tab whose shell is at its prompt
(`!hasRunningProgram`, the same test that lets its × close without asking)
is killed, a tab with a program running is left in the daemon for the next
launch, and with Keep Alive off everything goes. The kills travel over one
blocking one-shot connection (`XPCDaemonTransport.closeSessionsForQuit`) —
not the tabs' transports, whose `closeSession` is fire-and-forget on a queue
the exit outruns — and the call polls `listSessions` until the closed
sessions are gone, because a close reply only says the SIGHUP was sent. If
that leaves the daemon holding nothing, the Mac build sends `shutdown` and
the launch agent exits; the daemon's only part in this is a `registry.isEmpty`
guard on that one request. Its plist's `KeepAlive` is `{SuccessfulExit =
false}` for exactly this: a crash restarts, the asked-for exit stands, and
`MachServices` demand-launches it the next time the app connects. The device
LaunchDaemon keeps `KeepAlive = true` and is never asked.

The open request has two shapes and two keys. `cmd` is an argv run
verbatim — an absolute, executable path plus arguments, up to
`maximumCommandArgumentCount`, refused (`invalidRequest`) rather than
trimmed when longer — with the base environment (TERM, PATH, HOME, LC_CTYPE,
`SHELL` = the passwd shell) and no shell integration; this is what the
CLI's `new` and the Shortcuts send, and a one-word `cmd` is *that program*,
not a shell choice (`python3 -il` is not a session). `shell` is a bare path
naming the login shell to run interactively, with integration injected —
what the app sends for its Settings choice. Neither key is the default
shell.

A new tab opens where the current one is, and for a live session the
directory still never crosses the wire: `TabManager.newTab(.activeTab)`
names the active tab's daemon session (`inheritDirectoryFrom`, sent with the
open only — an attach reaches a shell that already sits somewhere), and
`SessionRegistry` reads *that shell's* current directory from the kernel
(`proc_pidinfo` / `PROC_PIDVNODEPATHINFO` on the child, not the foreground
program) and `chdir`s the new child there before `execve`. Nothing is typed
into a PTY, the app picks no path, it works for a shell with no OSC 7, and
the kernel's spelling is the one `chdir` wants, whatever vocabulary a
vroot-linked shell prints. A directory the session user can no longer enter
falls back to the plan's home, never to launchd's `/`. The iOS SDK ships no
`proc_info.h`, so the struct's ABI lives as constants in
`ProcVnodePathInfo`.

The new-tab menu needs the other half of that — a directory whose session is
long gone — so `startDirectory` names one outright. Only a path the daemon
itself reported may go there (`TerminalDirectory.path`, handed straight
back); the app composes none, `inheritDirectoryFrom` wins when both are
sent, and the registry checks it exactly as it checks an inherited one
(`enterableDirectory`: absolute, a directory right now), so a path that went
away means the home, never a failed open. That is also why the daemon
reports *two* spellings. Under roothide the kernel calls a shell's directory
`/var/containers/Bundle/Application/<uuid>/usr/src` and the vroot-linked
shell calls it `/usr/src`: `currentDirectory` is the first — the only one
`chdir` takes — and `displayDirectory` the second, sent only where they
differ and used for nothing but showing (`RuntimeEnvironment.displaySpelling`,
the inverse of `resolve` and not a general one: a directory outside the
jbroot is spelled the same by everyone). `TerminalDirectory` is the app's
pair of them.

Event 102 carries three things and fires when any of them moves: the
foreground process's name, whether that process is the session's own shell,
and where the shell is. The directory is read only while the shell *is* the
foreground — `cd` is a builtin, so nothing else can move it — and at most
once a second (`directoryPollInterval`), which is what notices a `cd` typed
at a prompt, since that changes no process at all. A client applies each
field on its own: an event may well say only that the directory moved.
`TerminalSessionStore` publishes it, `RecentDirectoryStore` counts it as one
visit (the transport emits changes only), and the Live Activity prefers it
over the shell's own OSC 7.

Tab titles have three sources. The daemon's is the one always there: each
session polls `tcgetpgrp` on its PTY (and re-checks as output drains, rate
limited — the drain sees one check per 64 KiB otherwise),
resolves the foreground process group leader's `proc_name`, and pushes it as
event 102 — also stated in every open/attach reply — so
`TerminalTab.secondaryTitle`, the dim line under the title, is a short stable
name ("zsh", "vim", "grok") no matter how often the program retitles, and a
session that reports nothing is titled by it. Ghostty's shell integration is the
second: the daemon injects it (`ShellIntegration`) and the .deb ships
libghostty's own scripts to `/usr/share/ighostvt/shell-integration`, so the
shell reports OSC 2 (command), OSC 7 (cwd), OSC 133 (prompts) by itself.
That injection reaches zsh, fish, and bash (which gets `--posix` in argv —
the daemon always spawns the shell directly, see the pam_launchd gotcha
below); a shell invoked as `sh` gets none. For it, `CommandTitleTracker` infers a title
from the line the user typed, and only if it was echoed to the screen — the
check that keeps a password out of the tab bar. The reported (or inferred)
title, trailing whitespace trimmed, is the tab's *title*
(`TerminalTab.displayTitle`), over the process name. Because all of these
live on *other* observable objects, the tab has to republish their changes
or no SwiftUI view redraws.

Every presentation of a tab — strip chip, title capsule, sidebar row, switcher
card — carries the same `TabContextMenu` (copy the page as text or image,
export it, lock, close). Close asks first only when it would interrupt
something: event 102 also says whether the foreground process group *is* the
spawned shell (`tcgetpgrp == childPID`, `foregroundIsShell`), and a connected
tab whose shell is at its prompt closes on the spot (`hasRunningProgram`). A
detached tab's last report is stale, so it still asks; an unknown state reads
as running. On the regular-width bar the trailing ⋯ button opens this same
menu for the active tab with New Tab and New Window at its head — the
strip has no + of its own.

Every `+` is a `NewTabMenu`: the only decision a new terminal has is where
its shell starts, so the control opens a menu of directories instead of a
tab. Three inline groups, in this order — the home; the directories this
window's own tabs are in, deduplicated and sorted by path, each naming a
live session (`inheritDirectoryFrom`) so the daemon re-reads it as the tab
opens; and the recent list, sorted by the order chosen in Settings ▸
Advanced. `NewTabDirectoryChoices` works all of that out once, because the
same answer decides whether there is anything to choose at all: with
nothing but the home to offer — a first launch, a window whose tabs have
not reported yet — the control stays the plain button it replaced, and ⌘T
is always `.activeTab` regardless. The ⋯ menu's New Tab is the same view
with a `Label`, so it becomes a submenu; that matters because on a phone
with tabs open the bar shows the title capsule and ⋯ is the only new-tab
control on screen. The sidebar row, the compact bar's `+`, the switcher's
dashed card and that entry are the four.

The recent list is `RecentDirectoryStore`, and it is the one thing about
sessions the app persists (`UserDefaults`): the daemon keeps no such record,
and the visit counts and the two spellings exist nowhere else. Every entry
came from event 102 — never from a shell's own OSC 7, which under roothide
is not a path anything can `chdir` to. Forty are kept, the least recently
visited evicted first whatever the sort order; eight reach the menu, minus
any directory an open tab is already offering and minus the home, which is
the first row anyway. Settings ▸ Advanced ▸ Recent Directories is the whole
of its configuration: Remember Directories both hides the group *and* stops
recording — a switch that says the app is not keeping this has to mean it —
Sort By is Last Visited or Most Visited, and Clear is the only thing that
throws the list away, so turning the switch back on restores it.

The two locks freeze the *user*, never the
program: output keeps flowing and the surface keeps rendering. They are
one choice (`TerminalTab.lock`, at most one of `.interaction` /
`.keyboard`): picking the other lock switches, picking the one that is on
clears it, and the `isLocked` / `isKeyboardLocked` flags the menus toggle
are views of that. Every presentation wears a `TabLockBadge` off the same
`tab.lock` — the filled padlock for both kinds; the overlay caption still
names which freeze is on. A sidebar row spends the close slot on that
padlock while locked (the × is gone, not a second glyph); close stays on
the context menu.
Both locks live on
`LockableTerminalView`, the app's `TerminalView` subclass installed through
the library's `makePlatformView` seam — refusing `hitTest` and first responder
closes every input path at once, which SwiftUI modifiers could not. That
factory closure reads the tab, because a view is made whenever the surface
mounts and one born after the user locked the tab would otherwise come up
unlocked.

The keyboard lock has to be enforced at the *input view*, not at the tap that
toggles it. libghostty becomes first responder from several other places — the
long-press selection menu, a pointer click, and the host's own `requestFocus`
after any sheet dismisses — and each of those raised the keyboard again while
the lock was on. Handing UIKit an empty `inputView` (and a nil
`inputAccessoryView`) closes all of them at once and keeps first-responder
status, so hardware keys still arrive. Empty the `inputAssistantItem` groups
along with it: the iPad shortcuts bar is not part of `inputAccessoryView`, and
it stays floating over the terminal with a dictation button, costing 40pt of
grid. On the Mac the keyboard lock is **not offered at all** (context menu,
menu bar and ⌥⌘K are `#if !targetEnvironment(macCatalyst)`, and
`TerminalWindow` answers the selector as disabled): there is no software
keyboard there, and hardware keys — every key a Mac has — pass through the
empty `inputView` by design, so the lock read as broken. The `TabLock.keyboard`
state and the Shortcuts vocabulary stay, for iOS and for shortcuts that sync
across platforms.

A tab switch on iOS does not raise the software keyboard unless it was
already up (`KeyboardState.isVisible`; the switcher snapshots that as it
opens, because the cover resigns the terminal). `requestFocus` is
`becomeFirstResponder`, which pops it; the previous surface already
resigned when the user tapped it away. A tap on the new terminal still
toggles it. Catalyst always hands focus over — there is no software
keyboard.

Every keyboard shortcut is a `UIKeyCommand` in the main menu — `AppMenus`,
installed from `AppDelegate.buildMenu` — never a SwiftUI `keyboardShortcut`.
The chords themselves are `KeyShortcuts.all`, one list read by three
places: the menu, `LockableTerminalView`, and Settings ▸ Keyboard ▸
Shortcuts. The terminal view is where the app's keys are actually won:
libghostty's `pressesBegan` swallows every hardware key without calling
`super`, so with a terminal focused UIKit (iOS 15+: responder chain first,
key commands only for an unhandled press) never fires the menu's commands
— ⌘1, ⌘T, ⌘W all went to the shell. `LockableTerminalView.pressesBegan`
matches a press against the enabled shortcuts before the library sees it
and sends the action down the responder chain (`sendAction(to: nil)`, so
`TerminalWindow.canPerformAction` still greys it), swallowing the release
too. Escape is never in the list; the library claims it under every
non-⌘ modifier and it always reaches the terminal. The settings page has
one switch per shortcut (`Shortcut.<id>` in UserDefaults; a hidden alias
follows its listed twin), sectioned by `ShortcutGroup`: off, the
interceptor lets the key through to the program and `AppMenus` builds
the item as a keyless `UICommand` (the alias is dropped), rebuilt on
every flip; nothing is rebound. The menu titles live in the catalog too,
so a new command is one `listed(...)` line there and one `command(...)`
in the menu. ghostty's own bindings on the same chords (`goto_tab`,
`new_tab`, `close_surface`…) are actions the library does not surface, so
a key that is off is a dead key, not a ghostty feature — except font
size and clear screen, which ghostty performs itself either way (the app
fronts them so the size preference follows).
One list feeds both the Mac's menu bar and the iPad's hold-⌘ overlay, and it
is where the system's own File ▸ New (⌘N, a window) and Close (⌘W, the
window) are replaced: in a tabbed terminal both keys belong to the tab.
`TerminalWindow` answers the commands, because the window is the one
responder every key passes through (sheets and the switcher included), and
its `canPerformAction` is what greys an item out — a command that would act
on whatever sits under a modal reads as disabled instead of failing quietly.
Bindings follow Terminal.app and Safari for tabs (⌃Tab, ⇧⌘\, ⌘1–9, ⌃⌘S for
the sidebar) and Ghostty for the terminal (⌘+ ⌘− ⌘0, ⌘K); where two
conventions coexist the second key is a hidden alias of the same action.
Close Tab is ⌘W alone — ⌘⌫ was tried as an alias and taken back, because in
a terminal it is delete-to-line-start (readline's ⌘⌫ on the Mac). On a
window with no tab left, ⌘W closes the window (the item retitles to Close
Window), and with the last window the app: the Mac goes through AppKit's
`terminate:` (`AppTermination`, the same call the relocation alert's Quit
makes) so `applicationWillTerminate` runs as for ⌘Q, iPad destroys the
scene, and a phone is sent home. The
font commands run ghostty's own `increase_font_size` actions on the active
surface and step `TerminalFontSize` alongside — they pre-empt the ⌘+/⌘−
press the library would otherwise have forwarded to ghostty itself. Menu
titles are hand-entered in `Localizable.xcstrings` (eleven languages,
`extractionState: manual`), and two keys made of the same words collide in
the catalog's generated symbols, which is why the menu's entry is keyed
`Settings… (menu)`.

## visionOS

A jailbroken Apple Vision Pro is the same product as a jailbroken iPad — the
app renders, `ighostvtd` owns the shells — so the tree builds for xros with
`make deb PLATFORM=xros` (roothide layout, `xros-arm64e`; `deb-xros` and
`deb-xros-rootless` are the shorthands, and ci.yml has a `package-xros`
job beside the two iOS ones). `PLATFORM` picks the SDK, the destination, the
`Build/Products/<config>-xros` directory, the architecture label's OS half,
and the control file's `Depends` (`firmware (>= 1.0)` there — the iOS
`firmware (>= 15.0)` would refuse to install on a visionOS 1.x/2.x
bootstrap); `PACKAGE_FLAVOR` stays the layout axis and is independent of it.
The daemon needed no source change at all; the app needed six guards, all
`#if os(visionOS)` nested inside code that is already UIKit-only, each around
one API the xros SDK lacks: `inputAssistantItem` and the `inputAccessoryView`
override (`LockableTerminalView`), `ActivityKit` (`SessionActivityController`,
`TerminalSessionAttributes` — the framework is absent from the SDK, so it is
`canImport`, and the widget target is already `platformFilter = ios`, which
keeps the appex out of the xros bundle), `glassEffect` /
`GlassEffectContainer` (`GlassStyle`, `AlertCardView` — visionOS windows are
glass already, the material fallback is the whole treatment), and the
keyboard-frame test in `KeyboardState` (the visionOS keyboard is its own
window; the frame says nothing). `XROS_DEPLOYMENT_TARGET` is 1.0 in
`Configuration/Base.xcconfig` — the lowest the SDK offers and what
libghostty-spm declares. The one thing that would raise it: two or more
children inside a single `#available` branch of a `@ViewBuilder` form a
`TupleContent`, whose `View` conformance the SDK dates to visionOS 26 with
no back-deployment (`TabContextMenu.lockControls` is split into one builder
per control for exactly this). libghostty-spm ships the xros and xrsimulator
slices since 1.5.0 (`upstream.1.3.1-2`); that repo's `Patches/ghostty/0012`,
`Patches/zig/` and the wrapper's own `os(visionOS)` guards are the other
half, and `Documents/Research/visionos-port.md` is the experiment log.
What is not known yet, because it takes the device: the bootstrap's dpkg
architecture (override `PACKAGE_ARCHITECTURE=` if it is not `xros-arm64e`),
whether `uikittools` exists there, and whether the M2's GPU user-client
classes match the AGX names in `Packaging/iGhostVT.entitlements` — a miss
is the same silent black terminal as on iOS, and the kernel log names the
class. Building the xros app locally on Xcode 27 needs nothing special;
building *libghostty* locally does (see that repo's
`Script/support/xcode27-sdk-overlay.sh`).

## Build & verify

- `make check` — project/packaging validation
- `make build` bumps `CURRENT_PROJECT_VERSION` before xcodebuild, so
  `Version.xcconfig` comes out of a build dirty by design
- `make test` — the PTY harness *and* the CLI's screen-renderer tests
  (`make harness` builds `ighostvtd-io` and
  spawns it as the proxy's child over a real socket, then drives the whole
  stack — the codec, a session's lifecycle, output routing, the flow-control
  pause and peer-cut, an io crash → respawn, and the shutdown-follow — plus
  the daemon's spawn path; launchd and the mach service are the only
  device-only parts)
- `make deb` — unsigned iphoneos build, ldid ad-hoc sign, roothide
  `iphoneos-arm64e` package; `make deb-rootless` packages the same binaries
  under `/var/jb` as `iphoneos-arm64` (`PACKAGE_FLAVOR` picks the layout)
- `make mac-run` — the whole stack on a Mac: builds `ighostvtd` for macOS and
  loads it as a per-user LaunchAgent (`make mac-daemon`, undone by
  `make mac-daemon-uninstall`; log in `~/Library/Logs/ighostvtd.log`), builds
  the app as Mac Catalyst (`make mac-app`), opens it. This is the off-device
  loop: the Simulator has no daemon, so nothing connects there. Device-only
  behaviour (the GPU entitlement, the bootstrap layouts, privilege drop,
  Live Activities, the software keyboard's accessory bar) is still debugged
  on the jailbroken device with the installed deb. `make mac-daemon` prints
  where it left `ighostvt-cli`; run it from there
  (`…/Debug/ighostvt-cli list`) — the daemon's DEBUG admission accepts the
  CLI built beside it, and the app itself only opens sessions from
  `/Applications`, so a CLI-opened session is the quickest way to have one.
- `make release VERSION=x.y.z` — the whole cut in one command
  (`Scripts/release.sh`): clean-tree/main/tag preflight, `set-version`
  (BUILD defaults to current+1), `make check`, the `x.y.z` commit, the
  tag, the push, waiting out the GitHub Release run, checking all ten
  assets, dispatching the APT repository build, and polling
  `https://apt.owngoal.dev/Packages` until the version is served — that
  poll is the acceptance test, because the APT run's own verify step has
  raced the CDN cache and reported failure after a successful deploy.
  `INSTALL=1` ends with `make mac-update-from-github` (Touch ID).
- `make mac-zip` — the *distributable* Mac build, a separate path from
  `make mac-run` (`mac-zip-check` validates its inputs; `Scripts/package-mac.sh`
  stages, signs, zips). Universal Release, ad-hoc signed by default, Developer
  ID and notarization optional via `MAC_ZIP_IDENTITY` / `MAC_NOTARY_PROFILE`.
  It deliberately does **not** depend on `make check`: that target requires the
  jailbreak toolchain, and a Mac with only Xcode has to be able to cut this zip.

The macOS product is one bundle carrying both programs — `Contents/MacOS/`
holds the Catalyst GUI and `ighostvtd`, and
`Contents/Library/LaunchAgents/wiki.qaq.ighostvtd.plist` (`BundleProgram`, not
`ProgramArguments`) is registered on first launch by `MacLaunchAgent` through
`SMAppService`. The two agent plists in `Packaging/macOS/` are not
interchangeable: the `@DAEMON@` one is the harness sidecar `make mac-run`
installs into `~/Library/LaunchAgents`, the `.agent.` one ships inside the
bundle. They share the label `wiki.qaq.ighostvtd`, so a stale harness job makes
`SMAppService` answer `kSMErrorInvalidSignature` — run
`make mac-daemon-uninstall` before testing a zip.

Gotchas that bit us:

- **The Mac app cannot be sandboxed, and neither can its helper.** macOS 14.2's
  Background Task Management refuses to let a sandboxed app register an
  unsandboxed `SMAppService` job, and the helper cannot be sandboxed either —
  it `forkpty`/`execve`s the user's shell, and children inherit the job's
  sandbox, so every command the user ran would inherit it too. This is not a
  flag to flip if something breaks; it is unsupported. Both
  `Packaging/macOS/*.entitlements` are empty dicts, `mac-zip-check` fails if
  `com.apple.security.app-sandbox` appears in either, and the hardening comes
  from Hardened Runtime (`codesign --options runtime`) instead.
- **Login Items binds to the path the app registered from.** A first launch out
  of Downloads registers a Gatekeeper-translocated mount that is gone by the
  next launch. `MacLaunchAgent` refuses to register outside `/Applications`
  and the window's alert offers to move the app there itself (Move or Quit;
  `moveToApplications()` moves or copies the translocation *original*,
  strips its quarantine flag so the copy is not translocated again, and
  launches it through `NSWorkspace` with `createsNewApplicationInstance`
  before this instance exits) — do not "fix" that by registering anyway.
  Dragging the app to the Trash does not unregister the agent either; the
  app offers no Turn Off of its own (registration is automatic on every
  launch) and Settings ▸ Advanced points at Login Items in System Settings,
  the system's own control, for removal. **Replacing the bundle in place (an
  update, a reinstall) breaks the registration, and `register()` alone
  cannot mend it.** Background Task Management stores a launch constraint
  with the item, and for an ad-hoc signed helper (no Team ID) it pins that
  build's cdhash. The next spawn of the new helper — at login, or from the
  updated app's own `register()`, which reuses the item — dies to AMFI
  (`Launch Constraint Violation`, an `ighostvtd` crash report with
  `SIGKILL (Code Signature Invalid)`), launchd removes the service, and
  BTM's `invalidateLaunchItem` ten seconds later leaves a job whose program
  is the unresolved relative `Contents/MacOS/ighostvtd`, retried every ten
  seconds ("Could not find and/or execute program") until something
  discards the item; a relaunch changes nothing. `SMAppService.status`
  reads `.enabled` throughout. `MacLaunchAgent` therefore fingerprints the
  bundled helper (SHA-256) and *rebinds* whenever the helper in the bundle
  is not the one whose registration last held — a missing record counts,
  so an update from a build without the check repairs itself once. Do not
  replace this with a plain re-register, and do not key it on the version:
  a locally cut zip can carry the same version as the one it replaces. The
  rebind (`MacLaunchAgent.rebind`, status `.rebinding`, "Updating Terminal
  Helper…" pill) is what the SDK header prescribes for a changed executable
  — unregister, then register — done the way the unified log says it has
  to be (`smd`, `backgroundtaskmanagementd`, `launchd`, read on
  2026-09-02 with an ad-hoc build over a Team-signed one). **`unregister()`
  does not remove the BTM item; it disables it**, and the `register()`
  after it logs `found existing item` and re-enables that same item with
  the constraint recorded for the *old* helper — so unregister → register
  alone can never mend a stale pin, and the old `try? unregister();
  register()` re-armed the same dead item on every launch. The fresh item
  comes from launchd: the re-enabled job spawns, AMFI kills the helper,
  launchd schedules a "repair LWCR update" spawn ten seconds out, and
  *that* spawn has BTM `invalidateLaunchItem` and create a new item. For
  an ad-hoc helper the repair itself then fails (`Unable to update LWCR
  with smd: 22`, "executable doesn't have a Team ID") and the job is left
  with the unresolved `Contents/MacOS/ighostvtd` — but an unregister →
  register *after* that point binds the new item to the helper on disk
  and it runs. So the rebind's rounds are: await the async `unregister`
  (its completion fires after the kill), poll `status` until BTM stops
  reporting the item, `register()` retried through BTM's settling window,
  then *ask the helper* (`XPCDaemonTransport.listSessions` over a one-shot
  connection, which demand-launches the job — the only test that means
  anything, since `status` says `.enabled` for a stale item too); no
  answer means **wait until twelve seconds after that register** and go
  again, three rounds, then `.failed` with Turn On Helper, which is the
  same rebind by hand. A round fired earlier "cancel[s] the throttled
  spawn" and re-enables the stale item once more — the first version of
  this did exactly that, three times in eighteen seconds, and never
  recovered. The digest is recorded only when the helper answered, so a
  rebind that did not take is retried at the next launch, never remembered
  as done. `refresh()` is a no-op while a rebind runs, so a scene
  activation cannot flip the status to the stale item's `.enabled` and
  start tabs connecting mid-sequence. After the fact, `launchctl bootout
  gui/$UID/wiki.qaq.ighostvtd`, delete the
  `MacLaunchAgent.registeredHelperDigest` default, and relaunch still
  works; `mac-update-from-github.sh` only waits for the helper now and
  must not bootout or relaunch inside the rebind's window. The whole
  class disappears with a Team ID: BTM keys a Developer ID signature's
  constraint on the team, not the cdhash, so
  `Scripts/mac-update-from-github.sh` re-signs the downloaded bundle with a
  local Developer ID Application identity when the keychain holds one
  (metadata preserved — the CLI's identifier stays the daemon's contract),
  and an update signed by the same team replaces the helper cleanly.
  **Never hardcode a Team ID or a person's Developer ID anywhere in the
  repo** — not in the update script, the packagers, the Makefile, or an
  entitlements file. The identity is always *discovered*: the keychain
  (`security find-identity`, matched by the certificate-type prefix
  `Developer ID Application:` only), the installed bundle's own
  `TeamIdentifier` (read with `codesign -dv` at run time, to prefer the
  team the app already carries), or the `MAC_ZIP_IDENTITY` /
  `MAC_UPDATE_IDENTITY` environment overrides. A literal identity would
  pin the repo to one person's certificate and silently break every other
  machine's build and update. `make check` rejects any `Name (TEAMID)`
  shaped literal in `Scripts/`, the `Makefile`, and `Packaging/` — keep it
  that way.
- **A drop pastes a path the shell can use, and where that path comes from
  depends on where the item lives.** `TerminalDropDelegate` replaces the
  library's drop interaction on both platforms (it has to *replace* the
  interaction rather than override the method: `dropInteraction(_:performDrop:)`
  is `public`, not `open`). A Finder drag on Catalyst pastes the item's own
  path, opened in place — a folder as readily as a file. A Files drag on iOS
  has no path a shell in another process could open, so the item (folder
  included) is copied under `TerminalFileStaging.directory` and that path
  is pasted. Data with no file behind it (Photos, a Mail attachment, an image
  off a web page) is written there too, named for its UTType so the path
  carries a real extension. Links and text snippets paste as text. The
  library's own staging API is internal, so the copy lives in the app; only
  the directory and the stale sweep are shared with pastes.
- **The Mac window's chrome is AppKit's, reached through the ObjC runtime.**
  `CatalystWindowChrome.install()` (called from `main.swift`, before any
  scene) hooks `UINSApplicationDelegate didCreateUIScene:`. The sidebar has
  no blur on the Mac — a behind-window `NSVisualEffectView`/`NSGlassEffectView`
  was tried and taken out (glass under the bar's glass controls, and the
  toggle transitions across it rendered as black discs): `RootView` paints
  the theme's background under the whole window, so the sidebar is the
  terminal's own colour — and the iPad's sidebar is the same, its
  `.regularMaterial` gone (it tinted the theme into a third colour neither
  column had). The title bar is hidden and `RootView` ignores the top safe area,
  so the top bar rides the window's edge and is the title bar now: the
  traffic lights are moved to its vertical centre (`standardWindowButton:`,
  re-done on every `NSWindowDidResizeNotification`, since AppKit re-tiles
  them), the sidebar keeps a strip of the bar's height above its list, and
  the bar beside a hidden sidebar starts after `windowControlsEnd`, its own
  8pt padding being the gap to the lights. The
  lights' geometry is *screen* points and gets converted: the iPad-idiom
  Catalyst app draws at 77%, so a UIKit inset sized in the app's own points
  lands 23% short of the lights. `WindowDragRegion`,
  behind the bar and the sidebar's strip and footer, moves the window from
  bare chrome (`performWindowDragWithEvent:` on `NSApp.currentEvent`).
- `SMAppService` is `macCatalyst(16.0)`, above this app's iOS 15 deployment
  target, so every call sits behind `#available`. The packager raises the
  staged bundle's `LSMinimumSystemVersion` to 13.0, since a Catalyst app built
  for iOS 15 otherwise advertises macOS 12, where none of this exists and the
  terminal would simply never connect.

- **The PTY's winsize must be the *last* grid the surface reported, and
  only the relay's record of that grid may ever be re-sent.** Reports come
  off ghostty's IO thread; the transport queue, the main actor (`Task`), and
  the daemon's open/attach reply each see them at their own pace.
  `TransportRelay` keeps the record under the lock the reports take, primes a
  freshly installed transport with it, and replays it from the transport's
  `.connected` event — synchronously, on the transport's queue, before the
  hop to the main actor — so a size reported during the round trip lands
  behind the open or attach. The transport itself never replays a size; it
  only dedupes against what the daemon already holds. Never re-send a
  main-actor copy: at cold launch that copy trails the IO thread, lands after
  the settled grid, and — because the library reports only *changes* — leaves
  a 49×16 PTY under a 93×32 surface until the next real resize. That 49×16 is
  the surface's birth size before its first `setSize`, not a transient layout.
- **A PTY master takes about a kilobyte and no more, so input is buffered,
  never truncated.** XNU accepts up to `TTYHOG - 2` (~1022 bytes) ahead of
  the program reading the terminal and answers `EAGAIN` for the rest — and a
  paste is one write of the whole clipboard. `PTYSession.write` used to hand
  that to `writeFully` and drop whatever the kernel refused, so a 13 KB paste
  reached the shell as its first 1022 bytes, cut mid-character, with the
  bracketed-paste terminator lost behind it: the program stayed in paste mode
  and ate every key after. It now queues the remainder in `pendingInput` and
  feeds it from a `DispatchSourceWrite` on the master (a PTY reports writable
  exactly when the slave's input queue has room), bounded by
  `sessionPendingInputByteCount` — a request that would pass the cap is
  refused whole as `inputBacklog`, never trimmed. **Nothing on this path may
  block**: it runs on the io side's one control queue, so a blocking write is
  the whole daemon stalled behind a program that is not reading.
  Correspondingly, every client sends input in `inputChunkByteCount` (512
  KiB) messages — a single message may only carry
  `maximumMessageDataByteCount`, and the daemon refuses more outright, which
  is how a large paste used to vanish entirely. The chunks are **not**
  acknowledged and must not be: XPC drains one connection's messages FIFO,
  the proxy forwards frames in the order it reads them, and the session
  appends them in the order it is handed them, so order is already
  guaranteed — waiting for a reply per chunk would only pace every paste at a
  round trip. The harness proves both halves (26 KB byte-for-byte through a
  raw-mode `cat`, and a chunked paste through the real proxy).
- A shell inherits both the daemon's resource limits and every descriptor
  that survives `execve`. Keep an explicit launchd `NumberOfFiles` soft limit
  sized for user workloads, and mark every daemon-owned session descriptor
  `FD_CLOEXEC` as soon as it is acquired; otherwise later shells retain older
  PTYs and lose capacity from their own per-process fd limit. The harness
  proves it with `lsof` on a spawned shell.
- **XNU posts `NOTE_EXIT` before the child is waitable.** `proc_exit` fires
  the kqueue note, *then* marks the process `SZOMB` and signals `SIGCHLD`. A
  process dispatch source that reaps exactly once can therefore see
  `waitpid(WNOHANG) == 0` and never try again — a zombie shell and a tab
  that never learns it died. `PTYSession` polls until reaped on every exit
  signal (the note and the PTY's EOF), and `SessionRegistry` sweeps every
  session on `SIGCHLD`, the one notice sent after `SZOMB`. `SIGCHLD` stays
  `SIG_DFL`: `SIG_IGN` auto-reaps and a `waitpid` racing that can block.
- **The CLI's macOS signing identifier is a contract with the daemon.** A
  bare Mach-O is signed under its file name unless told otherwise, and
  `MacPeerPolicy` requires `identifier "wiki.qaq.ighostvt-cli"` — so
  `package-mac.sh` signs it with an explicit `--identifier`, and `make check`
  fails if the two strings drift apart. Each client is judged against *its
  own* identifier-and-sibling pair, never the union, so a binary signed as
  one and placed where the other belongs satisfies neither. On the device the
  rule has the same shape: a second entry in `clientPaths`. The deb's
  `/usr/bin/ighostvt-cli` must stay a **relative** symlink — under roothide
  an absolute `/Applications/...` resolves against iOS's filesystem, not the
  bootstrap's — and `proc_pidpath` reports the target it executed, so
  admission sees the bundle path either way.
- **A Catalyst app cannot carry the client entitlement.** It is an
  iOS-family binary, and macOS refuses to launch one with an entitlement no
  provisioning profile granted ("Launchd job spawn failed"), ad-hoc signed
  or not. The Mac build is signed with no entitlements and the macOS daemon
  authenticates it by uid and `iGhostVT.app/Contents/MacOS/iGhostVT` path
  instead (`PeerAuthenticator`, `#if os(macOS)` only — the device policy is
  untouched).
- libghostty asks the host before a protected clipboard operation (an OSC 52
  read, a write under `clipboard-write = ask`, a paste that paste protection
  flagged) and **denies it silently when nobody answers**. `RootView` attaches
  `ClipboardConfirmation`, which presents each request as an alert; do not
  remove it or programs' clipboard reads and multi-line pastes into
  non-bracketed programs vanish without a trace.
- **Never spawn sessions through the bootstrap's `login`.** Procursus's
  `/etc/pam.d/login` runs `pam_launchd.so`, which moves the session into a
  per-user bootstrap namespace that cannot reach `com.apple.dnssd.service`;
  iOS has no `/etc/resolv.conf` fallback, so the session keeps TCP but loses
  DNS entirely — `curl` says "Could not resolve host" while
  `curl --dns-servers 8.8.8.8` works. Procursus comments that module out of
  `pam.d/sshd`, which is why ssh sessions resolve. The daemon spawns shells
  directly (no PAM) and supplies the env/uid `login` would have.
- Never redeclare C-variadic functions (e.g. `ioctl`) via `@_silgen_name`
  with fixed arity — arm64 puts variadic args on the stack and the call
  silently misbehaves. Use the Darwin overlay.
- **Never name an SDK `XPC_*` macro in Swift.** `XPC_TYPE_DICTIONARY` and its
  siblings are libSystem globals that have existed since iOS 8, but the iOS 27
  SDK also ships a Swift overlay for XPC, and in Swift those spellings resolve
  to accessors exported by `/usr/lib/swift/libswiftXPC.dylib`. The overlay's
  `.tbd` carries no back-deployment metadata, so ld links that dylib
  **non-weakly** however low `IPHONEOS_DEPLOYMENT_TARGET` is — and the dylib
  does not exist on iOS 15. dyld kills the process before `main`: "Library not
  loaded: /usr/lib/swift/libswiftXPC.dylib". It is present from iOS 17.3.1;
  iOS 16 is unverified. Reading the macros through C keeps them the old
  globals, and with no overlay symbol used the linker marks libswiftXPC weak by
  itself (only the weak `_swift_FORCE_LOAD_$_swiftXPC` reference is left).
  `import XPC` alone is harmless. So the constants live in
  `Shared/XPCShim/shim.h` as static inline C, reached through the
  `CiGhostVTXPC` module (`SWIFT_INCLUDE_PATHS` in `Configuration/Base.xcconfig`,
  `-I` in the harness), and Swift says `iGhostVTXPC.typeDictionary`
  (`Shared/Protocol/iGhostVTXPC.swift`, compiled into all four targets).
  `make check` fails on a Swift file that spells one; the folder is
  deliberately not a synchronized group, so it joins no target's sources.
  After a change here, prove it: `otool -L` must show libswiftXPC as
  `, weak)` or absent on every product.
- **Never hardcode a bootstrap path.** `RuntimeEnvironment` detects the layout
  from the daemon's own executable path and exposes the three vocabularies:
  `bootstrapPath()` (a file the bootstrap installed), `systemPath()` (a file
  on the untouched iOS filesystem), `resolve()` (either one, as a syscall
  wants it). roothide's programs are vroot-linked so their paths stay
  unprefixed and iOS's are reached via `/rootfs`; rootless programs have
  `/var/jb` compiled in and speak real paths. Prefixing the wrong one is
  *the* bug this type exists to prevent.
- When the sandboxed app offers bootstrap executables, let the daemon test a
  small fixed candidate list through `RuntimeEnvironment` and return stable,
  unprefixed paths. Do not enumerate binary directories or persist a resolved
  install root; the custom path covers tools outside the common list.
- **A connected terminal with nothing on it is not necessarily broken —
  the first shell after a userspace reboot takes ~30 s to print a byte.**
  Measured on the iPad (0.5.0, load average 300–500 in the minute after
  `launchctl reboot userspace`): the daemon reads the session's first
  bytes 27–32 s after `forkpty`, the app's XPC handler has them 1 ms
  later, and a session opened by `ighostvt-cli new` at the same moment
  (no app involved) is just as late. The shell spends that time in its rc
  files — `listSessions` shows the foreground cycling through `git`,
  `mkdir`, `grep`, `ls` — on cold caches, and, on a jailbreak, on the
  first exec of every binary the rc runs (trustcache / AMFI work that a
  later shell no longer pays). The surface, the session binding, the
  display link, and the transport were all verified fine throughout; what
  was wrong was the *presentation*: the "Connecting…" pill left the moment
  the daemon answered `openSession`, so for half a minute there was an
  empty pane and no hint that anything was coming, and a second tab
  opened afterwards "rendered fine" only because the first shell had
  warmed everything. The fix is `TerminalSessionStore.isAwaitingFirstOutput`
  ("Starting shell…" pill after a second of silence, cleared by the first
  byte) plus an explicit `cursor-style-blink = true`. Two lessons for the
  next "first terminal sits blank" report: (1) check `ighostvt-cli
  capture` *with a timestamp* before touching the view stack — an empty
  replay buffer means the shell hasn't spoken, and no surface fix will
  draw what does not exist; (2) the unified-log relay (`log stream`,
  Console.app, `pymobiledevice3 syslog`) drops most of the app's lines
  while the device is that busy, and a userspace reboot kills the tunnel
  anyway — turn on Settings ▸ Advanced ▸ Detailed Terminal Log and read
  the app's journal instead (Settings ▸ Advanced ▸ Logs, or
  `Documents/Journal/Dog_*.log` in the app's container), beside the
  daemon's own `/var/mobile/Library/Logs/ighostvtd.log`, which now stamps
  each session's first output.
- **Every line the app logs goes through `AppLog`** (`Backend/Logging/`):
  Dog's journal on disk — one `Journal/Dog_<date>_<id>.log` per launch
  under the container's Documents on the device and under
  `~/Library/Logs/iGhostVT` on the Mac (the Catalyst app is unsandboxed,
  so its Documents is the user's own), the last 32 kept, opened first
  thing in `didFinishLaunching` —
  and the unified log (`wiki.qaq.iGhostVT`, one category per
  `AppLog.Category`). No `os.Logger` of its own anywhere else, no `print`:
  the file is what survives a busy device, and the viewer reads only it.
  Settings ▸ Advanced ▸ Logs (`LogViewerView`, `LogReader`) shows that
  journal or the daemon's file, switched from its ⋯ menu; the daemon's
  path is `iGhostVTProtocol.daemonLogPath` because the app reads what
  `DaemonFileLog` writes, and `LogReader.parseDaemonLine` mirrors that
  line format — change one, change the other. The Detailed Terminal Log
  switch only widens what libghostty's `TerminalDebugLog` emits; its
  lines land in the same journal under the `ghostty` tag at verbose.
- A GUI app ad-hoc signed with ldid MUST carry
  `com.apple.security.iokit-user-client-class` (with `IOUserClient` / the
  AGX + IOGPU + IOSurface + IOAccel leaves, see
  `Packaging/iGhostVT.entitlements`). This is a jailbroken-iOS property, not
  a roothide one — the rootless package needs it just the same. Without it
  the kernel denies the GPU's IOKit user client — `no-sandbox` does NOT cover
  this — Metal can't create a device, and the symptom is a silent black
  terminal: no crash, ghostty logs `error.MetalFailed` / "surface rebuild
  failed", the kernel logs `deny(1) iokit-open-user-client
  AGXDeviceUserClient`. A vphone guest uses the same gate with the exact
  class `AppleParavirtDeviceUserClient`; keep it in that allowlist or the
  daemon and CLI will work while the app never creates a surface or sends an
  `openSession` request.

## RootHide runtime dependency policy

Evaluate official `libroothide`/`libvroot` before adding a new bootstrap path
shim. This native app/daemon currently keeps a physical-path contract: process
identity, filesystem decisions and Foundation must refer to the same path.
Do not apply `symredirect` to only one side of that boundary. Packaging rejects
an accidental vroot dependency on the native daemon. Both package layouts may
reuse these native binaries; `libvroot` itself is RootHide-specific and is not
made rootless-compatible by changing the Debian architecture label.
References: `roothide/Developer`'s `vroot.md`, and `roothide/libroothide`'s
`init.c` and `stub.h`. `libroot` is a separate Rootless v2 path API.
