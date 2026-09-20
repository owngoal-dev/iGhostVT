# visionOS port — experiment log and plan

*2026-08-31. Experiments run on a Mac with Xcode 27.0 beta 6 (visionOS 27.0
SDK) and Zig 0.15.2, against a scratch copy of this repo and of
libghostty-spm. The libghostty-spm half has since landed there (`dd2df3f`,
Phase 1 below), and the app side landed here the same day (Phase 2); this
repo holds this note and two simulator screenshots beside it in
`visionos/`. The target is a **jailbroken Vision Pro** — the
same product as on iOS: the app renders, the bundled `ighostvtd` owns the
shells.*

## Bottom line

**The whole product builds for visionOS** — libghostty (`xros-arm64` and
the simulator slice), the Swift wrapper, the app, **and the daemon**
(`ighostvtd`, `ighostvtd-io`, `ighostvt-cli`, which needed no source change
at all), and the existing `package-deb.sh` turns the xros products into a
roothide-style and a rootless-style `.deb` after a one-line fix. The app
installs and launches on the visionOS 27 simulator; its terminal surface
renders. **Phase 1 has since landed in libghostty-spm** (commit `dd2df3f`,
2026-08-31): the Ghostty and Zig std patches, the wrapper guards, the
xros/xrsimulator slices in every build script and CI matrix, and the
`upstream.1.3.1-2` storage tag, and package release **1.5.0** is out. **Phase
2 landed too**: `make deb PLATFORM=xros` builds the app and the daemon
against the xros SDK and packages `wiki.qaq.ighostvt_<ver>_xros-arm64e.deb`,
release.yml has a `package-xros` job, and the floor is visionOS 1.0. What is left here is small and specific: the app patch below,
the jailbreak's own layout and dpkg vocabulary (open questions, listed),
and a device to run it on.

Theos is not involved: the repo builds with `xcodebuild`, signs with `ldid`,
packages with `dpkg-deb`, and that pipeline already works for xros.

## What was tried, in order

### 1. The Zig toolchain on this Mac (not visionOS-specific)

The pinned Ghostty (1.3.1) needs Zig 0.15.2; Homebrew has 0.16, which no
longer compiles Ghostty's `build.zig` (`std.process.EnvMap` is gone). With
0.15.2 downloaded, `zig build` could not even link its own build runner:
`undefined symbol: __availability_version_check`, `_abort`, … Root cause:
the macOS 27 (and 26.5) SDK's `libSystem.tbd` lists targets
`[x86_64-macos, arm64e-macos, …]` — **no plain `arm64-macos`** — and Zig
0.15.2's tapi reader matches the triple literally, so a *native* build
(which passes `-syslibroot <SDK>`) links an empty libSystem. An explicit
`-target aarch64-macos.27.0` works because it skips the syslibroot.

Workaround used here (now libghostty-spm's
`Script/support/xcode27-sdk-overlay.sh`): an `xcrun` shim on
`PATH` that answers `--sdk macosx --show-sdk-path` with an overlay SDK — a
directory of symlinks into the real SDK plus a copied `usr/lib` whose
`.tbd` `targets:` lines also name `arm64-macos`/`arm64-maccatalyst`. Zig
finds the SDK through `xcrun` on `PATH`, so nothing else changes. CI on
`macos-26` runners with Xcode 26 is presumably unaffected (the released
1.4.12 binaries were built there); verify before relying on it.

Two more Xcode-27 regressions surfaced later and were confirmed to hit an
**iOS** build through the same toolchain, so they are environment, not
visionOS:

- The `libghostty-vt.dylib` install step's libc++ sub-compilation fails
  (`clamp_to_integral.h: use of undeclared identifier 'INFINITY'`). The
  dylib is not part of the XCFramework; the patch skips installing it.
- Xcode 27's `libtool` (cctools 27037) silently drops every archive member
  Zig's archiver wrote 2-byte-aligned ("64-bit mach-o not 8-byte
  aligned"), which empties oniguruma, libintl, freetype, zlib and the simd
  objects out of `libghostty-fat.a`; the app then fails to link with
  `_OnigEncodingASCII`, `_libintl_textdomain`, `_ghostty_simd_*`,
  `_zig_os_log_with_type` undefined. Fix: `LibtoolStep` merges with
  `zig ar qcsL --format=darwin` instead — accepted by both `libtool` and
  `ld`, and worth landing regardless of visionOS.

