# iGhostVT — Agent Notes

Ghostty-powered terminal for iOS 15+ on custom firmware — roothide and
rootless bootstraps both — and for the Mac; visionOS is no longer supported. The app
renders; the bundled `ighostvtd` LaunchDaemon owns every terminal session. `ighostvtd` is a thin XPC proxy under launchd's 6 MB
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
  and cuts a peer that will not drain (the app reconnects and replays) —
  one that takes *nothing* for the grace, since every byte it does take
  pushes the deadline back: `ighostvtd-remote` behind a slow relay is
  congested for minutes and draining all along, and cutting it after ten
  seconds is what dropped an `sz` mid-file. The helper's own pause band
  (512 → 384 KiB) is narrow for the same reason: while it holds the
  connection suspended it takes nothing. The
  other direction is bounded the same way: when the io socket's write
  backlog passes 1 MiB the proxy `xpc_connection_suspend`s every peer (a
  peer arriving mid-pause is suspended at registration) and resumes them,
  balanced, once it drains below 256 KiB — a paste into a program that is
  not reading stalls the pasters, not the proxy's memory. Keep
  Foundation out of it: `DaemonFileLog` uses `strftime`, not `DateFormatter`,
  for exactly this reason.
- Depends on the **released**
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm) package
  (`upToNextMajor` from 2.2.2026101001, Ghostty 35a81a98 on Zig 0.16). 2.x
  selects text inline on iOS — a long press puts handles and the edit menu
  on the terminal itself — and removed the long-press hand-off
  (`onTextSelectionRequest`) the app's own selection sheet hung off, so the
  app has no selection UI of its own; customise the menus through
  `touchMenuItems(for:)` / `touchSelectionMenuItems(for:)` on
  `LockableTerminalView`, never by bringing a sheet back. Match an item
  there by its identifier (`terminal.copy`, `terminal.paste`, …), never by
  its title: since 2.2.2026100701 the titles are localized, and they follow
  the user's language only because `Info.plist` sets
  `CFBundleAllowMixedLocalizations`. That release also adds the iOS 17+
  selection loupe and puts away, on a tap, the accessory bar iOS 27 left
  behind after hardware-keyboard input; below it the touch menus read
  English on every system. 2.2.2026100702 applies the surface option's
  `fontSize` as a set size, so a config reload (a theme change, the system
  switching light and dark) no longer snaps an open tab to the config's
  `font-size` — which, after Settings ▸ Text Size changed, resized tabs
  that should keep theirs — and reports the size back
  (`TerminalViewState.fontSize`). 2.2.2026101001 draws a symbol key of
  the accessory bar as all of its text on one line, in a capsule that
  widens to fit (`TerminalInputAccessoryItem.buttonTitle`, which the
  app's key editor reads too), and takes a presentation for it:
  `.symbol(text, presentation: .text(label) / .image(…))`. Settings ▸
  Accessory Keys builds on that: a custom key (`KeyboardBarKey.custom`,
  persisted as `custom:` + JSON beside the `sym:` codes) shows a label of
  its own while it sends its text, and tapping a character key on the
  bar opens it in the key editor. The editor's one appearance field is
  the Nickname; the code also reads an SF Symbol look, which an edit
  keeps while no nickname is given. Hidden, until a UI for it is
  decided: an image dropped on the editor brings up Fill with Image and
  Delete Image, and a saved one is a PNG in Application Support
  (`KeyboardBarPictures`, swept of files no key names on every save)
  that fills the round button. In the editor's lists a plain symbol key's circle is empty —
  its name spells what it types. iOS only — the
  bar does not exist on Catalyst. 2.2.2026100901 copies without the
  padding a TUI paints around its lines — trailing blanks off every line,
  and at most the selection's start column of indent off every later one
  (`TerminalCopyText`) — from the touch selection, the menu's Copy and ⌘C
  alike, and the touch highlight covers only each row's text; Claude
  Code's rows are separate lines with no soft-wrap mark, so the line
  breaks themselves stay. 2.2.2026100801 repeats a held
  arrow, Home/End or function key on Mac Catalyst, at the user's Key Repeat
  setting — UIKit reports such a press once there and spent its repeats on
  the empty text document, so a held arrow moved one step; text keys were
  already repeated by the system — and ends the repeat when the window
  loses the keyboard or a key command fires. 2.2.2026100703 keeps
  `TerminalViewState.backgroundColor` following the color scheme when a
  view whose delegate is not the state switches it through the controller;
  the app's views always have the state as delegate and read no background
  from it, so nothing here changed. 1.6.20261003 makes
  a tap below the cursor row, when nothing has mouse
  capture, click the cursor's cell, so raising the keyboard no longer
  pushes the top lines into scrollback; 1.6.20261002 bounds the main-queue
  work an output flood can cause — the view state's publishes (title, pwd,
  scrollbar…) coalesce into at most one flush per turn and off-main
  wakeups into one outstanding hop — and gives `InMemoryTerminalSession`
  an output-backlog API
  (`pendingOutputByteCount`, `setOutputBacklogHandler(highWater:lowWater:)`);
  it moves to DisplayLink 3.0 (the package formerly named MSDisplayLink).
  1.6.20260929 handed the hardware presses ghostty ignores (Caps Lock, bare
  modifiers, language keys) on to UIKit, so an iPad keyboard can switch
  input language in the terminal, and publishes the surface's effective
  background (`TerminalViewState.backgroundColor`, OSC 11 included);
  1.6.20260928 gave the UIKit view key repeat — a held hardware key, and the
  software keyboard's held backspace, repeat instead of firing once; below
  1.6.20260928 they fired once. 1.6.20260922 fixed resize flicker from stale
  IOSurfaces, synchronized clears, and semantic prompt redraws. The text
  primitive is `paste(text:)`; the
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
  and verifies all three flavours on every push and pull request, and keeps
  `build/Packages/` as the artifact `ighostvt-<sha>` for thirty days.
  `release.yml` runs on the tag, **compiles nothing**, waits for that commit's
  CI run, refuses to publish unless it passed, and attaches the bytes CI
  verified. Never rebuild at tag time: a second build is a different build
  number, a different runner image and bytes no test ever ran against. The
  workflow stays named `Release` — `pages.yml` watches for it, and
  `Scripts/release.sh` finds the run by that name and then checks all eleven
  assets by name (and then waits for Notarize's twelfth), so an asset that
  is renamed breaks the cut — and the app's Check for Updates, which fetches
  the notarized zip and the two debs by the same names. The relay's
  container image follows the same rule: CI pushes
  `ghcr.io/<owner>/ighostvt-relay:sha-<commit>` (every event but a pull
  request), and the Release run only gives that digest its release tags
  (`x.y.z`, the relay protocol's version, `latest`), records it in
  `relay-image.txt`, and attaches the `compose.yml` CI handed over.
  `release.sh` checks the version tag names the digest CI built.
  Notarization follows the same rule: `notarize.yml` (Notarize) runs when a
  Release run succeeds, downloads the macOS zip that run published, checks
  it against `SHA256SUMS.macos`, and changes only its signatures
  (`Scripts/notarize-mac-release.sh`: Developer ID inside out with the
  identifiers and empty entitlements kept, hardened runtime, notarytool,
  staple) before attaching `iGhostVT-x.y.z-macos-notarized.zip` beside the
  ad-hoc one and adding its line to `SHA256SUMS.macos`. It compiles nothing. The identity and the notarytool profile
  are one keychain held in two secrets, `NOTARY_TOOLBOX_ZIP_BASE64` (a zip
  holding the `.keychain-db`) and `NOTARY_TOOLBOX_PASSWORD`; the script reads
  the identity and the profile out of it and names neither. A release cut
  before this existed is notarized by dispatching Notarize with its tag, and
  the script runs on a Mac too (`KEYCHAIN_DB`, `KEYCHAIN_PASSWORD`,
  `NOTARIZE_UPLOAD=0` to keep the zip).
- **The relay never terminates TLS, and two devices talk only on the same
  release line.** The relay (`Relay/`) splices TCP and reads nothing but a
  ClientHello's SNI; the remote-access TLS-PSK runs end to end. The app and
  the helper stay on system frameworks only (Network.framework, CryptoKit,
  Security) — no Noise, no NIO, nothing that grows the bundle. A remote
  `hello` or `pairStart` from another major or minor version is refused
  (`unsupportedVersion`), so a new operation needs no compatibility path —
  and a **patch release may never add one**: every patch of a line talks to
  every other (`RemoteAccess.isCompatible`). On the wire a device says its
  line as `x.y.0` (`RemoteAccess.wireVersion`) — 1.4.0 compared the whole
  string, and `x.y.0` is what keeps a 1.4.1 acceptable to it. The build
  number is not part of the version.
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

Settings is a sheet on iPhone and iPad and a window of its own on the
Mac (`Interface/Settings/Mac/`): a second scene configuration
(`Settings`, `SettingsSceneDelegate`, chosen by `AppDelegate` when the
activation carries `wiki.qaq.ighostvt.settings`) with a `.preference`
toolbar of panes. `CatalystWindowChrome` leaves that window alone, a
restored one closes itself at launch, and ⌘W closes it. Each pane is a
child `UIHostingController` laid out at the window's width and pinned
under the toolbar by Auto Layout; its preferred content size is the
window's height, set straight away (a spring was tried and read as
sluggish) and never from inside a layout pass — resizing there made
AppKit throw on the layout loop. No SwiftUI frame reader decides the
size. The app runs in the iPad idiom, so the system checkbox is out of
reach: `UISwitch.preferredStyle = .checkbox` and its `title` throw
outside the Mac idiom, and `MacCheckbox` draws AppKit's instead.

Settings ▸ Ghostty Configuration is the user's own ghostty lines
(`GhosttyAppConfiguration.customConfigurationKey`). They ride on the
*theme* (`GhosttyAppConfiguration.theme(custom:)`), not the overlay: the
library writes the theme after the overlay and a later line wins, so a
custom colour on the overlay would lose to the theme it was meant to
change. Each `TerminalTab` snapshots the text when it is made and a theme
change re-applies that snapshot, which is what keeps "open tabs keep the
configuration they were opened with" true. The field straightens smart
quotes and dashes as they are typed — ghostty reads neither as syntax.

Check for Updates (`UpdateCheck`) asks GitHub's API for the latest release
and, when that is newer than `CFBundleShortVersionString`, downloads the
one asset that fits this install. On a device it is a button in Settings ▸
Advanced that runs under an `AlertViewController` of its own — live text
and a progress bar (`AlertViewController.Content`, `AlertCardView`'s
`progress`) over a Cancel that is always there to press — closed with
`close(then:)` once the check is done, so the next thing is not stacked on
it: the share sheet with the deb for this bootstrap, which a package
manager installs ahead of the APT repository, or an alert with any other
answer. The bootstrap is read off where the app sits (inside what `/var/jb`
resolves to is rootless, a jbroot's `Applications` is roothide; anywhere
else, the Simulator included, the button is hidden — Debug builds take
`UpdateCheck.packageArchitecture` from the defaults). On the Mac the only
way in is Check for Updates… under About in the application menu, whose
title is the progress (`AppDelegate.validate`, never a menu rebuild); the
notarized zip — never the ad-hoc one — lands in Downloads, quarantined as a
browser would so Gatekeeper's first-open check is the notarization check,
and is shown in the Finder. Bytes are kept only when they match the SHA-256
GitHub reports for the asset. It installs nothing and spawns nothing.

## Ghost Remote

The `GhostRemote` target is a second app built from the same sources: the
remote-access client alone, for an iPhone or iPad without custom firmware.
It runs sandboxed, has no daemon, and ships as an ad-hoc signed `.ipa`
(`make ipa`) that whoever installs it re-signs — never through the App Store,
because pairing uses the system's private SPAKE2+ (`CoreCryptoShim`). It
shares `Version.xcconfig` with iGhostVT on purpose: a paired device must be
on the same release line (`RemoteAccess.isCompatible`), so the two apps are
cut from one tag.

- **One switch, `AppEdition.isRemoteOnly`** (`GHOST_REMOTE` in the target's
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS`). Code reads the constant rather
  than `#if`, so both apps compile every branch. The local daemon is closed
  at its three doors — `XPCDaemonLink.init`, `oneShotRequest`,
  `closeSessionsForQuit` — and everything built on them fails soft.
- The target shares the `iGhostVT/` folder with its own exception set: it
  drops the app's `Info.plist` and `InfoPlist.xcstrings` (its own are in
  `GhostRemote/`) and the four Shortcuts intent files, which only speak to
  a local daemon. `ShortcutBridge` stays.
- Every tab is remote. `TabManager.newTab` sends an origin on this device
  to the active tab's device, else `RemoteTabDefaults.preferredHostID`, and
  with nothing paired opens Settings ▸ Remote Access and no tab — the `+`
  is the way to pair. The menus lose this device's rows.
- A cold launch reattaches through `RemoteTabLedger`, written whenever a
  window goes to the background (iOS kills a suspended app without a
  word), and a return to the foreground retries every tab's link at once.
  Leaving with a remote tab open — in either edition — holds a background
  task (`RemoteBackgroundGrace`, no `UIBackgroundModes`: none of them is
  this), so a short trip away keeps the links, a transfer included; it
  ends on return, when iOS calls time, or with the last remote tab.
- The Live Activity, and no other widget: `GhostRemoteWidgets` builds the
  `iGhostVTWidgets/` sources a second time (bundle id
  `wiki.qaq.GhostRemote.widgets`, a host's bundle id must prefix its
  extension's), named for this app through `WIDGETS_DISPLAY_NAME`, which
  each widget target sets and the extension's Info.plist reads. It asks
  for no entitlement — Live Activities need only `NSSupportsLiveActivities`
  — but it is one more App ID for whoever signs the .ipa, which a free
  account has few of; it was left out for that reason until people asked
  for the activity. A suspended app's links are down, so the activity
  shows the tabs as they were until the app comes back. The bundle id is
  rewritten by most signing tools, so nothing may depend on it.
- CI's `package-ipa` job builds `GhostRemote-<version>.ipa` from the same
  run number as the debs (`make ipa` seals the extension first, then the
  app), refuses one carrying any extension but `GhostRemoteWidgets.appex`
  or any entitlement on either (a free
  certificate cannot grant it, and AltStore 2 refuses an app whose
  entitlements or usage descriptions differ from its source), and the
  Release run attaches it beside them. The AltStore source,
  `Documents/Web/altstore.json`, is checked in with only what never changes;
  the Pages run (`Scripts/update-altstore-source.py`) fills in each recent
  release's .ipa — version, build, minimum OS and usage descriptions read
  off the bundle itself — plus the pre-2.0 fields SideStore and older
  AltStore read. Never write a version into the checked-in file.

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
Those IDs never repeat across `ighostvtd-io` processes
(`SessionIDReservation`, a block counter kept beside the daemon log): after
io dies a kept ID must name nothing, so the attach fails and the tab opens a
fresh shell. A counter restarting at 1 handed a reconnecting tab whatever the
replacement had opened under its old number — a CLI `new` included.
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

`ighostvt-cli remote …` (`status`, `on`/`off`, `pair [--wait | --end]`,
`revoke`, `name`, `relay <file> | --remove`) sends the management ops
Settings ▸ Remote Access sends (20–26), and is no new trust either: the
CLI has the rights of whoever runs it, and any admitted local peer may
already send them. The pairing code alone goes to stdout; `--wait` ends the
window if interrupted. On the Mac it must run as the agent's user — root is
refused by the uid check, so the CLI says so before trying. `relay` is Mac
only and writes the *app's* file (`RelayConfiguration.macStoreSubpath`,
`mkstemp` 0600 then `rename`) as that user before handing the helper the
same bytes, then posts `RelayConfiguration.storeChangedNotification` so a
running app drops its cache: setting the helper alone would be undone by
the app's next reconcile, which sends the app's file — or none. `on` and
`pair` reconcile the same way once the helper listens. On the device the
CLI cannot name the app's home (and may be root), so `relay` refuses there.
The CLI compiles `RelayConfiguration.swift` and `RemoteAccess.swift` from
`Shared/Remote` through an exception set that excludes every other file in
that folder — a new file there joins the CLI unless it is added to the set.
`Scripts/mac-install.sh` is the unattended Mac install built on it: root
copies the notarized bundle into `/Applications` (SHA256SUMS + `spctl`
checked), and every other step — the open-at-login LaunchAgent
(`wiki.qaq.ighostvt.open-at-login`, plain `open -g -b`), the relay file,
`remote on`, `remote pair` — runs as the user through `launchctl asuser`.
What it cannot do is grant Local Network: that is no TCC entry, no MDM
payload exists for it, and TN3179 exempts launchd *daemons* and root, never
an agent — the helper's prompt is attributed to iGhostVT.app. Until someone
allows it the helper still accepts connections and registers with a relay
on the internet, but its Bonjour advertisement is blocked, so nearby
devices do not see the host. The app itself browses only when something is
paired or Settings ▸ Remote Access is open (`askRemoteDevices` uses
`startIfPaired`): the Mac's menu bar fills the New Tab on Device element
at launch, and browsing from there raised the prompt on a first launch with
nothing to find.

A session held by another device shows the tab's "In Use on …" card, and
Use Here takes it. Coming back to the app is taken as that answer once:
every scene arms its tabs as it enters the foreground
(`TerminalSessionStore.armForegroundTakeover`), and the first time a tab
is in front afterwards a session another *device* holds is taken back on
the spot — another window of this app (no holder name) never is. The arm is
spent by that takeover, by a fresh attach, or by five seconds in front
still connected (a link that looked alive on return may have died while
suspended, and its reconnect is what meets the holder); a later loss shows
the card. No two devices can trade a session on their own: each takes it
at most once per return to the foreground, and only a person brings an app
forward.

`setSessionAttributes` (op 14) is the one thing the app keeps *in* a
session: a string→string dictionary (`attrs`) that `ighostvtd-io` stores on
the `PTYSession`, never reads, and hands back in the open reply (empty),
every attach and snapshot reply, and every `listSessions` row. The request
replaces the dictionary whole — the key is required, empty clears it — and
anything past 16 keys or 4 KiB of UTF-8 (keys and values together), or a
non-string value, is `invalidRequest` with nothing applied. Same trust as
`closeSession`: any admitted peer, attached or not, but only on a live
session (`unknownSession` otherwise). The attributes die with the session,
and with an io crash, since every session does. The proxy forwards it like
any other op and did not change. A daemon older than the op answers
`invalidRequest` and sends no `attrs` in its replies; the app takes either
as "keep it in memory" and stops sending on that transport. The CLI's `list`
shows the `lock` key as a LOCK column. The `title` key is the title the tab
shows (its reported part, at most once a second, newest wins), so a paired
device's new-tab menu names the terminal word for word as this one does,
on one line — the process under it read as noise in a list of agents that
all run the same binary. Past three terminals a device's group leads with
Open All, which attaches every one not already open here.

`uploadFile` (op 15) puts a file on the daemon's device for a shell there
to read: what a drop on a *remote* tab pastes, since no path on the app's
device means anything to that shell. Begin (`fileName`, `fileSize`, and the
client's own `upload` id, so a begin resent after a lost answer finds the
same upload) answers the `path`; parts (`upload`, `offset`, `data`, at most
`uploadChunkByteCount`) follow; `upload` alone asks how much is there, and
with `cancel` gives it up. Every reply carries `offset`. The state lives in
`ighostvtd-io` (`FileUploadStore`), keyed by upload, never by peer: a weak
link drops mid-file, the client comes back as another peer, asks, and
carries on. An upload with no part written for fifteen minutes is given up
(asking does not count), and while one is pending the idle `shutdown` is
refused. A part may overlap what is there — an old link's parts can land
after the new link asked — and only its new end is written; one that would
leave a hole or run past the size is `invalidRequest`. **Offsets are the
client's: compare, never add before checking** — an overflow trap in io
kills every shell on the device. Files land in
`<bootstrap>/var/lib/ighostvt/upload/<id>/` (root-only, unlike `/var/tmp`,
where any user can take the name first; the user's temporary directory on
the Mac); begin refuses a file that would leave under a GiB free. The file
*and its id directory* are handed to the session user, so everything under
the root is treated as theirs: reached by descriptor, `O_NOFOLLOW`, removed
one `unlinkat` at a time, a day after it was made. The client
(`DaemonFileUpload`) uses a link of its own and sends parts *in file order
from one task* — sent from the group's child tasks they left in whatever
order the tasks ran, and the host saw holes — eight unanswered at most,
halving after a timeout. A request gives up only when the link has answered
*nothing* for 30 s (a part queued behind two megabytes on a slow link is
not dead), the upload after three minutes without progress. Cancel closes
the link at once and pastes nothing; every failure after begin, cancel
included, tells the host to remove the partial file over a fresh link. The
file's size and modification time are checked before and after, so an edit
during the copy fails it. `ighostvtd-remote` forwards the op like every
other session op.

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
tabs of every connected scene (which is why the Mac app opts out of
automatic and sudden termination — `NSSupportsAutomaticTermination` and
`NSSupportsSuddenTermination` false in `Info.plist`: a quit that skipped the
callback would leave every idle shell behind, and one AppKit chose to
reclaim memory would do it without anyone asking): with Keep Alive on
every session stays in the daemon, idle shells included, and with it off
everything goes. The next launch asks nothing: its first window adopts
every session no tab holds and reopens every remote tab the last run had
(`RemoteTabLedger`, written as a window goes to the background and again
at terminate, in both editions), each taken back from whoever holds it.
A question was tried in 1.4.17 (Restore / Discard) and taken out — the
answer was always Restore. The kills travel over one
blocking one-shot connection (`XPCDaemonTransport.closeSessionsForQuit`) —
not the tabs' transports, whose `closeSession` is fire-and-forget on a queue
the exit outruns — and the call polls `listSessions` until the closed
sessions are gone, because a close reply only says the SIGHUP was sent.

Opening is the other half, beside it in Settings ▸ Sessions: New Session
at Launch (`SessionLaunch`, on by default) decides whether a window with
nothing to resume starts a shell. It applies to a window the app opens with
no other terminal window up — a launch, or the first window back after the
last closed — and never to one opened beside another (⌘N, New Window),
which was asked for. Leftovers are resumed either way, and a window that
opens with nothing shows `EmptyTabsView`. A remote-only build would turn it
off; `populate(movingSession:isOnlyWindow:)` is the one place it is read.

The app never asks the daemon to exit. **The daemon is demand-launched on
both platforms and leaves by itself**: `IOSupervisor` arms a timer whenever
no peer is connected (`idleExitDelay`, 30 s) and, when it fires, sends the
child a `shutdown` under its own reserved peer id (`supervisorPeerID`). The
child's `registry.isEmpty` guard refuses while a session is held — the
question is asked again a delay later, which is how the last shell exiting
is noticed — and grants it otherwise; the child exits 0 and the proxy
follows. A peer registering while that answer is in flight takes the exit
back (the child goes, a fresh one is spawned, the proxy stays); the client
is cut and reconnects as after any interruption. Both plists say
`RunAtLoad` + `KeepAlive = {SuccessfulExit = false}` + `MachServices`: a
crash restarts, the idle exit stands, the next lookup demand-launches, and
`make check` holds both to it. While remote access is on,
`ighostvtd-remote` keeps one connection open for as long as it runs, so the
daemon is resident exactly as long as the switch is on — the daemon itself
knows nothing about it. `shutdown` stays in the protocol for any client
that wants the same exit sooner.

**The relay** reaches a host that is not on the local network
(`Relay/PROTOCOL.md` is the wire contract; the server is Go, standard
library only, in a scratch image). Its server generates a P-256 key and keeps
only the public half; the private half goes into the `.vtrpsc` file
(`RelayConfiguration`) people import by opening it (`RelayImport`, the
`wiki.qaq.ighostvt.relay-config` document type). Opening one brings up
Settings ▸ Remote Access — the sheet, pushed to that page, on iPhone and
iPad; the settings window's Remote pane on the Mac — and the question is
asked there (`relayImportPrompt`), never over a terminal: alerts do not
stack, and one raised there took down whatever a tab was already asking as
if it had been refused. On iOS a window that is asking something waits for
the answer before Settings opens (`AlertViewController.isShowing`,
`didDisappear`). The app keeps the file (`RelayConfigurationStore`) and is
its one truth: it sends it to its own helper (`setRelayConfiguration`, op 26
— the payload holds the key, so nothing may log it) whenever the helper's
`relayFingerprint` in `remoteStatus` differs. The helper registers over a
plaintext control connection (`RelayLink`), signing with the relay key and
with a host key of its own that the relay binds the host id to on first
sight. An app connects to the relay with the same TLS it uses directly plus
an SNI of the host id (`RemoteTLS.parameters(serverName:)`, sent on the
direct path too); the relay asks the host to call back, and the helper
splices that call back into a second TLS listener on the loopback address,
so `RemoteClient` serves it like any other — counted apart from the local
network's unauthenticated slots, and taking a pairing through it only in a
window the app opened while it has a relay (it always asks for that; there
is no switch). `RemoteDaemonLink` races the paths:
direct first, the relay a moment later (1 s when Bonjour sees the host,
300 ms on a remembered address, at once when the direct one fails), first
TLS handshake wins, and the relay goes first only for five minutes after a
direct attempt *failed*, and never while Bonjour sees the host. Things
that bit:

- **A relay win is no evidence the local network is gone.** The race once
  remembered whichever path won and put it first for five minutes; a relay
  that went first won again, renewed the memory, and — with the list and
  the menus connecting every half minute — held a host on the local network
  behind the relay for good. `RemotePathMemory` now records only a direct
  attempt that failed on its own (a loser closed by the race does not
  count), a direct link clears it, and Bonjour seeing the host overrides it.
  A link already up stays on its path until it reconnects.
- **A relayed connection must never touch `lastAddress`.** The address
  that answered is the relay's; remembered as the host's it sent every later
  direct attempt there. `noteReached(viaRelay:)` records only the time.
- **Relay hosts are not Bonjour hosts.** `RemoteHostDirectory.relayHosts`
  is kept apart from `hosts`/`endpoints`, or the direct path dials the relay
  without an SNI and the relay's hosts show up as "nearby".
- **A splice ends with `forceCancel`, never `cancel`.** A graceful close
  waits for its queued bytes to leave; when the side they are queued for is
  itself stuck writing back (a host echoing a flood), neither drains and
  the host's connection stays open for good. The stress run reproduced it
  one time in six before the change, never in a dozen after.
- **TCP keepalive proves a leg, not the path.** A proxy on the way — a
  published container port is one — answers keepalive for a relay that is
  gone. So a relayed link has an end-to-end heartbeat: the app pings a quiet
  link (`ping`, op 32, answered by the helper itself) and gives it up after
  45 s without a byte; the helper drops a relayed device silent for 60 s and
  a splice idle for 75 s; the host's control connection pings every minute
  and registers again when no pong comes back in 20 s. The direct path is
  unchanged.
- **A remote link is questioned when the network changes, not left to
  TCP.** Keepalive and the drop time notice a dead link in 25 s or more,
  and the tab's back-off used to spend its minute against no network at
  all — Wi-Fi coming back found the next try up to fifteen seconds away,
  or the tab failed. `NetworkPathWatcher` (an `NWPathMonitor`, the
  interfaces' names as the signature, settled for 0.4 s) posts each
  change; every live `RemoteDaemonLink` then gives up at once if there is
  no network, and otherwise pings the host and gives up a link it has not
  heard from in `pathChangeReplyLimit` (5 s). Every host on the line
  answers the ping, direct or relayed, so this is no compatibility path.
  When the path comes back, every remote tab tries again at once with a
  fresh minute (`TabManager.reconnectRemoteTabs`, also run as the app
  comes forward in both editions), a failed one included unless its shell
  ended. Time with no network does not count against the minute, and the
  patient back-off tops out at 5 s.
- **The relay rate-limits data connections per address** (60 per 10 s,
  `RELAY_RATE_PER_IP`, 0 off): a window restoring a dozen tabs, or several
  devices behind one NAT, must stay under it. The helper sets up at most
  four call backs at once and queues up to 32 more, matching the relay's 32
  pending tickets per host.

`make relay-harness` (part of `make test` where Go is installed) spawns the
real relay and drives the helper's own `RelayLink` against it;
`RELAY_HARNESS_FLAGS=--stress` adds bulk, parallel, churn, slow-reader,
vanishing-client and relay-death runs, and `make relay-weak-network` repeats
them over `tc netem` links (lossy, awful, flapping) with the relay in a
container.

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
reports *two* spellings. `currentDirectory` is the kernel's path, the only
one `chdir` takes. `displayDirectory` is the same directory as a person
should read it: the session user's home as `~`, anything else inside the
bootstrap against `@jb` — nobody recognises
`/var/containers/Bundle/Application/<uuid>/usr/src`, and `@jb/usr/src` also
says which `/usr/src` it is — and absent for a path that is already its own
best spelling. Neither reading is the app's to make. **The home is not
`/var/mobile` under roothide**: the passwd entry says that, `resolve` finds
`<jbroot>/var/mobile`, and the shell starts there — so an app matching
`/var/mobile` renames iOS's own directory *and* misses the real home, which
is exactly what it did before `ShellLaunch.sessionHomeDirectory` existed.
`TerminalDirectory.label` therefore abbreviates nothing, and its `isHome`
is just `display == "~"`, which is what keeps the home off the menu's other
two groups.

Both spellings go through `RuntimeEnvironment.spelling(of:under:as:)`, and
it **canonicalises both sides**. `proc_pidinfo` answers `/var/mobile/…`
where `realpath` of the daemon's own executable — which is where
`Bootstrap.root` came from — gives `/private/var/mobile/…`; a plain prefix
test compares those two spellings of one directory and finds nothing, so
the marker never once appeared on a device. `Bootstrap.root` is the jbroot
under roothide and, under rootless, the *canonical* directory `/var/jb`
resolves to rather than the literal its binaries were built against, since
that may be a symlink to a randomly named one. None of this is the inverse
of `resolve`, and `~` and `@` begin no real path, so a display spelling can
never be mistaken for one.

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

**Nothing on the output path may queue main-thread work per event.** A
loop printing OSC 2 retitles tens of thousands of times a second; one
main-queue item per title (or per chunk) outran the main thread, the queue
grew to gigabytes and drained for minutes after the output stopped, with
^C and every click stuck behind it. The bounds: received bytes go into the
session on the transport's queue and the main actor hears of them through
at most one pending hop (`OutputSignal` in `TerminalSessionStore`); the
tab's retitle republish is throttled to one per 250 ms, newest wins, and
animates only when the previous one was a second ago
(`TerminalTab.animatesRetitle`). The library's own per-title publishes
and wakeups are coalesced in libghostty-spm (1.6.20261002). Under `yes`
or `base64` in three tabs the parser keeps up — the unparsed backlog never
grows — so the app does not pause XPC delivery; if it ever has to, the
hook is the session's `setOutputBacklogHandler`, and a suspension must
stay well under the proxy's 10 s congestion grace or the peer is cut.

**ZMODEM (`rz`/`sz`) is a clean-room client-side endpoint in
`iGhostVT/Backend/Zmodem/`** (no lrzsz — it is GPL). It adds no protocol op and
keeps no session state, so it is off by default (`ZmodemSetting`, Settings ▸
Advanced), built per connection, and leaves an older daemon, the CLI, or
another client untouched. `ZmodemEngine` interposes at the one
received-output choke point (`TerminalSessionStore`'s `.received` branch) on
its own serial queue: it detects the handshake iTerm2-style, passes other
output through, swallows a transfer, and replies via `transport.send` (the same
op as keystrokes). Files cross through `ZmodemFileBridge`, the only UIKit part —
temp files and the document pickers. The non-obvious bits are flagged in the
code: escape *all* control bytes or a PTY mangles a binary upload, window the
upload under the daemon's input cap, and throttle progress off the main thread
— with a trailing update, or the bar stands on a burst's first figure (it
stood on 0) until the next burst. A transfer never reaches the surface
outside an engine either: the attach replay (which skips the engine, so a
stale frame cannot start one) has every conversation cut out by
`ZmodemStreamScanner` — from `rz\r` and the first hex header to the ZFIN
exchange or a CAN run — and a link that drops mid-transfer leaves the next
engine discarding (`discardInterruptedTransfer`): it swallows the sender's
stream, cancels it once it sees ZDLE, and draws again after the sender's
own CAN run, at once if the first thing back is plain text. A relayed link
that only receives — a download — must still talk: the helper drops a
device silent for 60 s, so `DaemonLink` pings when *it* has sent nothing
for `relayedPingInterval`, not only when it has heard nothing. The pure
core is tested in `Tests/Zmodem` (`make test`), sender and receiver driven
against each other.

Every presentation of a tab — strip chip, title capsule, sidebar row, switcher
card — carries the same `TabContextMenu` (copy the page as text or image,
export it, lock, close), except a strip chip on a touch screen, where a long
press is the reorder and only that (below); the ⋯ button has it there. Close asks first only when it would interrupt
something: event 102 also says whether the foreground process group *is* the
spawned shell (`tcgetpgrp == childPID`, `foregroundIsShell`), and a connected
tab whose shell is at its prompt closes on the spot (`hasRunningProgram`). A
detached tab's last report is stale, so it still asks; an unknown state reads
as running. On the regular-width bar the trailing ⋯ button opens this same
menu for the active tab with New Tab and New Window at its head — the
strip has no + of its own.

That menu must not refresh while the terminal prints. UIKit rebuilds an
open menu whenever SwiftUI re-evaluates its content, and the tab
republishes on every retitle — so a menu that observed the tab flickered
grey and dropped taps under output. `TabContextMenu` therefore observes
only the tab's `TabAttributes`, and every view that hosts a `.contextMenu`
or the ⋯ `Menu` holds the tab as a plain reference; what changes with
output — title, subtitle, padlock, switcher picture — is a child view that
observes for itself (`TabLabels.swift`). Debug builds count those hosts'
body evaluations (`BodyTrace`, logged once a second under `tabs`); a line
during a flood of output is this regression back.

A tab moves to a window of its own by its daemon session, never by its
shell (`TabWindowMove`). The request is an `NSUserActivity`
(`wiki.qaq.ighostvt.move-tab`, declared in `NSUserActivityTypes`) naming
the session: the context menu's Move to New Window asks for a scene with
it, the drag item of a sidebar row carries it, so iPadOS turns a drop
beside the window into a new one while a drop on a slot still only
reorders, and a strip chip pulled out of the bar asks for it on release. The *new* scene does the hand-off as it connects
— the window holding the tab detaches it (`TabManager.handOff`:
`disconnect`, not `closeSession`) and drops it, and the new window attaches
to the session (`populate(movingSession:)`, which claims no resumable
sessions and opens no fresh tab) — so a drag that ends anywhere else moves
nothing. Attach is exclusive and the detach travels on the other window's
connection, so an attach answered `sessionBusy` is retried for two seconds
before the tab gives up and opens a fresh shell. The replay repaints the
output and the attach reply's attributes bring the lock. Offered only where
`supportsMultipleScenes` (never on a phone), and only for a tab that has a
session and is not its window's only tab — the menu item reads both off
`TabAttributes.sessionID` and the tab list, so it still observes nothing
output changes.

The top bar's strip picks a chip up with a long press and never with a
plain drag, which has another job on each platform: on the Mac the strip
*is* the title bar and a drag moves the window; on a touch screen it
scrolls the strip (a chip's system drag began as the finger moved, so a
swipe picked up a tab). The press lifts the chip onto an opaque capsule
of its own — bare text carried over another chip printed the two titles
over each other — and from there it reorders, or, pulled out of the bar,
its × turns into `arrow.up.right` and release opens it in a window of its
own (on the Mac placed so its chip lands under the pointer). On the Mac a
lifted chip over *another* window's bar turns into `arrow.down.left` and
joins that window (`TabWindowMove.merge`: the same detach-then-attach,
with no scene to create) — the way back from a torn-off window, whose only
tab may go and whose window then closes. Brought back into its own bar it
is only being reordered again. The Mac's press is a SwiftUI gesture
*simultaneous* with the chip's button (one that outranked the button
swallowed every click); a touch screen's is `ChipPressRecognizer`, a
UIKit recognizer on the strip's scroll view that every other recognizer
on the touch waits for — any SwiftUI gesture on a chip stopped the strip
scrolling. It decides a touch the way the Home Screen does: moved early
is a scroll, let go early a tap, held 0.3 s lifts, moved once lifted is
a carry, and let go unmoved settles it back. The chip had a context menu
there too, given the touch when the finger held still to 0.6 s, and on an
iPad it opened under a reorder that had not moved yet; it is gone, not
retimed.

A tab opened from inside the window (⌘T, a `+`, the menus) goes right
after the active tab, as a browser's does; one that arrives from outside
— a Shortcut, a URL, a moved session — is appended.

Every `+` is a `NewTabMenu`: the only decision a new terminal has is where
its shell starts, so the control opens a menu of directories instead of a
tab. The menu is UIKit's, a `UIDeferredMenuElement.uncached`
built as it opens (`NewTabMenuElements`, over the SwiftUI label): this
device's rows at once, and each paired device's open terminals in a
deferred element of their own inside its submenu, which waits for that
device's answer (at most 1.5 s; one from the last five seconds counts) and
lists what is true then — a SwiftUI `Menu` listed what its view knew at
its last render, a device's terminals from the last poll and checkmarks
for tabs closed since. The opening asks every device at once
(`RemoteSessionCatalog.refresh(hostID:)` joins an ask already out), so a
submenu's answer is usually in before the pointer gets there; the menu
once waited for all of them, and a slow relay put Loading… over the whole
menu, local rows included. Only the ⋯ menu's entry (`NewTabSubmenu`, a menu
inside a SwiftUI menu) still renders from the catalog — on iOS from rows
taken as a finger touches ⋯ (`NewTabMenuRows`) and then left alone: a
remote device's terminal titles change by the second, and every rebuild
of the open menu closed the New Tab submenu as it opened. Three inline groups, in this order — the home; the directories this
window's own tabs are in, deduplicated and sorted by path, each naming a
live session (`inheritDirectoryFrom`) so the daemon re-reads it as the tab
opens; and the recent list, sorted by the order chosen in Settings. Neither of the last two ever repeats the home (`isHome`) or a
directory the other already offers — three rows opening the same shell in
the same place is two too many. `NewTabDirectoryChoices` works all of that out once, because the
same answer decides whether there is anything to choose at all: with
nothing but the home to offer — a first launch, a window whose tabs have
not reported yet — the control stays the plain button it replaced, and ⌘T
is always `.activeTab` regardless. The ⋯ menu's New Tab is the same view
with a `Label`, so it becomes a submenu; that matters because on a phone
with tabs open the bar shows the title capsule and ⋯ is the only new-tab
control on screen. The sidebar row, the compact bar's `+`, the switcher's
dashed card and that entry are the four.

