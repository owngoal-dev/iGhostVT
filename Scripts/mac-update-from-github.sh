#!/bin/bash
# Replaces /Applications/iGhostVT.app with the macOS zip from a GitHub Release.
#
#   mac-update-from-github.sh [tag]
#
# Tag defaults to the latest release. The zip CI attaches is ad-hoc, so
# Gatekeeper quarantine has to come off; a live helper pins Background Task
# Management to the old cdhash, so the running app has to quit and the old
# agent has to go *before* the bundle is swapped. When the keychain holds a
# Developer ID Application identity the downloaded bundle is re-signed with
# it first: BTM keys a Team-ID signature's launch constraint on the team,
# not the cdhash, so the *next* update signed by the same team replaces the
# helper without tripping the constraint at all. MAC_UPDATE_IDENTITY
# overrides the choice; MAC_UPDATE_IDENTITY=- keeps the ad-hoc seal. The harness LaunchAgent
# (`make mac-run`) shares the label `wiki.qaq.ighostvtd` — leaving it loaded
# is the usual kSMErrorInvalidSignature after an install.
#
# Privileged steps (delete + copy into /Applications) go through sudo, which
# on this machine is Touch ID. Unprivileged: download, xattr, quit, bootout.
set -euo pipefail

repo="${GITHUB_REPOSITORY:-owngoal-dev/iGhostVT}"
dest="/Applications/iGhostVT.app"
installed_binary="$dest/Contents/MacOS/iGhostVT"
label="wiki.qaq.ighostvtd"
bundle_id="wiki.qaq.iGhostVT"
digest_key="MacLaunchAgent.registeredHelperDigest"
domain="gui/$(id -u)"
harness_plist="$HOME/Library/LaunchAgents/$label.plist"

die() {
    echo "error: $*" >&2
    exit 65
}

command -v gh >/dev/null || die "gh is required"
command -v ditto >/dev/null || die "ditto is required"
command -v sudo >/dev/null || die "sudo is required"

tag="${1:-}"
if [[ -z "$tag" ]]; then
    tag="$(gh release view -R "$repo" --json tagName --jq .tagName)"
    [[ -n "$tag" ]] || die "could not resolve the latest GitHub release of $repo"
fi
version="${tag#v}"
asset="iGhostVT-${version}-macos.zip"

echo "==> authenticating as root (Touch ID)"
sudo -v || die "sudo authentication failed"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-update.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

echo "==> downloading $repo $tag ($asset)"
gh release download "$tag" -R "$repo" -p "$asset" -D "$workdir"
zip="$workdir/$asset"
test -f "$zip" || die "release $tag has no $asset"

# Quarantine on the zip would land on the extracted tree. provenance/macl
# cannot be stripped (SIP); the copy into /Applications below drops xattrs.
echo "==> clearing xattrs on the zip"
xattr -cr "$zip"

echo "==> extracting"
ditto -x -k "$zip" "$workdir"
app="$workdir/iGhostVT.app"
test -d "$app" || die "the zip did not contain iGhostVT.app"
test -x "$app/Contents/MacOS/iGhostVT" || die "the app binary is missing"
test -x "$app/Contents/MacOS/ighostvtd" || die "the helper is missing"
test -f "$app/Contents/Library/LaunchAgents/$label.plist" \
    || die "the bundled agent plist is missing"
xattr -cr "$app"

# CI signs ad-hoc, and an ad-hoc helper's launch constraint is that build's
# cdhash — every update then leans on the digest repair. A Developer ID
# signature is keyed on its Team ID instead, which survives updates. The
# metadata is preserved on purpose: the CLI's identifier is a contract with
# PeerAuthenticator, and the empty entitlement sets are deliberate.
identity="${MAC_UPDATE_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)"
    if [[ -n "$identities" ]]; then
        # Prefer the team the installed app already carries, so the
        # constraint BTM recorded keeps matching across this very update.
        installed_team="$(codesign -dv "$dest" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)"
        if [[ -n "$installed_team" && "$installed_team" != "not set" ]]; then
            identity="$(grep -F "($installed_team)" <<<"$identities" | head -n 1 || true)"
        fi
        [[ -n "$identity" ]] || identity="$(head -n 1 <<<"$identities")"
    fi
fi
if [[ -n "$identity" && "$identity" != "-" ]]; then
    echo "==> re-signing as $identity"
    resign() {
        codesign --force --sign "$identity" --options runtime --timestamp \
            --preserve-metadata=entitlements,identifier,flags "$1"
    }
    # Inside out, the order package-mac.sh seals them.
    while IFS= read -r -d '' nested; do
        resign "$nested"
    done < <(find "$app/Contents" \
        \( -name '*.framework' -o -name '*.appex' -o -name '*.bundle' -o -name '*.dylib' \) \
        -print0 2>/dev/null)
    resign "$app/Contents/MacOS/ighostvtd-io"
    [[ ! -e "$app/Contents/MacOS/ighostvtd-remote" ]] || resign "$app/Contents/MacOS/ighostvtd-remote"
    resign "$app/Contents/MacOS/ighostvtd"
    resign "$app/Contents/MacOS/ighostvt-cli"
    [[ ! -e "$app/Contents/MacOS/ighostvt-mcp" ]] || resign "$app/Contents/MacOS/ighostvt-mcp"
    resign "$app"
    codesign --verify --deep --strict "$app"
else
    echo "==> no Developer ID Application identity; keeping the ad-hoc signature"
fi

echo "==> quitting the installed app"
# Path-scoped: a plain killall iGhostVT would also take down the Simulator.
osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -f "$installed_binary" >/dev/null || break
    sleep 0.25
done
if pgrep -f "$installed_binary" >/dev/null; then
    echo "    force-quitting (a dialog was probably up)"
    pkill -f "$installed_binary" || true
    sleep 0.5
fi

echo "==> unloading $label"
launchctl bootout "$domain/$label" 2>/dev/null || true
rm -f "$harness_plist"
pkill -x ighostvtd 2>/dev/null || true
pkill -x ighostvtd-io 2>/dev/null || true
pkill -x ighostvtd-remote 2>/dev/null || true
pkill -x ighostvt-mcp 2>/dev/null || true
defaults delete "$bundle_id" "$digest_key" 2>/dev/null || true

echo "==> replacing $dest"
# One sudo so Touch ID fires once more at most. ditto without xattrs is
# what actually drops SIP-protected provenance the unzip could not.
sudo /bin/bash -c '
    set -euo pipefail
    dest="$1"
    src="$2"
    owner="$3"
    rm -rf "$dest"
    ditto --norsrc --noextattr --noqtn "$src" "$dest"
    xattr -cr "$dest"
    chown -R "$owner:staff" "$dest"
' bash "$dest" "$app" "$(id -un)"

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$dest"
fi

echo "==> launching"
open "$dest"

# The app rebinds the registration itself (MacLaunchAgent.rebind): with the
# digest gone it unregisters and registers, asks the helper, and when
# Background Task Management re-enabled its stale item instead — the
# helper then dies to a launch constraint — waits out launchd's repair of
# that item and goes again. Two rounds take about fifteen seconds; do not
# bootout or relaunch in that window, it cancels the repair.
echo "==> waiting for the helper"
for _ in $(seq 1 20); do
    pgrep -x ighostvtd >/dev/null && break
    sleep 2
done
if pgrep -x ighostvtd >/dev/null; then
    echo "    helper is running"
else
    echo "    helper still not running; approve it in Login Items, then relaunch the app" >&2
fi

echo "installed $tag at $dest"
echo "allow the helper in Login Items if macOS asks; the app registers it on launch"
