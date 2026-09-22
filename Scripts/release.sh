#!/bin/bash
# One-command release: version bump → commit → tag → GitHub Release run →
# asset check → APT repository build → the repo actually serving it.
#
#   release.sh <x.y.z> [build]
#
# Build defaults to the current build number plus one. INSTALL=1 finishes by
# replacing /Applications/iGhostVT.app with the freshly published zip
# (`make mac-update-from-github`, Touch ID for sudo).
#
# The APT run's own conclusion is advisory — a run can fail on a trailing
# step after deploying, and another run can have deployed first — so the
# acceptance test is what https://apt.owngoal.dev/Packages actually serves.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
apt_repo="owngoal-dev/owngoal-packages"
apt_workflow="Build and Deploy APT Repository"
apt_index="https://apt.owngoal.dev/Packages"

die() {
    echo "error: $*" >&2
    exit 65
}

command -v gh >/dev/null || die "gh is required"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

version="${1:-}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh <x.y.z> [build]"

cd "$root"
[[ -z "$(git status --porcelain)" ]] || die "the tree is dirty; commit or stash first"
branch="$(git rev-parse --abbrev-ref HEAD)"
[[ "$branch" == "main" ]] || die "release from main (this is $branch)"
git fetch origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "main and origin/main differ; pull or push first"
git rev-parse -q --verify "refs/tags/v$version" >/dev/null \
    && die "tag v$version already exists"
# release.yml publishes this file as the release notes and the Pages
# depiction serves it as the changelog; without it the release goes out with
# a one-paragraph fallback and the depiction says nothing about $version.
[[ -f "Documents/Releases/$version.md" ]] \
    || die "Documents/Releases/$version.md is missing; write the release note before cutting"

build="${2:-}"
if [[ -z "$build" ]]; then
    current="$(make -s print-build-number)"
    [[ "$current" =~ ^[0-9]+$ ]] || die "could not read the current build number"
    build=$((current + 1))
fi

echo "==> $version (build $build)"
make set-version VERSION="$version" BUILD="$build"
make check
git add Configuration/Version.xcconfig
git commit -m "$version"
git tag "v$version"
git push origin main "v$version"

echo "==> waiting for the Release workflow"
run_id=""
for _ in $(seq 1 30); do
    # `|| true`: under `set -e` a failing substitution ends the script, and a
    # transient API error must fall through to the next poll instead.
    run_id="$(gh run list --workflow Release --limit 5 \
        --json databaseId,displayTitle \
        --jq ".[] | select(.displayTitle == \"$version\") | .databaseId" 2>/dev/null | head -n 1 || true)"
    [[ -n "$run_id" ]] && break
    sleep 5
done
[[ -n "$run_id" ]] || die "the Release run for $version never appeared"
gh run watch "$run_id" --exit-status >/dev/null || die "Release run $run_id failed"
echo "    run $run_id succeeded"

echo "==> verifying the release assets"
assets="$(gh release view "v$version" --json assets --jq '.assets[].name')"
for want in \
    "iGhostVT-$version-macos.zip" \
    "wiki.qaq.ighostvt_${version}_iphoneos-arm64.deb" \
    "wiki.qaq.ighostvt_${version}_iphoneos-arm64e.deb" \
    "wiki.qaq.ighostvt_${version}_xros-arm64e.deb" \
    "iGhostVT-$version-roothide-dSYMs.zip" \
    "iGhostVT-$version-rootless-dSYMs.zip" \
    "iGhostVT-$version-xros-dSYMs.zip" \
    "iGhostVT-$version-macos-dSYMs.zip" \
    "SHA256SUMS" \
    "SHA256SUMS.macos"; do
    grep -qxF "$want" <<<"$assets" || die "release v$version is missing $want"
done
echo "    all release assets present"

echo "==> dispatching the APT repository build"
gh -R "$apt_repo" workflow run "$apt_workflow"
sleep 10
apt_run="$(gh -R "$apt_repo" run list --workflow "$apt_workflow" --limit 1 \
    --json databaseId --jq '.[0].databaseId')"
if [[ -n "$apt_run" ]]; then
    gh -R "$apt_repo" run watch "$apt_run" --exit-status >/dev/null \
        || echo "    note: APT run $apt_run did not succeed; checking what the repo serves anyway" >&2
fi

echo "==> verifying $apt_index serves $version"
served=""
for _ in $(seq 1 30); do
    # Same `|| true`: one 404/5xx from the CDN is the race this poll exists
    # for, not a reason to abandon a release that has already been served.
    served="$(curl -fsSL "$apt_index" 2>/dev/null \
        | awk '/^Package: wiki.qaq.ighostvt$/{p=1} p&&/^Version:/{print $2; p=0}' \
        | sort -u || true)"
    # The repository keeps earlier versions beside the new one.
    grep -qxF "$version" <<<"$served" && break
    sleep 10
done
grep -qxF "$version" <<<"$served" \
    || die "the APT repository serves '$(tr '\n' ' ' <<<"$served")', not $version"
echo "    served"

echo "==> released $version (build $build)"
if [[ "${INSTALL:-0}" == "1" ]]; then
    make mac-update-from-github TAG="v$version"
else
    echo "    install locally with: make mac-update-from-github TAG=v$version"
fi
