#!/bin/bash
# Create (or update) a GitHub Release from already-built packages.
#
#   publish-release.sh <tag> <asset> [<asset> ...]
#
# The three platform jobs (roothide .deb, rootless .deb, macOS zip) each
# produce their own artifact. This is the merge step: the tag must already
# exist on the remote, and every file given here is attached to that tag's
# GitHub Release. A machine that was not the one that built a given package
# can still publish — it only needs the files.
#
# Retries on transient API failures. `gh release view` is what decides
# create vs upload, so a 503 is not mistaken for "the release already exists".
set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 65
}

command -v gh >/dev/null || die "gh is required"

tag="${1:-}"
shift || true
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must look like v1.2.3 (got '$tag')"
[[ "$#" -ge 1 ]] || die "usage: $0 <tag> <asset> [<asset> ...]"

for asset in "$@"; do
    [[ -f "$asset" ]] || die "not a file: $asset"
done

repo="${GITHUB_REPOSITORY:-}"
repo_flag=()
if [[ -n "$repo" ]]; then
    repo_flag=(-R "$repo")
fi

# The note is a file in the repo (`Documents/Releases/<version>.md`), and it
# is what the Pages depiction serves as the changelog. `--generate-notes`
# only ever produced a compare link, so it is the fallback for a tag whose
# note was never written, not the default.
root="$(cd "$(dirname "$0")/.." && pwd)"
version="${tag#v}"
notes_file="$root/Documents/Releases/$version.md"
notes_flag=(--notes-file "$notes_file")
if [[ ! -f "$notes_file" ]]; then
    echo "warning: $notes_file is missing; falling back to a generated compare link" >&2
    notes_flag=(--generate-notes)
fi

echo "==> publishing $# asset(s) to $tag"
for attempt in 1 2 3 4 5; do
    # `${arr[@]+"${arr[@]}"}`: an empty array is an unbound variable under
    # bash 3.2's `set -u`, which is what /bin/bash is on a Mac.
    if gh release view ${repo_flag[@]+"${repo_flag[@]}"} "$tag" >/dev/null 2>&1; then
        gh release upload ${repo_flag[@]+"${repo_flag[@]}"} "$tag" "$@" --clobber && exit 0
    else
        gh release create ${repo_flag[@]+"${repo_flag[@]}"} "$tag" \
            --title "iGhostVT $version" \
            "${notes_flag[@]}" \
            "$@" && exit 0
    fi
    echo "publish attempt ${attempt} failed; retrying in 20s" >&2
    sleep 20
done

die "could not publish $tag after 5 attempts"
