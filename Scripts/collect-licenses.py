#!/usr/bin/env python3
"""Collects every license the app ships under into one Licenses.json.

Runs as the "Collect Licenses" build phase of the iGhostVT target, so the
list is made of what this build actually links, not a hand-kept copy that
drifts:

  1. the app itself — the repository's LICENSE, versioned from
     Configuration/Version.xcconfig;
  2. the vendored notices under Licenses/ — one folder per component whose
     license the package scan cannot reach, each holding a LICENSE and a
     notice.json (name, url, and where its version comes from). Ghostty is
     the one that matters: libghostty-spm ships it as a prebuilt XCFramework,
     and a binary carries no license file;
  3. every package pinned in Package.resolved — its checkout under
     SourcePackages is walked for LICENSE / COPYING / NOTICE files, at the
     root and nested (libghostty-spm carries the iTerm2 color schemes' and
     bash-preexec's notices beside the files they cover).

A pin whose checkout is missing, or whose checkout has no license file at
all, fails the build: the list would be incomplete and nobody would notice.
So does GPL-family text anywhere in the set — the package is MIT and the
.deb once shipped Ghostty's GPLv3 shell integration by accident; this is the
last check that it stays out.

Output: a JSON array of {name, version?, license, url, text}, read by
LicenseCatalog in the app.
"""

import argparse
import json
import os
import re
import sys

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)([-_.].*)?$", re.IGNORECASE)
SKIPPED_DIRECTORIES = {
    ".git", ".build", ".swiftpm", "Tests", "Test", "Example", "Examples",
    "docs", "Documentation", "node_modules", "Script", "Scripts", "Patches",
}
# Sources named in the nested notices, rather than the package carrying them.
NESTED_LICENSE_URLS = {
    ("libghostty-spm", "Sources/GhosttyTerminal/Resources/Ghostty/shell-integration/bash/LICENSE-bash-preexec.md"):
        "https://github.com/rcaloras/bash-preexec",
    ("libghostty-spm", "Sources/GhosttyTheme/LICENSE"):
        "https://github.com/mbadolato/iTerm2-Color-Schemes",
}
# Identifier heuristics, first match wins; a text that matches none is shown
# as "Other" and still shipped whole.
LICENSE_KINDS = [
    ("GPL", re.compile(r"GNU (Affero |Lesser |Library )?General Public License|www\.gnu\.org/licenses/(a|l)?gpl", re.IGNORECASE)),
    ("Apache-2.0", re.compile(r"Apache License,? Version 2\.0", re.IGNORECASE)),
    ("MPL-2.0", re.compile(r"Mozilla Public License,? (Version |v\.? ?)2\.0", re.IGNORECASE)),
    ("MIT", re.compile(r"MIT License|Permission is hereby granted, free of charge", re.IGNORECASE)),
    ("BSD", re.compile(r"Redistribution and use in source and binary forms", re.IGNORECASE)),
    ("ISC", re.compile(r"ISC License|Permission to use, copy, modify, and/or distribute", re.IGNORECASE)),
    ("Unlicense", re.compile(r"This is free and unencumbered software", re.IGNORECASE)),
    ("Zlib", re.compile(r"This software is provided 'as-is', without any express or implied warranty", re.IGNORECASE)),
]