Paired devices (remote access) follow, each with New Terminal, the
terminals it has open, and the directories this app's tabs were in on that
device — the same order as this device's own rows — a submenu each, however few there are (listed inline, a device's
terminals made the menu long and read as this device's own). The Mac's File ▸ New Tab
on Device is the same list built in UIKit from an `uncached`
`UIDeferredMenuElement` — but the Mac's menu bar keeps a deferred element's
first answer regardless, so `RemoteSessionCatalog` calls
`UIMenuSystem.main.setNeedsRebuild()` whenever hosts, sessions or the
remote recents change; without it the first opening, made before Bonjour
answered, said No Paired Devices for the rest of the run. **On the Mac no
menu element is fulfilled late.** AppKit draws every UIKit menu as an
NSMenu, and a deferred element whose completion runs after that NSMenu was
rebuilt or closed crashes in UIKitMacHelper (`-[UINSMenuController
rebuildMenu:]`, a dangling `objc_retain`): 1.4.1 waited for each device's
answer inside its submenu, one device's answer rebuilt the menu bar, and a
slower one's landed on the thrown-away menu. So on Catalyst a device's
Open Terminals is the catalog's last answer, given as the menu opens — the
ask still goes out, and the rebuild brings its answer in. The catalog also
asks a device for its terminals the moment the browser finds it, not at the
next 30 s poll.

