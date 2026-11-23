#!/bin/bash
# The Mac zip a release published, signed with Developer ID and notarized,
# attached to the same release as iGhostVT-<version>-macos-notarized.zip,
# with its sum added to the release's SHA256SUMS.macos.
#
#   notarize-mac-release.sh <vX.Y.Z | X.Y.Z>
#
# Nothing is compiled. The zip CI built and the Release run published is
# downloaded, checked against the release's SHA256SUMS.macos, and only its
# signatures change: every binary is re-signed inside out the way
# mac-update-from-github.sh does it — hardened runtime, a timestamp, and the
# identifiers and (empty) entitlements kept, since the CLI's identifier is a
# contract with PeerAuthenticator — then submitted to Apple, stapled and
# zipped again. Gatekeeper opens the result without clearing a quarantine
# bit, and a Team ID signature keeps Background Task Management's launch
# constraint across updates (AGENTS.md).
#
# The signing identity and the notarytool credentials come from one keychain
# made for this, never from the repo:
#   NOTARY_TOOLBOX_ZIP_BASE64  a zip holding that keychain, base64 (the
#                              Notarize workflow's secret)
#   NOTARY_TOOLBOX_PASSWORD    its password
# or, on a Mac that has the keychain on disk:
#   KEYCHAIN_DB, KEYCHAIN_PASSWORD
# The keychain holds one Developer ID Application identity and the profile
# `xcrun notarytool store-credentials <name> --keychain <db>` saved in it.
#
# NOTARIZE_UPLOAD=0 leaves the release alone and prints where the zip is.
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 65
}

tag="${1:-}"
tag="v${tag#v}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: notarize-mac-release.sh <vX.Y.Z>"
version="${tag#v}"
asset="iGhostVT-${version}-macos.zip"
notarized="iGhostVT-${version}-macos-notarized.zip"
cli_identifier="wiki.qaq.ighostvt-cli"
mcp_identifier="wiki.qaq.ighostvt-mcp"

command -v gh >/dev/null || die "gh is required"
command -v ditto >/dev/null || die "ditto is required"

workdir="$(mktemp -d "${TMPDIR:-/tmp}/ighostvt-notarize.XXXXXX")"
added_keychain=""
original_keychains=()
cleanup() {
    # The keychain leaves the search list before its file goes: a runner is
    # thrown away, a Mac running this by hand is not.
    if [[ -n "$added_keychain" ]]; then
        security list-keychains -d user -s "${original_keychains[@]}" 2>/dev/null || true
    fi
    rm -rf "$workdir"
}
trap cleanup EXIT

# MARK: - The keychain

keychain="${KEYCHAIN_DB:-}"
password="${KEYCHAIN_PASSWORD:-}"
if [[ -z "$keychain" ]]; then
    [[ -n "${NOTARY_TOOLBOX_ZIP_BASE64:-}" ]] || die "NOTARY_TOOLBOX_ZIP_BASE64 (or KEYCHAIN_DB) is not set"
    [[ -n "${NOTARY_TOOLBOX_PASSWORD:-}" ]] || die "NOTARY_TOOLBOX_PASSWORD is not set"
    mkdir -p "$workdir/toolbox"
    printf '%s' "$NOTARY_TOOLBOX_ZIP_BASE64" | base64 -D >"$workdir/toolbox.zip"
    ditto -x -k "$workdir/toolbox.zip" "$workdir/toolbox"
    keychain="$(find "$workdir/toolbox" -type f \( -name '*.keychain-db' -o -name '*.keychain' \) \
        -not -path '*/__MACOSX/*' | head -n 1)"
    [[ -n "$keychain" ]] || die "the toolbox zip holds no keychain"
    password="$NOTARY_TOOLBOX_PASSWORD"
fi
[[ -f "$keychain" ]] || die "no keychain at $keychain"
[[ -n "$password" ]] || die "KEYCHAIN_PASSWORD is not set"

echo "==> unlocking the signing keychain"
while IFS= read -r line; do
    line="$(tr -d '"' <<<"$line" | xargs)"
    [[ -n "$line" ]] && original_keychains+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${original_keychains[@]}"
added_keychain="$keychain"
security unlock-keychain -p "$password" "$keychain"
security set-keychain-settings -t 3600 -l "$keychain"
# Without this codesign asks, in a dialog nobody is there to answer, before
# it may use the private key.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

