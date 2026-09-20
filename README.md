<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# iGhostVT

A real terminal on iPhone, iPad, Apple Vision Pro, and Mac, drawn by the same engine as [Ghostty](https://ghostty.org) on the desktop. Start a command, leave the app, and come back — the shell is still running.

![Preview](./Documents/screenshots.png)

## Install

On a jailbroken device, add the OwnGoal Studio repository in your preferred package manager:

**[apt.owngoal.dev](https://apt.owngoal.dev/)**

Packages are also on [GitHub Releases](https://github.com/owngoal-dev/iGhostVT/releases). Choose the file that matches your device.

| Device | Package |
| --- | --- |
| Jailbroken iPhone or iPad, [roothide](https://github.com/roothide) | `iphoneos-arm64e` |
| Jailbroken iPhone or iPad, rootless (`/var/jb`) | `iphoneos-arm64` |
| Jailbroken Apple Vision Pro | `xros-arm64e` or `xros-arm64` |
| Mac | `iGhostVT-<version>-macos.zip` |

Requires iOS 15 or later, visionOS 1 or later, or macOS 13 or later.

### Mac

Unzip the archive, drag `iGhostVT.app` into **Applications**, then open it from there. The app uses a background helper to run your sessions. If approval is requested, follow the app’s prompt to enable it in System Settings.

Releases are ad-hoc signed. If macOS refuses to open the app:

```sh
xattr -dr com.apple.quarantine /Applications/iGhostVT.app
```

## Features

- **Ghostty’s engine**: GPU-drawn terminal, the Ghostty theme catalog, and extra keys on the software keyboard.
- **Persistent Sessions**: With **Keep Sessions Running** enabled, programs continue after you quit the app, and their sessions reopen on the next launch. Idle shells close when the app quits. Manage this setting in **Settings → Advanced → Sessions**.
- **Tabs and Windows**: Open multiple sessions, use the tab switcher, lock a tab to prevent accidental input, and open multiple windows on iPad and Mac.
- **Copy and share**: Copy Text, Copy as Image, or Export Text.
- **Shortcuts**: Run a command, open a tab, or read terminal output from the Shortcuts app. Use `ighostvt://session/<id>` to open a specific session from another app.
- **Live Activities**: View session status on the Lock Screen on supported devices with iOS 16.2 or later, and in the Dynamic Island on supported iPhone models.
- **Command line**: `ighostvt-cli` talks to the same sessions the app is showing, without taking them over.

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
make deb-xros         # visionOS, roothide
make mac-zip          # Mac
make test
```

Contributor notes are in [AGENTS.md](AGENTS.md). Architecture is in [Documents/ARCHITECTURE.md](Documents/ARCHITECTURE.md).

## License

iGhostVT is available under the [MIT License](LICENSE).

The iOS and visionOS apps require a jailbreak. They are not for the App Store. The Mac app does not require a jailbreak.

Join the community on [Discord](https://discord.gg/vqhDEep2mN).