### 2. libghostty for `aarch64-visionos`

`Script/build-platform.sh` already has a `visionos` group
(`aarch64-visionos`, `aarch64-visionos-simulator@apple_a17`,
`x86_64-visionos-simulator`), and `build.sh` notes "upstream Ghostty crashes
for visionos". The crash is one line: `SharedDeps.zig:383` unwraps a
`MetallibStep` that returns `null` for any OS tag but macOS/iOS.

libghostty-spm's `Patches/ghostty/0012-visionos.sh` (the `LibtoolStep` and
`libghostty-vt.dylib` changes became `0013-host-toolchain.sh`, since they
fix iOS on Xcode 27 too) fixes everything Ghostty-side:

1. `MetallibStep.zig` — `xros`/`xrsimulator` SDK names and the version
   flag: the Metal compiler has no `-mxros-version-min`; it takes
   `-mtargetos=xros1.0` and `-mtargetos=xros1.0-simulator` (both verified
   with `xcrun -sdk xros metal`).
2. `Config.zig` — `osVersionMin(.visionos)` = 1.0; sentry/i18n defaults.
3. Runtime switches keyed on `.ios` get `.visionos` beside it: `Metal.zig`
   (storage modes, layer attach, device choice, the two spm iOS patches'
   `builtin.os.tag == .ios` checks), `IOSurfaceLayer.zig`, `coretext.zig`,
   `pty.zig` (`NullPty` — the host-managed backend, as on iOS),
   `os/desktop.zig`, `os/homedir.zig`, `os/open.zig`, `config/theme.zig`,
   `input/keycodes.zig`, `cli/tui.zig`, `Command.zig`,
   `pkg/apple-sdk/build.zig`.
4. `build.zig` — skip the vt dylib on visionOS.
5. `LibtoolStep.zig` — llvm-ar merge (see above).

The embedded runtime's platform tag stays `ios`: the host passes
`GHOSTTY_PLATFORM_IOS` with a `UIView`, which is exactly what visionOS is.

Result: `libghostty.a` for `xros-arm64` — `LC_BUILD_VERSION platform 11
minos 1.0`, 172 archive members (the same count as the iOS slice), with
`ghostty_*`, oniguruma, libintl, simd and os_log symbols all present. The
`xros-arm64-simulator` slice (apple_a17) builds with the same script.

### 3. Zig 0.15.2's std has visionOS gaps

`std.c` covers visionos, but five files do not, each an OS switch with an
`else => @compileError`: `fs.zig` (`max_path_bytes`, `NAME_MAX`),
`fs/Dir.zig` (three arms of the Darwin directory iterator),
`process/Child.zig`, `debug/Dwarf/abi.zig` (`mcontext_t` register map),
`debug/SelfInfo.zig`. libghostty-spm's
`Patches/zig/0.15.2-visionos-std.patch` adds `.tvos, .watchos, .visionos`
beside `.ios`; `Script/prepare-zig-lib.sh` applies it to a *copy* of the
toolchain's `lib/` under the build cache and `build-ghostty.sh` exports that
copy as `ZIG_LIB_DIR` for `*visionos*` targets only, so the Zig on PATH is
never edited and no other target changes. Moving to a Ghostty ref that builds with Zig 0.16 would
retire this patch and the SDK shim at once — but every spm patch
(`0001`–`0011`) is pinned to 1.3.1, so that is its own project.

### 4. The Swift wrapper (`GhosttyTerminal`)

Type-checked against the xros SDK by emitting `.swiftmodule`s by hand
(the C headers are platform-neutral, so this needed no binary). Six sites
in five files (landed in libghostty-spm `dd2df3f`; the fallback scale is a
named `UITerminalView.fallbackDisplayScale` there):

| file | site | visionOS |
|---|---|---|
| `UITerminalView.swift:138` | `UIScreen.main.nativeScale` | `UIScreen` unavailable |
| `UITerminalView+Lifecycle.swift:130,136` | `window?.screen`, `UIScreen.main` | same; `traitCollection.displayScale` is the answer |
| `UITerminalView+InputAccessory.swift:12` | `override inputAccessoryView` | property is unavailable — cannot be overridden |
| `UITerminalView+Interaction.swift:662` | `UIImpactFeedbackGenerator` | unavailable |
| `TerminalInputAccessoryView.swift:287` | `UIGlassEffect` | unavailable |

