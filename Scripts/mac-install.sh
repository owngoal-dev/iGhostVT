#!/bin/bash
# Installs iGhostVT on a Mac without anyone at it, for one user, and can
# turn remote access on, give it a relay, and print a pairing code.
#
#   sudo mac-install.sh [--user NAME] [--tag vX.Y.Z | --zip PATH]
#                       [--relay FILE.vtrpsc] [--pair] [--no-open-at-login]
#
# Root is used for one thing: putting the bundle in /Applications. Every
# other step runs as the user iGhostVT is for, through the same doors the
# app and `ighostvt-cli` use — the helper is that user's own LaunchAgent and
# admits nobody else, and the relay file is that user's, so nothing here
# reaches further than the user could by themselves.
#
#   --user               whose iGhostVT this is; defaults to the user who
#                        ran sudo, else whoever is at the console
#   --tag                a release to install; defaults to the latest. Only
#                        the notarized zip is taken, checked against the
#                        release's SHA256SUMS.macos and Gatekeeper's verdict
#   --zip                a zip already on disk (a local `make mac-zip`);
#                        its signature is verified, notarization is not
#                        required
#   --relay              use this relay, as importing the file in Settings
#                        would
#   --pair               open a pairing window and print its code (valid
#                        for two minutes)
#   --no-open-at-login   do not open iGhostVT when the user logs in, and
#                        remove that if an earlier run set it up
#
# The helper itself starts at login whether or not the app opens: it is
# registered as a LaunchAgent the first time the app runs. Opening the app
# at login is what keeps windows and tabs there for whoever sits down.
#
# Remote access, the relay hand-off and the pairing code need the user's
# login session (macOS runs a LaunchAgent only inside one). Without it the
# install still happens and the rest is printed as commands to run once the
# user has logged in — or run this again then; every step is idempotent.
set -euo pipefail

repo="${GITHUB_REPOSITORY:-owngoal-dev/iGhostVT}"
dest="/Applications/iGhostVT.app"
bundle_id="wiki.qaq.iGhostVT"
label="wiki.qaq.ighostvtd"
login_label="wiki.qaq.ighostvt.open-at-login"
digest_key="MacLaunchAgent.registeredHelperDigest"

die() {
    echo "error: $*" >&2
    exit 65
}

user=""
tag=""
zip_path=""
relay_path=""
pair=0
open_at_login=1
while (($#)); do
    case "$1" in
    --user) user="${2:?--user needs a name}"; shift 2 ;;
    --tag) tag="${2:?--tag needs a tag}"; shift 2 ;;
    --zip) zip_path="${2:?--zip needs a path}"; shift 2 ;;
    --relay) relay_path="${2:?--relay needs a file}"; shift 2 ;;
    --pair) pair=1; shift ;;
    --no-open-at-login) open_at_login=0; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
    esac
done
[[ -z "$tag" || -z "$zip_path" ]] || die "--tag and --zip are exclusive"
[[ $EUID -eq 0 ]] || die "run this as root (sudo $0 …)"
[[ -z "$relay_path" || -r "$relay_path" ]] || die "cannot read $relay_path"
[[ -z "$zip_path" || -r "$zip_path" ]] || die "cannot read $zip_path"

if [[ -z "$user" ]]; then
    user="${SUDO_USER:-}"
    [[ -n "$user" && "$user" != root ]] || user="$(stat -f %Su /dev/console)"
fi
case "$user" in
root | "" | loginwindow | _*) die "name the user iGhostVT is for with --user" ;;
esac
uid="$(id -u "$user" 2>/dev/null)" || die "no user named $user"
home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
[[ -d "$home" ]] || die "$user has no home directory"