identity_line="$(security find-identity -v -p codesigning "$keychain" | grep '"Developer ID Application: ' | head -n 1 || true)"
[[ -n "$identity_line" ]] || die "the keychain holds no Developer ID Application identity"
identity="$(awk '{ print $2 }' <<<"$identity_line")"
team="$(sed -n 's/.*(\([A-Z0-9]*\))".*/\1/p' <<<"$identity_line")"
echo "    team $team"

profile="$(security dump-keychain "$keychain" 2>/dev/null | strings \
    | grep -o 'com\.apple\.gke\.notary\.tool\.saved-creds\.[^"]*' | head -n 1 \
    | sed 's/^com\.apple\.gke\.notary\.tool\.saved-creds\.//' || true)"
[[ -n "$profile" ]] || die "the keychain holds no notarytool profile (xcrun notarytool store-credentials <name> --keychain <db>)"
echo "    notarytool profile $profile"

# MARK: - The zip CI built

echo "==> downloading $asset from $tag"
gh release download "$tag" --pattern "$asset" --pattern SHA256SUMS.macos --dir "$workdir/download"
expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$workdir/download/SHA256SUMS.macos")"
[[ -n "$expected" ]] || die "SHA256SUMS.macos does not list $asset"
actual="$(shasum -a 256 "$workdir/download/$asset" | awk '{ print $1 }')"
[[ "$actual" == "$expected" ]] || die "$asset does not match SHA256SUMS.macos"

mkdir -p "$workdir/app"
ditto -x -k "$workdir/download/$asset" "$workdir/app"
app="$workdir/app/iGhostVT.app"
[[ -d "$app" ]] || die "$asset holds no iGhostVT.app"

# MARK: - Signing

echo "==> re-signing with Developer ID"
resign() {
    codesign --force --sign "$identity" --keychain "$keychain" --options runtime --timestamp \
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
codesign --display --verbose=2 "$app/Contents/MacOS/ighostvt-cli" 2>&1 \
    | grep -x "Identifier=$cli_identifier" >/dev/null \
    || die "ighostvt-cli lost its identifier $cli_identifier; the daemon would refuse it"
if [[ -e "$app/Contents/MacOS/ighostvt-mcp" ]]; then
    codesign --display --verbose=2 "$app/Contents/MacOS/ighostvt-mcp" 2>&1 \
        | grep -x "Identifier=$mcp_identifier" >/dev/null \
        || die "ighostvt-mcp lost its identifier $mcp_identifier"
fi

# MARK: - Notarization

echo "==> notarizing"
ditto -c -k --sequesterRsrc --keepParent "$app" "$workdir/submit.zip"
result="$(xcrun notarytool submit "$workdir/submit.zip" --keychain-profile "$profile" --keychain "$keychain" \
    --wait --output-format json)"
submission="$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
echo "    submission $submission: $status"
if [[ "$status" != "Accepted" ]]; then
    [[ -z "$submission" ]] || xcrun notarytool log "$submission" --keychain-profile "$profile" --keychain "$keychain" || true
    die "notarization ended as '${status:-unknown}'"
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir -p "$workdir/out"
ditto -c -k --sequesterRsrc --keepParent "$app" "$workdir/out/$notarized"
sum="$(shasum -a 256 "$workdir/out/$notarized" | awk '{ print $1 }')"
echo "    $sum  $notarized"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '`%s`\n\n```\n%s  %s\n```\n' "$notarized" "$sum" "$notarized" >>"$GITHUB_STEP_SUMMARY"
fi

if [[ "${NOTARIZE_UPLOAD:-1}" == "0" ]]; then
    kept="${NOTARIZE_OUTPUT_DIR:-$PWD}/$notarized"
    cp "$workdir/out/$notarized" "$kept"
    echo "==> kept $kept; the release was left alone"
    exit 0
fi

echo "==> attaching $notarized to $tag"
gh release upload "$tag" "$workdir/out/$notarized" --clobber

# Its sum goes beside the ad-hoc zip's, replacing the line a run before this
# one wrote: a new signature is a new file.
grep -vF "  $notarized" "$workdir/download/SHA256SUMS.macos" >"$workdir/out/SHA256SUMS.macos" || true
printf '%s  %s\n' "$sum" "$notarized" >>"$workdir/out/SHA256SUMS.macos"
gh release upload "$tag" "$workdir/out/SHA256SUMS.macos" --clobber
echo "    SHA256SUMS.macos lists it"