def fail(message):
    # Xcode reads "error:" lines into the issue navigator.
    print(f"error: collect-licenses: {message}", file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip("\n") + "\n"


def license_kind(text):
    for kind, pattern in LICENSE_KINDS:
        if pattern.search(text):
            return kind
    return "Other"


def entry(name, version, url, text):
    kind = license_kind(text)
    if kind == "GPL":
        fail(f"{name} carries GPL-family license text; the app does not ship GPL code")
    item = {"name": name, "license": kind, "url": url, "text": text}
    if version:
        item["version"] = version
    return item


def xcconfig_setting(path, key):
    for line in read(path).splitlines():
        head, sep, value = line.partition("=")
        if sep and head.strip() == key:
            return value.split("//")[0].strip()
    fail(f"{key} is missing from {path}")


def app_entry(project):
    manifest = json.load(open(os.path.join(project, "manifest.json"), encoding="utf-8"))
    return entry(
        "iGhostVT",
        xcconfig_setting(os.path.join(project, "Configuration", "Version.xcconfig"), "MARKETING_VERSION"),
        manifest.get("homepage", ""),
        read(os.path.join(project, "LICENSE")),
    )


def vendored_entries(project, checkouts):
    root = os.path.join(project, "Licenses")
    entries = []
    for folder in sorted(os.listdir(root)):
        directory = os.path.join(root, folder)
        if not os.path.isdir(directory):
            continue
        notice_path = os.path.join(directory, "notice.json")
        license_path = os.path.join(directory, "LICENSE")
        for required in (notice_path, license_path):
            if not os.path.isfile(required):
                fail(f"Licenses/{folder} lacks {os.path.basename(required)}")
        notice = json.load(open(notice_path, encoding="utf-8"))
        version = notice.get("version")
        version_file = notice.get("version_file")
        if version_file:
            path = os.path.join(checkouts, version_file)
            if not os.path.isfile(path):
                fail(f"Licenses/{folder}: version_file {version_file} is not in the package checkouts")
            version = read(path).strip()
        entries.append(entry(notice["name"], version, notice.get("url", ""), read(license_path)))
    return entries


def package_entries(project, checkouts):
    resolved_path = os.path.join(
        project, "iGhostVT.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"
    )
    resolved = json.load(open(resolved_path, encoding="utf-8"))
    entries = []
    for pin in sorted(resolved["pins"], key=lambda pin: pin["identity"]):
        location = pin["location"]
        url = location[:-4] if location.endswith(".git") else location
        package = url.rstrip("/").rsplit("/", 1)[-1]
        state = pin.get("state", {})
        version = state.get("version") or state.get("revision")
        checkout = os.path.join(checkouts, package)
        if not os.path.isdir(checkout):
            fail(f"{package} is pinned in Package.resolved but has no checkout under {checkouts}")
        found = []
        for directory, subdirectories, files in os.walk(checkout):
            subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
            for filename in sorted(files):
                if LICENSE_FILE.match(filename) and not filename.endswith(".template"):
                    found.append(os.path.join(directory, filename))
        if not found:
            fail(f"{package} has no LICENSE, COPYING, or NOTICE file in its checkout")
        # The root license first, nested notices after it, so a package reads
        # as itself and then what it vendors.
        found.sort(key=lambda path: (os.path.dirname(path) != checkout, path))
        for path in found:
            relative_directory = os.path.relpath(os.path.dirname(path), checkout)
            stem = os.path.splitext(os.path.basename(path))[0]
            suffix = re.sub(r"^(LICEN[CS]E|COPYING|NOTICE)[-_.]?", "", stem, flags=re.IGNORECASE)
            if relative_directory == ".":
                name = package
            elif suffix:
                name = suffix
            else:
                name = os.path.basename(relative_directory)
            source_url = NESTED_LICENSE_URLS.get((package, os.path.relpath(path, checkout)), url)
            entries.append(entry(name, version if relative_directory == "." else None, source_url, read(path)))
    return entries


def find_source_packages(build_dir):
    """Xcode keeps SourcePackages beside Build/ in the derived data folder;
    BUILD_DIR is Build/Products for a build and a deeper archive path for an
    archive, so walk up until the sibling appears."""
    directory = os.path.abspath(build_dir)
    # Xcode nests BUILD_DIR at most this far below the derived-data root; past
    # it the walk would leave derived data and test the user's home and /.
    for _ in range(8):
        candidate = os.path.join(directory, "SourcePackages")
        if os.path.isdir(os.path.join(candidate, "checkouts")):
            return candidate
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    fail(f"no SourcePackages/checkouts above {build_dir}; resolve the packages first")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True, help="the repository root (SRCROOT)")
    parser.add_argument("--build-dir", required=True, help="Xcode's BUILD_DIR, used to find SourcePackages")
    parser.add_argument("--output", required=True, help="where to write Licenses.json")
    arguments = parser.parse_args()

    checkouts = os.path.join(find_source_packages(arguments.build_dir), "checkouts")
    entries = [app_entry(arguments.project)]
    entries += vendored_entries(arguments.project, checkouts)
    entries += package_entries(arguments.project, checkouts)

    os.makedirs(os.path.dirname(arguments.output), exist_ok=True)
    with open(arguments.output, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"collect-licenses: {len(entries)} licenses -> {arguments.output}")


if __name__ == "__main__":
    main()