# Everything but the bundle copy runs as the user. `asuser` puts the command
# in their login session's bootstrap namespace, where the helper's mach
# service lives — `sudo -u` alone looks it up in root's and finds nothing.
as_user() { sudo -u "$user" -H "$@"; }
in_session() { launchctl asuser "$uid" sudo -u "$user" -H "$@"; }
has_session() { launchctl print "gui/$uid" >/dev/null 2>&1; }
# The CLI where it can reach the helper, and plainly as the user where it
# cannot (it still keeps a relay file without one).
cli_as_user() {
    if has_session; then in_session "$cli" "$@"; else as_user "$cli" "$@"; fi
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-install.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

# MARK: - The bundle

if [[ -n "$zip_path" ]]; then
    zip="$zip_path"
else
    if [[ -z "$tag" ]]; then
        curl -fsSL "https://api.github.com/repos/$repo/releases/latest" -o "$workdir/release.json" \
            || die "could not ask GitHub for the latest release"
        # plutil reads JSON, and is on every Mac — python3 is not, and asking
        # for it raises the Command Line Tools installer.
        tag="$(plutil -extract tag_name raw -o - "$workdir/release.json")" \
            || die "GitHub's answer named no release"
    fi
    version="${tag#v}"
    asset="iGhostVT-${version}-macos-notarized.zip"
    base="https://github.com/$repo/releases/download/$tag"
    echo "==> downloading $tag"
    curl -fsSL "$base/$asset" -o "$workdir/$asset" \
        || die "$tag has no $asset yet (Notarize attaches it after the release)"
    curl -fsSL "$base/SHA256SUMS.macos" -o "$workdir/SHA256SUMS.macos" \
        || die "$tag has no SHA256SUMS.macos"
    expected="$(awk -v name="$asset" '$2 == name || $2 == "*"name { print $1 }' "$workdir/SHA256SUMS.macos")"
    actual="$(shasum -a 256 "$workdir/$asset" | awk '{ print $1 }')"
    [[ -n "$expected" && "$expected" == "$actual" ]] || die "$asset does not match SHA256SUMS.macos"
    zip="$workdir/$asset"
fi

echo "==> checking the bundle"
mkdir "$workdir/unpacked"
ditto -x -k "$zip" "$workdir/unpacked"
app="$workdir/unpacked/iGhostVT.app"
test -x "$app/Contents/MacOS/iGhostVT" || die "the zip does not hold iGhostVT.app"
test -x "$app/Contents/MacOS/ighostvtd" || die "the helper is missing"
test -x "$app/Contents/MacOS/ighostvt-cli" || die "ighostvt-cli is missing"
codesign --verify --deep --strict "$app" || die "the bundle's signature does not verify"
if [[ -z "$zip_path" ]]; then
    # What Gatekeeper would decide at first open, decided here, since nobody
    # will be at the screen to answer its question.
    spctl --assess --type execute "$app" || die "Gatekeeper rejects the bundle"
fi
bundle_version() {
    local plist="$1/Contents/Info.plist"
    echo "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
}
new_version="$(bundle_version "$app")"
installed_version=""
[[ ! -d "$dest" ]] || installed_version="$(bundle_version "$dest" 2>/dev/null || true)"

if [[ "$installed_version" == "$new_version" ]]; then
    echo "==> $new_version is already installed"
else
    if [[ -n "$installed_version" ]]; then
        # The same sequence as mac-update-from-github.sh: the app quits,
        # and the old helper goes before its bundle does — Background Task
        # Management may have pinned the old one's signature. This ends the
        # user's terminal sessions, as any update of the helper does.
        echo "==> replacing $installed_version"
        if has_session; then
            in_session osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
            for _ in $(seq 1 20); do
                pgrep -u "$uid" -f "$dest/Contents/MacOS/iGhostVT" >/dev/null || break
                sleep 0.25
            done
        fi
        pkill -u "$uid" -f "$dest/Contents/MacOS/iGhostVT" 2>/dev/null || true
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        pkill -u "$uid" -x ighostvtd 2>/dev/null || true
        pkill -u "$uid" -x ighostvtd-io 2>/dev/null || true
        pkill -u "$uid" -x ighostvtd-remote 2>/dev/null || true
        as_user defaults delete "$bundle_id" "$digest_key" 2>/dev/null || true
    fi
    echo "==> installing $new_version at $dest"
    rm -rf "$dest"
    ditto --norsrc --noextattr --noqtn "$app" "$dest"
    chown -R root:wheel "$dest"
    lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [[ ! -x "$lsregister" ]] || as_user "$lsregister" -f "$dest" || true
fi
cli="$dest/Contents/MacOS/ighostvt-cli"

# MARK: - Open at login

login_plist="$home/Library/LaunchAgents/$login_label.plist"
if ((open_at_login)); then
    echo "==> opening iGhostVT when $user logs in"
    as_user mkdir -p "$home/Library/LaunchAgents"
    # Written by the user, into the user's own folder: root never writes
    # through a path someone else controls.
    as_user tee "$login_plist" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$login_label</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-g</string>
		<string>-b</string>
		<string>$bundle_id</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
    plutil -lint "$login_plist" >/dev/null || die "could not write $login_plist"
elif [[ -e "$login_plist" ]]; then
    echo "==> no longer opening iGhostVT at login"
    launchctl bootout "gui/$uid/$login_label" 2>/dev/null || true
    as_user rm -f "$login_plist"
fi

# MARK: - Remote access

if [[ -n "$relay_path" ]]; then
    # The file may be readable by root alone; the CLI runs as the user and
    # reads a private copy of it.
    staged="$(as_user mktemp -d /tmp/ighostvt-relay.XXXXXX)"
    cat "$relay_path" | as_user tee "$staged/relay.vtrpsc" >/dev/null
    cli_as_user remote relay "$staged/relay.vtrpsc" || { as_user rm -rf "$staged"; exit 1; }
    as_user rm -rf "$staged"
fi

if ! has_session; then
    echo "$user is not logged in, so the helper cannot run yet." >&2
    echo "After they log in, run this again, or as $user:" >&2
    echo "  $cli remote on" >&2
    ((pair)) && echo "  $cli remote pair" >&2
    exit 0
fi

echo "==> starting iGhostVT for $user"
in_session open -g -b "$bundle_id"
# The app registers the helper on its first launch, and on an update rebinds
# it — about fifteen seconds when Background Task Management needs repair.
ready=0
for _ in $(seq 1 45); do
    if cli_as_user list >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
((ready)) || die "the helper did not start; check Login Items in System Settings ▸ General"

if [[ -n "$relay_path" ]] || ((pair)); then
    echo "==> turning remote access on"
    cli_as_user remote on
fi
if ((pair)); then
    echo "==> pairing code"
    cli_as_user remote pair
fi
echo "installed $new_version for $user"