`Package.swift` needs `.visionOS(.v1)` (the template too), `test.sh` two
more destinations, `verify-xcframework.sh` the `xros` identifiers, and
the CI matrix the `visionos` group. `MSDisplayLink`, `GhosttyKit`,
`GhosttyTheme` compile untouched.

### 5. The app

landed as the tree's `#if os(visionOS)` guards (see the visionOS section of
AGENTS.md), seven files:

- `project.pbxproj` — app target: `SUPPORTED_PLATFORMS = "iphoneos
  iphonesimulator macosx xros xrsimulator"`, `TARGETED_DEVICE_FAMILY =
  "1,2,7"`, `XROS_DEPLOYMENT_TARGET = 26.0`; daemon/io/cli targets:
  `SUPPORTED_PLATFORMS = "iphoneos macosx xros xrsimulator"`. (26 rather
  than 1.0: with the 27 SDK, SwiftUI's `TupleContent` `View` conformance
  is `@available(visionOS 26)`, and every `#available(iOS 26, *)` in the
  app otherwise needs `visionOS 26` spelled out. Drop it to 2.0 only if
  the jailbreak targets an older visionOS — then those `#available`s need
  the extra clause.) The widget's embed and target dependency already
  carry `platformFilter = ios`, so it is skipped on xros for free.
- `LockableTerminalView.swift` — the keyboard-lock override of
  `inputAccessoryView` and the `inputAssistantItem` groups: neither exists
  on visionOS. The lock still holds through `inputView` and
  `canBecomeFirstResponder`.
- `SessionActivityController.swift`, `TerminalSessionAttributes.swift` —
  `ActivityKit` is not in the xros SDK; `#if canImport(ActivityKit)`.
- `GlassStyle.swift`, `AlertCardView.swift` — `glassEffect` /
  `GlassEffectContainer` are unavailable on visionOS (its windows are
  glass already); the material fallback is the whole treatment there.
- `KeyboardState.swift` — `UIScreen.main.bounds` in the "is this a
  software keyboard" test; the visionOS keyboard is its own window, so
  the frame says nothing and the answer is `true`.

Everything else — `TabManager`, the XPC transport, Shortcuts, the CLI
protocol, `ScreenRenderer`, the drop delegate, the menus — compiles as
is. `xcodebuild -scheme iGhostVT -destination generic/platform=visionOS`:
**BUILD SUCCEEDED**, `iGhostVT.app` 18 MB, `platform 11 minos 26.0`, all
localizations and the AppIntents metadata present.

### 6. The daemon

`xcodebuild -scheme ighostvtd -destination generic/platform=visionOS`
with only the `SUPPORTED_PLATFORMS` change: `ighostvtd` (255 KB),
`ighostvtd-io` (345 KB) and `ighostvt-cli` (191 KB), all
`LC_BUILD_VERSION platform 11`, **no source edits**. Everything the daemon
leans on — `forkpty`/`execve`, `proc_pidinfo`/`PROC_PIDVNODEPATHINFO`,
`tcgetpgrp`, kqueue, the XPC mach-service listener, `posix_spawn` of the
io child, `JailbreakRoot`'s executable-path detection — is the same
XNU/libSystem surface the iOS SDK exposes. The PTY harness (`make test`)
exercises all of it on macOS already; the device-only parts are, as on
iOS, launchd and the mach service.

### 7. Packaging

`Scripts/package-deb.sh` run by hand on the xros Release products produced
both flavours — `iphoneos-arm64e` unprefixed and `iphoneos-arm64` under
`/var/jb` — ~5 MB each, `ldid`-signed with the existing entitlement files,
and the script's own entitlement verification passed. One fix was needed
(landed in `Scripts/package-deb.sh`): the appex loop assumed
`PlugIns/*.appex` is non-empty, and the xros bundle has no widget.

What the script cannot know is the visionOS jailbreak's vocabulary:

- **Bootstrap layout.** `JailbreakRoot` recognises roothide (jbroot
  detected from its own path, `/rootfs` for the untouched filesystem) and
  rootless (`/var/jb`). If the Vision Pro bootstrap is either of those
  shapes, `PACKAGE_FLAVOR` covers it; if it is a third layout, it is a new
  `Layout` case and a new prefix in `package-deb.sh` — the type exists so
  that nothing else has to change.
