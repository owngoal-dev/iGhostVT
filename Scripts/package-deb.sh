#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ "$#" -ne 16 ]]; then
    echo "usage: $0 <app> <daemon> <daemon-io> <cli> <control> <app-entitlements> <daemon-entitlements> <cli-entitlements> <appex-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <install-prefix> <depends>" >&2
    exit 64
fi

app_bundle="$1"
daemon_binary="$2"
# The daemon's child, installed beside it: ighostvtd is the launchd job and
# lives under launchd's jetsam limit, so the PTYs and their buffers live in
# ighostvtd-io, which it spawns.
daemon_io_binary="$3"
# The command-line client. It ships *inside* the app bundle, beside the app
# binary, because the daemon admits a peer by its executable path and one
# rule then covers both clients; /usr/bin gets a symlink to it.
cli_binary="$4"
control_template="$5"
app_entitlements="$6"
daemon_entitlements="$7"
cli_entitlements="$8"
appex_entitlements="$9"
launch_plist="${10}"
output_deb="${11}"
package_id="${12}"
version="${13}"
architecture="${14}"
# Empty for roothide, which installs into the jbroot it picked this boot, and
# "/var/jb" for a rootless bootstrap, which has to be named in every path the
# package ships — including the ones inside the launch daemon and the
# maintainer scripts.
install_prefix="${15}"
# The control file's Depends line. The firmware floor differs per platform —
# iOS 15 for iphoneos-*, visionOS 1 for xros-* — and the Makefile knows which
# it built.
depends="${16}"

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
[[ -x "$daemon_io_binary" ]] || { echo "error: daemon io binary is missing" >&2; exit 66; }
[[ -x "$cli_binary" ]] || { echo "error: cli binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" \
    "$cli_entitlements" "$appex_entitlements" "$launch_plist"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
[[ "$install_prefix" =~ ^(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || { echo "error: invalid install prefix" >&2; exit 64; }
case "$architecture:$install_prefix" in
iphoneos-arm64:/var/jb | iphoneos-arm64e: | xros-arm64:/var/jb | xros-arm64e:) ;;
*) echo "error: architecture and install prefix name different bootstrap layouts" >&2; exit 64 ;;
esac

depends_pattern='^[A-Za-z0-9][-A-Za-z0-9+.,()~<>= _]*$'
[[ "$depends" =~ $depends_pattern ]] || { echo "error: invalid Depends: $depends" >&2; exit 64; }

for native_binary in "$daemon_binary" "$daemon_io_binary" "$cli_binary"; do
    native_dependencies="$(otool -L "$native_binary")"
    if grep -q 'libvroot' <<<"$native_dependencies"; then
        echo "error: native daemon/client already resolves physical paths; unexpected vroot dependency" >&2
        exit 65
    fi
done

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.iGhostVT && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with — refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}

# Settings ▸ About ▸ Licenses reads this; the Collect Licenses build phase
# writes it, and a bundle without it is a build that skipped the phase.
[[ -f "$app_bundle/Licenses.json" ]] || {
    echo "error: $app_bundle has no Licenses.json — the Collect Licenses build phase did not run" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
# Scratch files live in their own per-run directory: macOS mktemp only
# substitutes trailing Xs, so a file template with a suffix is a fixed path.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-deb-scratch.XXXXXX")"
trap 'rm -rf "$staging" "$scratch"; rm -f "$temporary_deb"' EXIT
app_signed_entitlements="$scratch/app-entitlements.plist"
daemon_signed_entitlements="$scratch/daemon-entitlements.plist"
appex_signed_entitlements="$scratch/appex-entitlements.plist"
cli_signed_entitlements="$scratch/cli-entitlements.plist"
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_root="$staging$install_prefix"
installed_app="$installed_root/Applications/iGhostVT.app"
installed_daemon="$installed_root/usr/libexec/ighostvtd"
installed_daemon_io="$installed_root/usr/libexec/ighostvtd-io"
installed_cli="$installed_app/ighostvt-cli"
installed_cli_link="$installed_root/usr/bin/ighostvt-cli"
installed_plist="$installed_root/Library/LaunchDaemons/wiki.qaq.ighostvtd.plist"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$app_bundle" "$installed_app"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
/usr/bin/ditto "$daemon_io_binary" "$installed_daemon_io"
/usr/bin/ditto "$cli_binary" "$installed_cli"
# A relative link, and it has to stay one: under roothide the bootstrap's
# /Applications is reached through the jbroot this boot, and an absolute
# /Applications/... would resolve against iOS's own. The kernel reports the
# target it executed, so PeerAuthenticator sees the bundle path either way.
mkdir -p "$(dirname "$installed_cli_link")"
ln -sfn ../../Applications/iGhostVT.app/ighostvt-cli "$installed_cli_link"
sed -e "s|@PREFIX@|$install_prefix|g" "$launch_plist" >"$installed_plist"
# The daemon recovers its install root by stripping this suffix off its own
# executable path, so the plist has to launch it by the path it is installed
# at — a mismatch and every bootstrap path it derives is wrong.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/ighostvtd" ]] || {
    echo "error: the launch daemon does not point at the installed ighostvtd" >&2
    exit 65
}
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon" "$installed_daemon_io" "$installed_cli"
chmod 0644 "$installed_plist"

strip_and_check_private_paths() {
    local binary="$1"
    local private_path
    /usr/bin/strip -xS "$binary"
    for private_path in "$repository_root" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}"; do
        [[ -z "$private_path" || "$private_path" == / ]] && continue
        if LC_ALL=C grep -aF "$private_path" "$binary" >/dev/null; then
            echo "error: $(basename "$binary") embeds a private build path" >&2
            exit 65
        fi
    done
}