The recent list is `RecentDirectoryStore`, and it is the one thing about
sessions the app persists (`UserDefaults`): the daemon keeps no such record,
and the visit counts and the two spellings exist nowhere else. Every entry
came from event 102 — never from a shell's own OSC 7, which under roothide
is not a path anything can `chdir` to. Forty are kept, the least recently
visited evicted first whatever the sort order; eight reach the menu, minus
any directory an open tab is already offering and minus the home, which is
the first row anyway. Settings ▸ Recent Directories is the whole
of its configuration: Remember Directories hides the group, stops recording
*and* clears what is stored — a switch that says the app is not keeping this
has to mean it, and there is no separate Clear — and Sort By is Last Visited
or Most Visited. A remote
tab's directories are kept apart, per host id (`remoteEntries`, twenty per
device, five in its menu group): a path on another device names nothing
here. They open with `startDirectory` on *that* device's daemon, which
checks them like any other, and unpairing a device drops its list.

The two locks are for touch. Some programs in a terminal take taps and
drags of their own, and a tab showing one of them — or just being watched —
should not have a stray touch raise the software keyboard, move the focus,
or start a selection. That is all they guard: hardware keys, paste and
drag and drop are allowed under both, by design, and neither lock is a
way to keep input away from the program. The program itself never
notices: output keeps flowing and the surface keeps rendering. They are
one choice (`TabAttributes.lock`, at most one of `.interaction` /
`.keyboard`): picking the other lock switches, picking the one that is on
clears it, and the `isLocked` / `isKeyboardLocked` flags the menus toggle
are views of that. `TabAttributes` is the tab's one home for what the user
sets on it, observed apart from the tab (above); `TerminalTab.lock` and
its flags forward to it. Every presentation wears a `TabLockBadge` off the
same lock — the filled padlock for both kinds, the phone's title capsule
included. Which freeze is on is said once, as the lock changes: a caption
over the surface that fades after a second and a half — one left there
for as long as the tab was locked covered the terminal's first rows. A sidebar row spends the close slot on that
padlock while locked (the × is gone, not a second glyph); close stays on
the context menu.
Both locks live on
`LockableTerminalView`, the app's `TerminalView` subclass installed through
the library's `makePlatformView` seam. The interaction lock refuses
`hitTest`, which keeps every touch off the surface at once — something
SwiftUI modifiers could not — and refuses first responder so a tap cannot
take the focus. It is not an input barrier and is not meant to be one:
with keyboard navigation on (the Mac's setting, or Full Keyboard Access)
the focus system still hands the locked view keys and the menu's Paste,
and that is fine. That
factory closure reads the tab, because a view is made whenever the surface
mounts and one born after the user locked the tab would otherwise come up
unlocked.

The lock outlives the app because it is stored in the daemon's session
(op 14, key `lock` = `interaction` / `keyboard`, absent when unlocked),
never in `UserDefaults` — a relaunch, or a `kill -9` that runs no
termination code, reattaches and the attach reply hands it back.
`TerminalTab` sends each change through `TerminalSessionStore` to the tab's
transport and remembers the value the session holds (`sessionLock`); a
restore sets that first, so the lock it then assigns is equal to it and
does not echo back as another request. A change made with no link to carry
it is marked unsent, and the next attach pushes the tab's lock instead of
adopting the session's older one; a freshly opened session holds nothing and
is given the tab's.

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

On the Mac only the key window takes first responder. Every window's
scene is `foregroundActive` at once, and each window hands focus out on
events of its own — its scene turning active, a tab whose shell exited, a
reconnect, the helper's status, a program's clipboard request — so a
window behind used to take the keyboard from the one being typed in (and
Return could answer its clipboard card, whose default is Allow).
`LockableTerminalView.becomeFirstResponder` and the alert card's claim
refuse outside the key window; `TerminalWindow.becomeKey` hands the active
tab its focus back as the window comes forward. "Frontmost" on the Mac is
the key window, never `activationState` (`ShortcutBridge`).

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

## Build & verify

- After each requested change, build the roothide package and install it on
  the already-mapped physical device for the user's inspection before handing
  back. Verify the mapped device and the installed build; report any blocker.
- `make check` — project/packaging validation
- `make build` bumps `CURRENT_PROJECT_VERSION` before xcodebuild, so
  `Version.xcconfig` comes out of a build dirty by design
- `make test` — the PTY harness, the CLI's screen-renderer tests, the
  remote and ZMODEM harnesses, and the relay harness where Go is installed
  (`make harness` builds `ighostvtd-io` and
  spawns it as the proxy's child over a real socket, then drives the whole
  stack — the codec, a session's lifecycle, output routing, the flow-control
  pause and peer-cut, an io crash → respawn, the shutdown-follow, and the
  idle exit — plus
  the daemon's spawn path; launchd and the mach service are the only
  device-only parts)
- `make deb` — unsigned iphoneos build, ldid ad-hoc sign, roothide
  `iphoneos-arm64e` package; `make deb-rootless` packages the same binaries
  under `/var/jb` as `iphoneos-arm64` (`PACKAGE_FLAVOR` picks the layout).
  Before the packager runs, an iOS `make deb` puts the app bundle (widget
  included), `ighostvtd`, `ighostvtd-io` and `ighostvt-cli` through
  `Scripts/audit-ios-floor.sh` at the lowest `IPHONEOS_DEPLOYMENT_TARGET` in
  the pbxproj, and a failure is no package — CI's too. It fails on a Swift
  library newer than the floor linked non-weakly (the libswiftXPC gotcha
  below), a binary built above the floor (an appex is allowed its own), and
  a Swift runtime symbol newer than the floor imported non-weakly: its own
  list (`_swift_initBorrow`, iOS 27, which Swift 6.4 can import strongly
  from code that never names it), and,
  where an iOS simulator runtime at or above the floor keeps its Swift
  libraries as files (18.x does, 26 does not), every import that runtime
  does not export. The script is the platformize-app-ios template's, copied
  verbatim; a fix goes there first. A dependency bump that follows the
  standard library closely is proven by launching the packaged Release
  build on a device below the newest iOS, not by the audit passing
- `make mac-run` — the whole stack on a Mac: builds `ighostvtd` for macOS and
  loads it as a per-user LaunchAgent (`make mac-daemon`, undone by
  `make mac-daemon-uninstall`; log in `~/Library/Logs/ighostvtd.log`), builds
  the app as Mac Catalyst (`make mac-app`), opens it. This is the off-device
  loop: the Simulator has no daemon, so nothing connects there. Device-only
  behaviour (the GPU entitlement, the bootstrap layouts, privilege drop,
  Live Activities, the software keyboard's accessory bar) is still debugged
  on a device running custom firmware, with the installed deb. `make mac-daemon` prints
  where it left `ighostvt-cli`; run it from there
  (`…/Debug/ighostvt-cli list`) — the daemon's DEBUG admission accepts the
  CLI built beside it, and the app itself only opens sessions from
  `/Applications`, so a CLI-opened session is the quickest way to have one.
- `make release VERSION=x.y.z` — the whole cut in one command
  (`Scripts/release.sh`): clean-tree/main/tag preflight, `set-version`
  (BUILD defaults to current+1), `make check`, the `x.y.z` commit, the
  tag, the push, waiting out the GitHub Release run, checking all eleven
  assets, dispatching the APT repository build, and polling
  `https://apt.owngoal.dev/Packages` until the version is served — that
  poll is the acceptance test, because the APT run's own verify step has
  raced the CDN cache and reported failure after a successful deploy —
  then waiting for the notarized Mac zip Notarize attaches. The relay
  image is checked against the tag's commit, never HEAD: a commit pushed
  to main during the wait once made a good release fail that check.
  `INSTALL=1` ends with `make mac-update-from-github` (Touch ID).
- `make mac-zip` — the *distributable* Mac build, a separate path from
  `make mac-run` (`mac-zip-check` validates its inputs; `Scripts/package-mac.sh`
  stages, signs, zips). Universal Release, ad-hoc signed by default, a
  Developer ID signature optional via `MAC_ZIP_IDENTITY`. Nothing here
  notarizes: the release's notarized zip is the Notarize workflow's.
  It deliberately does **not** depend on `make check`: that target requires the
  bootstrap toolchain, and a Mac with only Xcode has to be able to cut this zip.

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
- **A Mac launch brings back one window.** macOS restores every window
  the last run had open (after a crash too), but tabs live only in the
  daemon and the first window claims every unattached session; the others
  came up with one fresh shell each, and a tab looked lost in whichever
  window was checked. `SceneDelegate` records the scene sessions that
  exist as the first window connects and closes any later window whose
  session is one of them — timing cannot tell them apart, since macOS
  connects a restored window after the first is already active — and the
  first ignores a restored move request: every leftover is its tab. A claim the daemon did not
  answer stays open and is retried when the Mac's helper comes up.
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
  the directory and the stale sweep are shared with pastes. On a **remote**
  tab every resolved file is then copied to the other device
  (`uploadFile`, above) and *that* path is pasted, the transfer pill showing
  progress and cancel; a folder is left out. A *paste* there goes the same
  way when the pasteboard holds a file (a screenshot, a copied file):
  `LockableTerminalView` takes `paste(_:)`, ⌘V and the touch menu's Paste
  and hands the pasteboard's providers to `TerminalDropDelegate.deliver`;
  text stays ghostty's paste. The accessory bar's Paste key calls the
  library's internal paste directly and still stages locally.
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
  behind the bar, its capsule and the sidebar's strip and footer, moves the
  window from bare chrome (`performWindowDragWithEvent:` on
  `NSApp.currentEvent`) and answers a double-click as a title bar would.
  AppKit still keeps a title bar's band over the window's top ~30pt, and
  in a movable window it moves the window from *any* drag starting there —
  a chip pressed to reorder took the window with it — so the window is
  kept not movable and `WindowDragRegion` makes it movable for its own
  drag only. That band also never hands a system drag to the content as a
  drop target, movable or not, which is why the strip reorders its chips
  with a gesture of its own (long press to lift; a plain drag moves the
  window) while the sidebar uses `onDrag`/`onDrop`. A `ScrollView` in that band draws Tahoe's scroll
  edge effect over its own content — the chips came up frosted — so the
  strip's scroller hides it (`scrollEdgeEffectHidden`).
- **A windowed iPad's red, yellow and green buttons sit over the content,
  outside the safe area.** `WindowControlsInsetReader` reads iOS 26's
  corner-adapted safe area (`.safeArea(cornerAdaptation:)`) off a view that
  spans the window: the phone layout starts *under* them (vertical), the
  sidebar layout's top row moves *past* them (horizontal, the sidebar title
  or the strip's toggle), so a maximized window, whose controls hide until
  asked for, keeps its full height. Zero on the Mac, which places its own
  traffic lights, and before iOS 26.
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
- **Root never opens a file in mobile's directories by its path.** The log
  and the session-id store live in `/var/mobile/Library/Logs`, which mobile
  owns, and a plain `open(O_CREAT)` there followed whatever mobile left at
  the name — a symlink to `sudoers` was truncated as root. Every such open
  goes through `ConfinedFile` (no untrusted symlink on the way, `O_NOFOLLOW`,
  a plain file this process owns with one link), and anything whose mere
  presence is a decision — the remote-access switch — lives in a directory
  only root can write (`<bootstrap>/var/lib/ighostvt`), never beside the log.
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
  `mkdir`, `grep`, `ls` — on cold caches, and, on custom firmware, on the
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
  `Documents/wiki.qaq.iGhostVT/Journal/Dog_*.log` in the app's home), beside the
  daemon's own `/var/mobile/Library/Logs/ighostvtd.log`, which now stamps
  each session's first output.
- **The app's data folder is `~/Documents/<bundle id>`, and the package
  makes it.** The device app has no container, so its home is mobile's —
  `<jbroot>/var/mobile` on roothide, `/var/mobile` on rootless — shared with
  every other app without one. Anything it keeps there goes in a folder named
  for its bundle id, the isolation a container would give, inside a
  `Documents` mobile owns, which a container would have had too. The postinst
  (dpkg, as root) makes each missing level — home, `Documents`, the folder —
  and hands it to mobile on its own, leaves a level that exists alone, and
  never follows a symlink. Never `mkdir -p` as root: Irisin 4.3.4–4.5.25 did,
  and on a roothide bootstrap with no `Documents` it left `Documents` root's,
  so this app could make nothing there and wrote no journal. The same block is
  in every sibling's postinst and in the platformize-app-ios template.
- **Every line the app logs goes through `AppLog`** (`Backend/Logging/`):
  Dog's journal on disk — one `Journal/Dog_<date>_<id>.log` per launch
  in the app's data folder on the device, `Documents/<bundle id>/Journal`
  (`Library/Logs/iGhostVT/Journal` should that be out of reach), and under
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
  switch decides whether *any* verbose line reaches the journal
  (`AppLog.writesVerbose`) — libghostty's `TerminalDebugLog`, which it
  turns on and off with it (under the `ghostty` tag), and the app's own
  per-chunk lines (output received, ZMODEM blocks). Off, the journal has
  info and up only; it used to keep the verbose lines anyway, and a
  download filled it with eighty thousand of them. The unified log has
  them either way.
- A GUI app ad-hoc signed with ldid MUST carry
  `com.apple.security.iokit-user-client-class` (with `IOUserClient` / the
  AGX + IOGPU + IOSurface + IOAccel leaves, see
  `Packaging/iGhostVT.entitlements`). This is a property of iOS on custom
  firmware, not a roothide one — the rootless package needs it just the same. Without it
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