- **dpkg `Architecture`.** `iphoneos-arm64e` / `iphoneos-arm64` are the
  Procursus labels; whatever `dpkg --print-architecture` says on the Vision
  Pro bootstrap goes into `PACKAGE_ARCHITECTURE`.
- **`Depends: firmware (>= 15.0)`.** visionOS reports 1.x/2.x/26 — a
  `firmware` version below 15 *refuses to install*. The control template
  needs a per-flavour `Depends` (a `@DEPENDS@` placeholder), and
  `uikittools` needs to exist on that bootstrap (`uicache` runs in
  `postinst`).
- **Entitlements.** `com.apple.security.iokit-user-client-class` lists the
  AGX/IOAccel/IOSurface classes iOS needs for Metal; a Vision Pro (M2)
  should match the M-series names, but the symptom of a miss is the same
  silent black terminal as on iOS — `deny(1) iokit-open-user-client` in
  the kernel log says which class to add. `no-sandbox`, the mach-lookup
  exception and the client entitlement carry over unchanged.
- **The app's peer path.** `PeerAuthenticator` admits
  `/Applications/iGhostVT.app/iGhostVT` and the CLI beside it; the same
  rule applies as long as the bootstrap installs `/Applications` the same
  way (the deb's `/usr/bin/ighostvt-cli` symlink must stay relative).

### 8. The simulator

The scratch tree built for `generic/platform=visionOS Simulator` (with the
`xros-arm64-simulator` slice) installs and launches on the visionOS 27.0
"Apple Vision Pro" simulator (`visionos/simulator-first-launch.jpg`): the
sidebar, the tab strip with its ⋯ menu, and the libghostty **Metal surface
rendering** — the reconnect lines are drawn by the terminal itself — under
the "terminal unavailable" card, because the simulator has no daemon (no
launchd job, same as the iOS Simulator). Layout, fonts, theme, and the
alert card all carried over without visionOS-specific work.

Two observations for the UI pass: the window opens at the system's default
size (no `sizeRestrictions` yet), and the top bar still reads as the
iPad's — visionOS's own bar/ornament conventions are untouched.

## Plan

### Phase 0 — answers only the jailbreak can give (you)
- Bootstrap layout on the Vision Pro (roothide-shaped, rootless-shaped,
  or a third).
- `dpkg --print-architecture` and the `firmware` version its dpkg
  reports.
- Zig strategy: keep 0.15.2 + the std patch and the archive fix, or
  budget for moving Ghostty to a 0.16-buildable ref (re-basing eleven
  spm patches).

### Phase 1 — libghostty-spm ships an xros slice — **done** (`dd2df3f`)
Landed on 2026-08-31, verified locally with a pristine Zig 0.15.2 through
the CI code path (fresh checkout of the pinned ref, full patch stack;
aarch64-visionos, both simulator archs, aarch64-ios, both macOS archs; the
six-slice XCFramework through `verify-xcframework`, `test.sh` on eleven
destinations, `swift test` on macOS, the consumer test on all six).
Both workflows have since run: **Build Upstream XCFramework** published
`upstream.1.3.1-2` (`Ghostty.build` = 2; the old `upstream.1.3.1` asset
stays, every 1.4.x tag pins its checksum — all ten targets and the
six-destination consumer test passed on the runners), and **Release
Package** cut **1.5.0** (test.sh on eleven destinations, `swift test`
165/165, `verify-release` against the new asset). This repo now pins
`upToNextMajor` from 1.5.0.

### Phase 2 — the tree builds and packages for xros — **done**
Landed 2026-08-31 in this repo:
- The six `#if os(visionOS)` guards and the `ActivityKit` `canImport`s;
  `SUPPORTED_PLATFORMS` gains `xros xrsimulator` on the app and the three
  daemon targets, `TARGETED_DEVICE_FAMILY` gains `7`;
  `XROS_DEPLOYMENT_TARGET = 1.0` in `Configuration/Base.xcconfig`. The
  experiment needed 26.0 because of one `TupleContent` in
  `TabContextMenu.lockControls`; splitting it into one builder per control
  takes the floor to the SDK's minimum, and the iOS and Catalyst builds are
  unchanged by it.
- `Makefile`: a `PLATFORM` axis (`ios` default, `xros`) picking the
  destination, the `Build/Products/<config>-xros` directory, the
  architecture label's OS half and the control file's `Depends`
  (`firmware (>= 1.0), uikittools` for xros — the iOS `>= 15.0` would refuse
  a visionOS 1.x/2.x bootstrap). `deb-xros` / `deb-xros-rootless` are the
  shorthands; `PACKAGE_FLAVOR` stays the layout axis.
- `Scripts/package-deb.sh`: a `<depends>` argument and the empty-appex fix;
  `Packaging/DEBIAN/control` says iOS and visionOS and takes `@DEPENDS@`.
- `.github/workflows/release.yml`: `package-xros` (macos-26, `make deb-xros`),
  a `xros` choice for a single-platform dispatch, and a merge that expects
  three debs.
- No visionOS app icon yet (the catalog has none for iOS either; the build
  only warns).

Verified: `make deb PLATFORM=xros` end to end (check, harness, app + daemon
for `generic/platform=visionOS`, ldid, entitlement checks, dpkg-deb) →
`wiki.qaq.ighostvt_0.5.4_xros-arm64e.deb` whose app and `ighostvtd` are
`platform VISIONOS minos 1.0`; the same tree still builds for
`generic/platform=iOS` and Mac Catalyst; the Debug xrsimulator build
installs and launches on the visionOS 27.0 simulator
(`visionos/simulator-tree-build.jpg`) — sidebar, tab bar, terminal surface
rendering, "Connecting…" because the simulator has no daemon.

Still the jailbreak's to answer (Phase 0): the dpkg architecture label
(`PACKAGE_ARCHITECTURE=` overrides `xros-arm64e`), whether `uikittools`
exists on that bootstrap, and the GPU user-client classes.

### Phase 3 — first install on the device (≈1–2 days, device in hand)
1. Install the deb; `launchctl print system/wiki.qaq.ighostvtd` shows the
   job; `ighostvt-cli list` from `/usr/bin` answers (that proves admission
   by executable path on this bootstrap).
2. Open the app; if the terminal is black, read the kernel log for
   `deny(1) iokit-open-user-client` and extend the IOKit class list.
3. `ighostvt-cli new` + `capture` before touching the view stack if the
   first shell sits blank — the ~30 s first-shell warm-up after a
   userspace reboot applies here too.
4. Shell integration: the deb ships libghostty's scripts to
   `/usr/share/ighostvt/shell-integration`; verify the bootstrap's zsh
   picks them up (OSC 7 / 133 in a tab title).
5. Keep Alive / quit semantics: the device LaunchDaemon path
   (`KeepAlive = true`, never asked to shut down) is what applies.

### Phase 4 — visionOS UI pass (≈3–5 days)
- No keyboard accessory bar on visionOS: the sticky Esc/Tab/Ctrl/arrow
  keys move to a window ornament (`.ornament`) or the toolbar;
  `KeyboardBarStore` already compiles, only its host differs. With a
  hardware keyboard paired most of this is moot; check `KeyboardState`'s
  visibility rule with the separate keyboard window.
- Hover: `.hoverEffect()` on tab chips and buttons; the bar's material
  should read as visionOS glass, not the iOS one.
- Window sizing: `UIWindowScene.sizeRestrictions` for a sensible default
  grid; multiple windows already work (one `TabManager` per scene).
- Pointer/gaze: long-press selection menu, the drop delegate (the Files
  path applies as is), pinch-to-zoom.
- Live Activities do not exist on visionOS; the sidebar/tab chips are the
  only session status. Nothing to build, just nothing to promise.

### Later, unrelated to the jailbreak
- An SSH transport on the `TerminalTransport` seam would give the
  visionOS *and* iOS simulators a shell and open a sandboxed,
  store-shaped build; it is not on this port's critical path.

## Verification done here

- `libghostty.a` (xros-arm64, xros-arm64-simulator) as above.
- XCFramework with six slices via `xcodebuild -create-xcframework`.
- `xcodebuild -scheme iGhostVT` and `-scheme ighostvtd`, both
  `generic/platform=visionOS`: BUILD SUCCEEDED (Debug and Release).
- `package-deb.sh` → `wiki.qaq.ighostvt_0.5.3_iphoneos-arm64e.deb`
  (unprefixed) and `_iphoneos-arm64.deb` (`/var/jb`), from xros products.
- Install + launch on the visionOS 27.0 simulator.
- Not done: anything on a Vision Pro. Phase 3 is that.