strip_and_check_private_paths "$installed_app/$app_executable"
strip_and_check_private_paths "$installed_daemon"
strip_and_check_private_paths "$installed_daemon_io"
strip_and_check_private_paths "$installed_cli"

# The bash and zsh shell integration, which is what makes a session report
# its title, its working directory, and its command boundaries. libghostty-spm
# ships it inside the app's resource bundle — its own MIT rewrite, not
# Ghostty's GPLv3 scripts, and this MIT package must stay that way; the grep
# below fails the build if a GPL header ever shows up in what was copied. The
# package installs a second copy the daemon owns, because the daemon is what
# points a new shell at them and it should not have to know the app bundle's
# internal layout to do it. Missing scripts are not fatal: the daemon checks
# before injecting, and the app falls back to inferring a title from what the
# user types.
installed_integration="$installed_root/usr/share/ighostvt/shell-integration"
integration_source="$(/usr/bin/find "$installed_app" -type d -name shell-integration -print -quit)"
if [[ -n "$integration_source" ]]; then
    if grep -rqi "General Public License" "$integration_source"; then
        echo "error: GPL-licensed file in $integration_source; refusing to package it" >&2
        grep -rli "General Public License" "$integration_source" >&2
        exit 65
    fi
    mkdir -p "$(dirname "$installed_integration")"
    /usr/bin/ditto "$integration_source" "$installed_integration"
    # The session runs as mobile, so every script has to be readable by it.
    chmod -R a+rX "$installed_integration"
else
    echo "warning: no shell-integration in the app bundle; sessions will report no title" >&2
fi

ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
# The same entitlements as its parent: it is the process that forks as root
# and drops to mobile, so it needs everything the daemon used to.
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon_io"
# The client marker and the mach lookup, and nothing else — see the
# entitlements file for why `no-sandbox` is not among them.
ldid -S"$cli_entitlements" -Cadhoc "$installed_cli"
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"

