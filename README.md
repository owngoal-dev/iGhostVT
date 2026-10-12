<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# iGhostVT

A real terminal on iPhone, iPad, and Mac, drawn by the same engine as [Ghostty](https://ghostty.org) on the desktop. Start a command, leave the app, and come back — the shell is still running.

![Preview](./Documents/screenshots.png)

## Install

On a device running custom firmware, add the OwnGoal Studio repository in your preferred package manager:

**[apt.owngoal.dev](https://apt.owngoal.dev/)**

Packages are also on [GitHub Releases](https://github.com/owngoal-dev/iGhostVT/releases). Choose the file that matches your device.

| Device | Package |
| --- | --- |
| iPhone or iPad on custom firmware, [roothide](https://github.com/roothide) | `iphoneos-arm64e` |
| iPhone or iPad on custom firmware, rootless (`/var/jb`) | `iphoneos-arm64` |
| Mac | `iGhostVT-<version>-macos.zip` |
| iPhone or iPad without custom firmware, to reach the devices above | `GhostRemote-<version>.ipa` (see [Ghost Remote](#ghost-remote)) |

Requires iOS 15 or later, or macOS 13 or later.

### Mac

Unzip the archive, drag `iGhostVT.app` into **Applications**, then open it from there. The app uses a background helper to run your sessions. If approval is requested, follow the app’s prompt to enable it in System Settings.

Releases are ad-hoc signed. If macOS refuses to open the app:

```sh
xattr -dr com.apple.quarantine /Applications/iGhostVT.app
```

### Ghost Remote

Ghost Remote is iGhostVT's remote access on its own, for an iPhone or iPad without custom firmware: it opens terminals on your devices running iGhostVT and runs none of its own. Add this source to AltStore or SideStore:

**`https://owngoal-dev.github.io/iGhostVT/altstore.json`**

or install `GhostRemote-<version>.ipa` from [GitHub Releases](https://github.com/owngoal-dev/iGhostVT/releases) with Sideloadly or your own certificate. Turn on remote access on the other device, then tap **+** in Ghost Remote and pair with the code it shows. Both need the same release line: the first two numbers of the version match.

## Features

- **Ghostty’s engine**: GPU-drawn terminal, the Ghostty theme catalog, and extra keys on the software keyboard.
- **Persistent Sessions**: Programs keep running after you quit the app, and every session reopens as a tab on the next launch. Close a tab to end its session.
- **Tabs and Windows**: Open multiple sessions, use the tab switcher, lock a tab to prevent accidental input, and open multiple windows on iPad and Mac.
- **Copy and share**: Copy Text, Copy as Image, or Export Text.
- **Shortcuts**: Run a command, open a tab, or read terminal output from the Shortcuts app. Use `ighostvt://session/<id>` to open a specific session from another app.
- **Live Activities**: View session status on the Lock Screen on supported devices with iOS 16.2 or later, and in the Dynamic Island on supported iPhone models.
- **Command line**: `ighostvt-cli` talks to the same sessions the app is showing, without taking them over.
- **Remote access**: Pair your devices with a six-digit code and open terminals on each other — on the same network, or from anywhere through a relay you run yourself (`docker compose up -d`, then import the `.vtrpsc` file it writes; see [Relay](Relay/README.md)). Both devices need the same version of iGhostVT.

## Command Line

List sessions, capture terminal output, send input, or create and close sessions. Each command runs once and disconnects. Use `ighostvt-cli list` to find a session ID, then replace `1` in the examples below. The `kill` command closes that session.

```sh
ighostvt-cli list
ighostvt-cli capture 1
ighostvt-cli capture 1 --full
ighostvt-cli send 1 text "ls -la" key Enter
ighostvt-cli send 1 key C-c
ighostvt-cli new
ighostvt-cli new -- /bin/sh -l
ighostvt-cli kill 1
```

On a Mac the tool is `/Applications/iGhostVT.app/Contents/MacOS/ighostvt-cli`.

## Build from Source

```sh
make deb              # iOS, roothide
make deb-rootless     # iOS, rootless
make mac-zip          # Mac
make test
```

Contributor notes are in [AGENTS.md](AGENTS.md). Architecture is in [Documents/ARCHITECTURE.md](Documents/ARCHITECTURE.md).

## License

iGhostVT is available under the [MIT License](LICENSE).

The iOS app requires custom firmware. They are not for the App Store. The Mac app does not require custom firmware.

Join the community on [Discord](https://discord.gg/vqhDEep2mN).