# App extensions are separate Mach-Os with their own signature, so Xcode's is
# as useless to us as the app's and the system refuses to load an appex whose
# signature does not verify. Sign every one the app ships.
shopt -s nullglob
appexes=("$installed_app/PlugIns"/*.appex)
shopt -u nullglob
for appex in ${appexes[@]+"${appexes[@]}"}; do
    appex_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
    [[ -f "$appex/$appex_executable" ]] || {
        echo "error: appex $(basename "$appex") has no executable" >&2
        exit 65
    }
    rm -rf "$appex/_CodeSignature"
    strip_and_check_private_paths "$appex/$appex_executable"
    ldid -S"$appex_entitlements" -Cadhoc "$appex/$appex_executable"
done

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}

require_false() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == false ]] || {
        echo "error: signed executable is missing entitlement: $key = false" >&2
        exit 65
    }
}

# The privilege-granting entitlements an extension must never carry. Every one
# of these either weakens the sandbox or moves the data container, and an appex
# needs none of it: it draws a Live Activity from data ActivityKit hands it.
# Absence is the assertion — `container-required=false` *is* the switch, so
# checking for `false` would pass the very thing it means to catch.
#
# The app itself legitimately carries two of these; see the block below, and
# the symptom that forced each one in Packaging/iGhostVT.entitlements.
require_unprivileged() {
    local plist="$1"
    local label="$2"
    local key
    for key in platform-application \
        com.apple.private.security.no-sandbox \
        com.apple.private.security.no-container \
        com.apple.private.security.container-required \
        com.apple.private.security.storage.AppDataContainers \
        com.apple.private.skip-library-validation; do
        [[ -z "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" ]] || {
            echo "error: $label must stay sandboxed and unprivileged: remove $key" >&2
            exit 65
        }
    done
}

# The app reaches the daemon (the client marker the daemon authenticates
# against, plus the mach-lookup exception for the service name) and carries
# the three things an ad-hoc signed bundle needs to draw a terminal at all,
# each measured on device (iPad8,9, iOS 18.5 rootless, 2026-08-18) and
# explained in Packaging/iGhostVT.entitlements: the GPU user-client list
# (without it the kernel denies AGXDeviceUserClient and Metal cannot create a
# device), `no-sandbox` (without it the kernel denies the app every write
# inside its own container, so libghostty's config never lands on disk and no
# terminal boots), and `storage.AppDataContainers` (so a no-sandbox bundle
# keeps its container, and UserDefaults stay in it). Spawning is still the
# daemon's alone — the app target has no process API at all.
require_true "$app_signed_entitlements" wiki.qaq.ighostvt.client
require_true "$app_signed_entitlements" com.apple.private.security.no-sandbox
require_true "$app_signed_entitlements" com.apple.private.security.storage.AppDataContainers
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.iokit-user-client-class:0' "$app_signed_entitlements" 2>/dev/null || true)" ]] || {
    echo "error: app is missing the GPU iokit-user-client-class list" >&2
    exit 65
}
# The container entitlements that would undo storage.AppDataContainers, plus
# the two the app was measured not to need.
for key in platform-application \
    com.apple.private.security.no-container \
    com.apple.private.security.container-required \
    com.apple.private.skip-library-validation; do
    [[ -z "$(/usr/libexec/PlistBuddy -c "Print :$key" "$app_signed_entitlements" 2>/dev/null || true)" ]] || {
        echo "error: the app must not carry $key" >&2
        exit 65
    }
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.ighostvt.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}

for signed_binary in "$installed_daemon" "$installed_daemon_io"; do
    ldid -e "$signed_binary" >"$daemon_signed_entitlements"
    for entitlement in platform-application com.apple.private.security.no-sandbox \
        com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers; do
        require_true "$daemon_signed_entitlements" "$entitlement"
    done
    require_false "$daemon_signed_entitlements" com.apple.private.security.container-required
    # Spawning belongs to the daemon alone: fail the build if either half of it
    # ever picks up the client entitlement's counterpart by mistake. Both are
    # signed with the same entitlements file, so both are asserted here rather
    # than against whichever dump the loop happened to leave behind.
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :wiki.qaq.ighostvt.client' "$daemon_signed_entitlements" 2>/dev/null || true)" != true ]] || {
        echo "error: $(basename "$signed_binary") must not carry the client entitlement" >&2
        exit 65
    }
done

# The CLI is the second peer the daemon admits by path. It needs the marker
# and the lookup; everything the app or the daemon carry would be privilege
# it has no use for, so the absence is asserted too.
ldid -e "$installed_cli" >"$cli_signed_entitlements"
require_true "$cli_signed_entitlements" wiki.qaq.ighostvt.client
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$cli_signed_entitlements")" == wiki.qaq.ighostvt.service ]] || {
    echo "error: the CLI is missing the daemon mach lookup entitlement" >&2
    exit 65
}
require_unprivileged "$cli_signed_entitlements" ighostvt-cli
[[ -z "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.iokit-user-client-class' "$cli_signed_entitlements" 2>/dev/null || true)" ]] || {
    echo "error: the CLI must not carry the GPU iokit-user-client-class list" >&2
    exit 65
}

# Every appex is a second process running under the app's bundle id prefix and
# none of its privileges. The daemon authenticates peers by their binary, so an
# extension carrying the client entitlement would be an entrance nobody
# designed — check what was actually signed, not what the file asked for.
for appex in ${appexes[@]+"${appexes[@]}"}; do
    appex_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
    ldid -e "$appex/$appex_executable" >"$appex_signed_entitlements"
    require_unprivileged "$appex_signed_entitlements" "$(basename "$appex")"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :wiki.qaq.ighostvt.client' "$appex_signed_entitlements" 2>/dev/null || true)" != true ]] || {
        echo "error: $(basename "$appex") must not carry the client entitlement" >&2
        exit 65
    }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name' "$appex_signed_entitlements" 2>/dev/null || true)" != *ighostvt* ]] || {
        echo "error: $(basename "$appex") must not reach the daemon's mach service" >&2
        exit 65
    }
done

installed_size="$(du -sk "$installed_root/Applications" "$installed_root/usr" "$installed_root/Library" | awk '{total += $1} END {print total}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@DEPENDS@/$depends/g" \
    "$control_template" >"$debian/control"

packaging_root="$(cd "$(dirname "$control_template")/.." && pwd -P)"
for script in postinst prerm postrm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$packaging_root/DEBIAN/$script" >"$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm" "$debian/postrm"
# What dpkg will run is the substituted copy, so that is the one checked: it
# has to parse, and no packager placeholder may be left in anything shipped.
for script in postinst prerm postrm; do
    sh -n "$debian/$script"
done
if grep -nE '@[A-Z_]+@' "$debian/control" "$debian/postinst" "$debian/prerm" "$debian/postrm" "$installed_plist"; then
    echo "error: an unsubstituted placeholder is left in the package (above)" >&2
    exit 65
fi

dpkg-deb --root-owner-group -Zzstd -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Depends)" == "$depends" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
grep -F ".$install_prefix/Applications/iGhostVT.app/$app_executable" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/libexec/ighostvtd" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/libexec/ighostvtd-io" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Applications/iGhostVT.app/ighostvt-cli" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/bin/ighostvt-cli -> ../../Applications/iGhostVT.app/ighostvt-cli" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Library/LaunchDaemons/wiki.qaq.ighostvtd.plist" <<<"$contents" >/dev/null
[[ -z "$integration_source" ]] || grep -F ".$install_prefix/usr/share/ighostvt/shell-integration/zsh/.zshenv" <<<"$contents" >/dev/null

mv -f "$temporary_deb" "$output_deb"
echo "Packaged iGhostVT: $output_deb"
shasum -a 256 "$output_deb"
