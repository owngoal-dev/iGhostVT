# iGhostVT Xcode build and jailbreak Debian packaging (roothide, rootless;
# iOS and visionOS)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT_DIR            := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT             := $(ROOT_DIR)/iGhostVT.xcodeproj
SCHEME              := iGhostVT
CONFIGURATION       ?= Release
DERIVED_DATA        ?= /private/tmp/ighostvt-deriveddata

# Which OS the device build targets. `ios` is the iPhone/iPad package; `xros`
# is the same app and daemon built for a jailbroken Apple Vision Pro — same
# sources, same packaging, a different SDK and Mach-O platform. The two axes
# are independent: PLATFORM picks the binaries, PACKAGE_FLAVOR the layout.
PLATFORM            ?= ios
ifeq ($(PLATFORM),ios)
DEVICE_DESTINATION  := generic/platform=iOS
PRODUCTS_SDK        := iphoneos
DEB_ARCH_OS         := iphoneos
# uikittools' triggers register the app; the maintainer scripts run launchctl
# and killall, and killall ships in shell-cmds.
DEB_DEPENDS         := firmware (>= 15.0), uikittools, launchctl, shell-cmds
else ifeq ($(PLATFORM),xros)
DEVICE_DESTINATION  := generic/platform=visionOS
PRODUCTS_SDK        := xros
# The dpkg architecture a visionOS bootstrap reports is its own to say; xros-*
# keeps the package distinct from the iOS one in a shared APT repository (same
# id, same version, different binaries). Override PACKAGE_ARCHITECTURE if the
# device's dpkg wants another label.
DEB_ARCH_OS         := xros
DEB_DEPENDS         := firmware (>= 1.0), uikittools, launchctl, shell-cmds
else
$(error PLATFORM must be ios or xros, got '$(PLATFORM)')
endif
PRODUCTS_DIR        := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-$(PRODUCTS_SDK)
APP_BUNDLE          := $(PRODUCTS_DIR)/iGhostVT.app
DAEMON_BINARY       := $(PRODUCTS_DIR)/ighostvtd
DAEMON_IO_BINARY    := $(PRODUCTS_DIR)/ighostvtd-io
CLI_BINARY          := $(PRODUCTS_DIR)/ighostvt-cli
DAEMON_SCHEME       := ighostvtd
PACKAGE_ID          ?= wiki.qaq.ighostvt
BUNDLE_ID           := wiki.qaq.iGhostVT
PROJECT_OBJECT_VERSION := 77

# Which jailbreak layout the .deb is built for. roothide relocates the package
# into the jbroot it picked this boot, so its paths ship unprefixed; a rootless
# bootstrap lives at a fixed /var/jb that every path in the package has to
# name. The binaries are identical — only the layout and the architecture
# label differ.
PACKAGE_FLAVOR      ?= roothide
ifeq ($(PACKAGE_FLAVOR),roothide)
PACKAGE_PREFIX      :=
PACKAGE_ARCHITECTURE ?= $(DEB_ARCH_OS)-arm64e
else ifeq ($(PACKAGE_FLAVOR),rootless)
PACKAGE_PREFIX      := /var/jb
PACKAGE_ARCHITECTURE ?= $(DEB_ARCH_OS)-arm64
else
$(error PACKAGE_FLAVOR must be roothide or rootless, got '$(PACKAGE_FLAVOR)')
endif
# The clang module holding the SDK's XPC_TYPE_* macros as C functions. Xcode
# reaches it through SWIFT_INCLUDE_PATHS in Configuration/Base.xcconfig; the
# hand-rolled harness compile needs the same -I.
XPC_SHIM_DIR        := $(ROOT_DIR)/Shared/XPCShim
CONFIG_DIR          := $(ROOT_DIR)/Configuration
VERSION_CONFIG      := $(CONFIG_DIR)/Version.xcconfig
xcconfig_setting     = $(strip $(shell awk -F= '$$1 ~ /^[[:space:]]*$(1)[[:space:]]*$$/ { gsub(/[[:space:]]/, "", $$2); print $$2; exit }' "$(VERSION_CONFIG)"))
APP_VERSION         := $(call xcconfig_setting,MARKETING_VERSION)
BUILD_NUMBER        := $(call xcconfig_setting,CURRENT_PROJECT_VERSION)
DEB_OUTPUT          ?= $(ROOT_DIR)/build/Packages/$(PACKAGE_ID)_$(APP_VERSION)_$(PACKAGE_ARCHITECTURE).deb

XCODEBUILD_WRAPPER  := $(ROOT_DIR)/Scripts/run-xcodebuild.sh
DEB_PACKAGER        := $(ROOT_DIR)/Scripts/package-deb.sh
VERSION_APPLIER     := $(ROOT_DIR)/Scripts/apply-version.sh
LICENSE_COLLECTOR   := $(ROOT_DIR)/Scripts/collect-licenses.py
MAC_DAEMON_LOADER   := $(ROOT_DIR)/Scripts/mac-daemon.sh
MAC_PACKAGER        := $(ROOT_DIR)/Scripts/package-mac.sh
MAC_UPDATE_FROM_GITHUB := $(ROOT_DIR)/Scripts/mac-update-from-github.sh
RELEASE_SH          := $(ROOT_DIR)/Scripts/release.sh
CONTROL_TEMPLATE    := $(ROOT_DIR)/Packaging/DEBIAN/control
ENTITLEMENTS        := $(ROOT_DIR)/Packaging/iGhostVT.entitlements
DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/iGhostVTDaemon.entitlements
CLI_ENTITLEMENTS    := $(ROOT_DIR)/Packaging/iGhostVTCLI.entitlements
APPEX_ENTITLEMENTS  := $(ROOT_DIR)/Packaging/iGhostVTWidgets.entitlements
LAUNCH_DAEMON       := $(ROOT_DIR)/Packaging/wiki.qaq.ighostvtd.plist

XCODEBUILD := $(XCODEBUILD_WRAPPER) \
	-project "$(PROJECT)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipMacroValidation \
	-skipPackagePluginValidation

UNSIGNED_XCODEBUILD := $(XCODEBUILD) \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	CODE_SIGN_IDENTITY=""

DEVICE_XCODEBUILD := $(UNSIGNED_XCODEBUILD) \
	ARCHS=arm64 \
	ONLY_ACTIVE_ARCH=YES \
	ENABLE_DEBUG_DYLIB=NO

ifeq ($(APP_VERSION),)
$(error MARKETING_VERSION is missing from Configuration/Version.xcconfig)
endif
ifeq ($(BUILD_NUMBER),)
$(error CURRENT_PROJECT_VERSION is missing from Configuration/Version.xcconfig)
endif

.PHONY: all help print-version print-build-number print-deb-path print-mac-zip-path set-version bump-build check test harness build deb deb-roothide deb-rootless deb-xros deb-xros-rootless mac-app mac-daemon mac-daemon-uninstall mac-run mac-zip-check mac-zip mac-update-from-github release clean

all: deb

help:
	@echo "iGhostVT:"
	@echo "  build       Build the unsigned iGhostVT.app and daemon (PLATFORM=$(PLATFORM): ios or xros)"
	@echo "  deb         Build, ad-hoc sign, and package the .deb (PLATFORM=$(PLATFORM) PACKAGE_FLAVOR=$(PACKAGE_FLAVOR))"
	@echo "  deb-roothide  Package for roothide (unprefixed, iphoneos-arm64e)"
	@echo "  deb-rootless  Package for a rootless bootstrap (/var/jb, iphoneos-arm64)"
	@echo "  deb-xros    Package the visionOS build for roothide (unprefixed, xros-arm64e)"
	@echo "  deb-xros-rootless  Package the visionOS build for a rootless bootstrap (/var/jb, xros-arm64)"
	@echo "  test        Run the PTY harness"
	@echo "  harness     Run the daemon on macOS: proxy, ighostvtd-io, and the PTY spawn tests"
	@echo "  check       Validate the project and packaging inputs"
	@echo "  mac-run     Build the Mac Catalyst app, load ighostvtd as a LaunchAgent, open the app"
	@echo "  mac-app     Build the Mac Catalyst app only"
	@echo "  mac-daemon  Build ighostvtd for macOS and (re)load it as a per-user LaunchAgent"
	@echo "  mac-daemon-uninstall  Unload and remove the macOS LaunchAgent"
	@echo "  mac-zip     Build, sign, and zip the distributable macOS app (MAC_ZIP_IDENTITY=$(MAC_ZIP_IDENTITY))"
	@echo "  mac-zip-check  Validate the macOS packaging inputs"
	@echo "  mac-update-from-github  Download a GitHub macOS zip, re-sign it with a local Developer ID if one exists, and replace /Applications/iGhostVT.app (TAG=vX.Y.Z)"
	@echo "  release     Bump, tag, wait for the GitHub Release, dispatch and verify the APT repo (VERSION=x.y.z [BUILD=n] [INSTALL=1])"
	@echo "  set-version Write VERSION=x.y.z [BUILD=n] into Configuration/Version.xcconfig"
	@echo "  clean       Remove derived data and generated packages"

print-version:
	@echo "$(APP_VERSION)"

print-build-number:
	@echo "$(BUILD_NUMBER)"

print-deb-path:
	@echo "$(DEB_OUTPUT)"

print-mac-zip-path:
	@echo "$(MAC_ZIP_OUTPUT)"

set-version:
	@test -n "$(VERSION)" || { echo "usage: make set-version VERSION=1.2.3 [BUILD=42]" >&2; exit 64; }
	@"$(VERSION_APPLIER)" "$(VERSION)" $(BUILD)

# Every build gets its own number, so a device can say which build it runs.
# CI is exempt: the workflow pins the build number to its run number, and a
# bump there would ship an artifact that disagrees with the tag.
bump-build:
	@if [ -n "$${CI:-}" ]; then echo "==> CI: keeping build $(BUILD_NUMBER)"; else \
		"$(VERSION_APPLIER)" "$(APP_VERSION)" $$(( $(BUILD_NUMBER) + 1 )) >/dev/null; \
		echo "==> build $$(( $(BUILD_NUMBER) + 1 ))"; fi

check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v ldid >/dev/null || { echo "error: ldid is required" >&2; exit 69; }
	@command -v dpkg-deb >/dev/null || { echo "error: dpkg-deb is required" >&2; exit 69; }
	@test -d "$(PROJECT)" || { echo "error: iGhostVT.xcodeproj is missing" >&2; exit 66; }
	@objver="$$(sed -n 's/^[[:space:]]*objectVersion = \([0-9]*\);.*/\1/p' "$(PROJECT)/project.pbxproj")"; \
		[[ "$$objver" == "$(PROJECT_OBJECT_VERSION)" ]] || { echo "error: project.pbxproj objectVersion must stay $(PROJECT_OBJECT_VERSION), got '$$objver'" >&2; exit 65; }
	@grep -qE '^[[:space:]]*(MARKETING_VERSION|CURRENT_PROJECT_VERSION) =' "$(PROJECT)/project.pbxproj" \
		&& { echo "error: versions must live in Configuration/Version.xcconfig, not project.pbxproj — a target-level value shadows the xcconfig and ships the wrong build number" >&2; exit 65; } || true
	@test -f "$(CONTROL_TEMPLATE)" || { echo "error: Debian control template is missing" >&2; exit 66; }
	@test -x "$(DEB_PACKAGER)" || { echo "error: package-deb.sh is not executable" >&2; exit 66; }
	@test -x "$(VERSION_APPLIER)" || { echo "error: apply-version.sh is not executable" >&2; exit 66; }
	@test -x "$(MAC_DAEMON_LOADER)" || { echo "error: mac-daemon.sh is not executable" >&2; exit 66; }
	@test -x "$(LICENSE_COLLECTOR)" || { echo "error: collect-licenses.py is not executable" >&2; exit 66; }
	@grep -qF 'collect-licenses.py' "$(PROJECT)/project.pbxproj" \
		|| { echo "error: the Collect Licenses build phase is missing from the iGhostVT target — Settings ▸ About ▸ Licenses would be empty" >&2; exit 65; }
	@test -f "$(ROOT_DIR)/Licenses/ghostty/LICENSE" -a -f "$(ROOT_DIR)/Licenses/ghostty/notice.json" \
		|| { echo "error: Licenses/ghostty must carry Ghostty's LICENSE and notice.json — the XCFramework ships no license file" >&2; exit 66; }
	@for xcconfig in Version Base Development Release; do \
		test -f "$(CONFIG_DIR)/$$xcconfig.xcconfig" || { echo "error: Configuration/$$xcconfig.xcconfig is missing" >&2; exit 66; }; \
	done
	@[[ "$(APP_VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: MARKETING_VERSION must look like 1.2.3, got '$(APP_VERSION)'" >&2; exit 65; }
	@[[ "$(BUILD_NUMBER)" =~ ^[0-9]+$$ ]] || { echo "error: CURRENT_PROJECT_VERSION must be an integer, got '$(BUILD_NUMBER)'" >&2; exit 65; }
	@for script in postinst prerm postrm; do \
		sh -n "$(ROOT_DIR)/Packaging/DEBIAN/$$script" || { echo "error: Packaging/DEBIAN/$$script does not parse" >&2; exit 65; }; \
	done
	@! grep -nE '[A-Za-z0-9_@]2>' "$(ROOT_DIR)"/Packaging/DEBIAN/* \
		|| { echo "error: a redirect is glued to the word before it above — launchctl would be handed '<label>2' and its errors would show" >&2; exit 65; }
	@plutil -lint "$(ENTITLEMENTS)"
	@plutil -lint "$(DAEMON_ENTITLEMENTS)" "$(CLI_ENTITLEMENTS)" "$(APPEX_ENTITLEMENTS)" "$(LAUNCH_DAEMON)"
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :SoftResourceLimits:NumberOfFiles' "$(LAUNCH_DAEMON)")" == "10240" ]] || { echo "error: the daemon and its shells require a 10240 soft file-descriptor limit" >&2; exit 65; }
	@targets="$$(xcodebuild -project "$(PROJECT)" -list)"; \
		grep -F "ighostvtd" <<<"$$targets" >/dev/null || { echo "error: the ighostvtd target is missing from the project" >&2; exit 65; }; \
		grep -F "ighostvtd-io" <<<"$$targets" >/dev/null || { echo "error: the ighostvtd-io target is missing from the project" >&2; exit 65; }; \
		grep -F "ighostvt-cli" <<<"$$targets" >/dev/null || { echo "error: the ighostvt-cli target is missing from the project" >&2; exit 65; }
	@grep -qF 'wiki.qaq.ighostvt-cli' "$(ROOT_DIR)/iGhostVTDaemon/Server/PeerAuthenticator.swift" \
		&& grep -qF 'wiki.qaq.ighostvt-cli' "$(MAC_PACKAGER)" \
		|| { echo "error: the CLI's signing identifier must match in PeerAuthenticator.swift and package-mac.sh" >&2; exit 65; }
	@! grep -rnE '[A-Za-z0-9] \([A-Z0-9]{10}\)' "$(ROOT_DIR)/Scripts" "$(ROOT_DIR)/Makefile" "$(ROOT_DIR)/Packaging" \
		|| { echo "error: a signing identity ('Name (TEAMID)') is hardcoded above — identities come from the keychain or MAC_ZIP_IDENTITY/MAC_UPDATE_IDENTITY, never the repo" >&2; exit 65; }
	@test -f "$(XPC_SHIM_DIR)/module.modulemap" -a -f "$(XPC_SHIM_DIR)/shim.h" \
		|| { echo "error: Shared/XPCShim is missing — the XPC_TYPE_* macros are read through the CiGhostVTXPC module" >&2; exit 66; }
	@grep -qF 'SWIFT_INCLUDE_PATHS' "$(CONFIG_DIR)/Base.xcconfig" \
		|| { echo "error: Configuration/Base.xcconfig must add Shared/XPCShim to SWIFT_INCLUDE_PATHS" >&2; exit 65; }
	@floor="$$(sed -n 's/.*IPHONEOS_DEPLOYMENT_TARGET = \([0-9.]*\);.*/\1/p' "$(PROJECT)/project.pbxproj" | sort -V | head -1)"; \
	if (( $${floor%%.*} < 16 )); then \
		hits="$$(grep -rnE '\bXPC_(TYPE|ERROR|ARRAY_APPEND)[A-Z_0-9]*' --include='*.swift' \
			"$(ROOT_DIR)/iGhostVT" "$(ROOT_DIR)/iGhostVTDaemon" "$(ROOT_DIR)/iGhostVTDaemonShared" \
			"$(ROOT_DIR)/iGhostVTIO" "$(ROOT_DIR)/iGhostVTCLI" "$(ROOT_DIR)/iGhostVTWidgets" \
			"$(ROOT_DIR)/Shared" "$(ROOT_DIR)/Tests" || true)"; \
		if [[ -n "$$hits" ]]; then \
			echo "error: an SDK XPC macro is named in Swift below — that links /usr/lib/swift/libswiftXPC.dylib, which iOS $$floor does not have, and dyld kills the process at launch. Use iGhostVTXPC (Shared/Protocol/iGhostVTXPC.swift):" >&2; \
			echo "$$hits" >&2; \
			exit 65; \
		fi; \
	fi

# The app has no unit tests since the TCP transport left; the harness and
# the CLI renderer tests are the whole suite until it grows some again.
test: harness

# The daemon on the host, where launchd and the mach service are out of
# reach but everything else is real: `ighostvtd-io` is built and spawned as
# the proxy's child, the socket between them carries the protocol, and
# forkpty/execve, the read loop, exit decoding, and TIOCSWINSZ behave
# exactly as they do on device.
harness:
	@harness_dir="$$(mktemp -d /tmp/ighostvt-harness.XXXXXX)"; \
	trap 'rm -rf "$$harness_dir"' EXIT; \
	xcrun --sdk macosx swiftc -swift-version 5 -I "$(XPC_SHIM_DIR)" \
		"$(ROOT_DIR)/Shared/Protocol/iGhostVTProtocol.swift" \
		"$(ROOT_DIR)/Shared/Protocol/iGhostVTXPC.swift" \
		$$(find "$(ROOT_DIR)/iGhostVTDaemonShared" "$(ROOT_DIR)/iGhostVTIO" -name '*.swift' | sort) \
		-o "$$harness_dir/ighostvtd-io" && \
	xcrun --sdk macosx swiftc -swift-version 5 -DDEBUG -I "$(XPC_SHIM_DIR)" \
		"$(ROOT_DIR)/Shared/Protocol/iGhostVTProtocol.swift" \
		"$(ROOT_DIR)/Shared/Protocol/iGhostVTXPC.swift" \
		$$(find "$(ROOT_DIR)/iGhostVTDaemonShared" "$(ROOT_DIR)/iGhostVTIO" "$(ROOT_DIR)/iGhostVTDaemon" -name '*.swift' ! -name 'main.swift' | sort) \
		$$(find "$(ROOT_DIR)/Tests/PTYHarness" -name '*.swift' | sort) \
		-o "$$harness_dir/harness" && \
	IGHOSTVT_IO_BINARY="$$harness_dir/ighostvtd-io" "$$harness_dir/harness" && \
	xcrun --sdk macosx swiftc -swift-version 5 \
		"$(ROOT_DIR)/Shared/Protocol/iGhostVTProtocol.swift" \
		"$(ROOT_DIR)/Shared/Screen/ScreenRenderer.swift" \
		"$(ROOT_DIR)/Shared/Screen/KeyNames.swift" \
		$$(find "$(ROOT_DIR)/Tests/CLIRenderer" -name '*.swift' | sort) \
		-o "$$harness_dir/cli-renderer" && \
	"$$harness_dir/cli-renderer"

build: check test bump-build
	XCBUILD_LABEL=build-$(PLATFORM) $(DEVICE_XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "$(DEVICE_DESTINATION)" \
		build
	XCBUILD_LABEL=build-daemon-$(PLATFORM) $(DEVICE_XCODEBUILD) \
		-configuration "$(CONFIGURATION)" \
		-scheme "$(DAEMON_SCHEME)" \
		-destination "$(DEVICE_DESTINATION)" \
		build

deb: build
	"$(DEB_PACKAGER)" \
		"$(APP_BUNDLE)" \
		"$(DAEMON_BINARY)" \
		"$(DAEMON_IO_BINARY)" \
		"$(CLI_BINARY)" \
		"$(CONTROL_TEMPLATE)" \
		"$(ENTITLEMENTS)" \
		"$(DAEMON_ENTITLEMENTS)" \
		"$(CLI_ENTITLEMENTS)" \
		"$(APPEX_ENTITLEMENTS)" \
		"$(LAUNCH_DAEMON)" \
		"$(DEB_OUTPUT)" \
		"$(PACKAGE_ID)" \
		"$(APP_VERSION)" \
		"$(PACKAGE_ARCHITECTURE)" \
		"$(PACKAGE_PREFIX)" \
		"$(DEB_DEPENDS)"

# Both layouts share the build; only the packaging step differs, so these are
# the same recipe with the flavour switched.
deb-roothide:
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=roothide deb

deb-rootless:
	@$(MAKE) --no-print-directory PACKAGE_FLAVOR=rootless deb

# The visionOS build is a different set of binaries (Mach-O platform xros),
# so it has its own products directory and its own architecture label; the
# layout axis is the same as above.
deb-xros:
	@$(MAKE) --no-print-directory PLATFORM=xros PACKAGE_FLAVOR=roothide deb

deb-xros-rootless:
	@$(MAKE) --no-print-directory PLATFORM=xros PACKAGE_FLAVOR=rootless deb

# Mac Catalyst development harness: the whole stack off-device (AGENTS.md,
# "make mac-run"). The app is signed with *no* entitlements — a Catalyst app
# cannot carry the client one — so the daemon authenticates it by uid and
# bundle path, which only a Debug macOS daemon does; that is why the
# configuration is not a knob.
#
# Ad-hoc by default, since that is what every checkout can do. To sign as
# yourself, pass a Developer ID identity — it needs no provisioning profile,
# which an iOS-family binary would otherwise demand before macOS will launch
# it:
#
#   make mac-run MAC_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)"
MAC_CONFIGURATION   := Debug
MAC_SIGN_IDENTITY   ?= -
MAC_APP_BUNDLE      := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)-maccatalyst/iGhostVT.app
MAC_DAEMON_BINARY   := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)/ighostvtd
MAC_DAEMON_IO_BINARY := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)/ighostvtd-io
MAC_DAEMON_CLI_BINARY := $(DERIVED_DATA)/Build/Products/$(MAC_CONFIGURATION)/ighostvt-cli
MAC_LAUNCH_AGENT    := $(ROOT_DIR)/Packaging/macOS/wiki.qaq.ighostvtd.plist

mac-app:
	XCBUILD_LABEL=build-mac-app $(UNSIGNED_XCODEBUILD) \
		-configuration "$(MAC_CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "platform=macOS,variant=Mac Catalyst" \
		build
	@test -d "$(MAC_APP_BUNDLE)" || { echo "error: $(MAC_APP_BUNDLE) was not built" >&2; exit 66; }
	@# Nested code first (any embedded framework or bundle), then the app.
	@find "$(MAC_APP_BUNDLE)/Contents" -type d \( -name '*.framework' -o -name '*.appex' \) -print0 2>/dev/null \
		| xargs -0 -n1 -I{} codesign --force --sign "$(MAC_SIGN_IDENTITY)" --timestamp=none "{}"
	codesign --force --sign "$(MAC_SIGN_IDENTITY)" --timestamp=none "$(MAC_APP_BUNDLE)"
	@# A bundle rebuilt and re-signed in place can leave LaunchServices with
	@# a stale registration, and `open` then fails with "Launchd job spawn
	@# failed" while running the executable directly works. Re-register it.
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(MAC_APP_BUNDLE)"
	@echo "Built and signed $(MAC_APP_BUNDLE)"

mac-daemon:
	XCBUILD_LABEL=build-mac-daemon $(XCODEBUILD) \
		-configuration "$(MAC_CONFIGURATION)" \
		-scheme "$(DAEMON_SCHEME)" \
		-destination "platform=macOS" \
		build
	@test -x "$(MAC_DAEMON_IO_BINARY)" || { echo "error: $(MAC_DAEMON_IO_BINARY) was not built; ighostvtd spawns it from beside itself" >&2; exit 66; }
	@test -x "$(MAC_DAEMON_CLI_BINARY)" || { echo "error: $(MAC_DAEMON_CLI_BINARY) was not built; ighostvtd depends on it" >&2; exit 66; }
	"$(MAC_DAEMON_LOADER)" install "$(MAC_DAEMON_BINARY)" "$(MAC_LAUNCH_AGENT)"
	@echo "Command line: $(MAC_DAEMON_CLI_BINARY) list"

mac-daemon-uninstall:
	"$(MAC_DAEMON_LOADER)" uninstall

mac-run: mac-daemon mac-app
	open "$(MAC_APP_BUNDLE)"

# ---------------------------------------------------------------------------
# Distributable macOS build (`make mac-zip`)
#
# A different path from `make mac-run` on purpose. The harness above loads a
# DerivedData binary through a sidecar plist in ~/Library/LaunchAgents; this
# one produces a self-contained app that carries its helper inside the bundle
# and registers it with SMAppService on first launch. The two must never both
# be loaded — they share the label wiki.qaq.ighostvtd, and SMAppService answers
# kSMErrorInvalidSignature when it finds a job it does not own. Run
# `make mac-daemon-uninstall` before testing a zip.
#
# Signing is ad-hoc by default, which is what an unattended build (and every
# checkout without a certificate) can do. An ad-hoc bundle is not
# Gatekeeper-clean: whoever downloads it has to clear the quarantine bit once.
# To ship one that does not need that, pass a Developer ID and a notarytool
# keychain profile:
#
#   make mac-zip MAC_ZIP_IDENTITY="Developer ID Application: NAME (TEAMID)" \
#                MAC_NOTARY_PROFILE=ighostvt-notary
MAC_RELEASE_CONFIGURATION := Release
# Universal by default. libghostty-spm ships both slices, and an Intel Mac is
# still the machine a lot of people keep a terminal on.
MAC_ARCHS           ?= arm64 x86_64
MAC_ZIP_IDENTITY    ?= -
MAC_NOTARY_PROFILE  ?=
MAC_APP_ENTITLEMENTS    := $(ROOT_DIR)/Packaging/macOS/iGhostVT.entitlements
MAC_DAEMON_ENTITLEMENTS := $(ROOT_DIR)/Packaging/macOS/iGhostVTDaemon.entitlements
MAC_AGENT_PLIST     := $(ROOT_DIR)/Packaging/macOS/wiki.qaq.ighostvtd.agent.plist
MAC_ZIP_APP_BUNDLE  := $(DERIVED_DATA)/Build/Products/$(MAC_RELEASE_CONFIGURATION)-maccatalyst/iGhostVT.app
MAC_ZIP_DAEMON      := $(DERIVED_DATA)/Build/Products/$(MAC_RELEASE_CONFIGURATION)/ighostvtd
MAC_ZIP_DAEMON_IO   := $(DERIVED_DATA)/Build/Products/$(MAC_RELEASE_CONFIGURATION)/ighostvtd-io
MAC_ZIP_CLI         := $(DERIVED_DATA)/Build/Products/$(MAC_RELEASE_CONFIGURATION)/ighostvt-cli
MAC_ZIP_OUTPUT      ?= $(ROOT_DIR)/build/Packages/iGhostVT-$(APP_VERSION)-macos.zip

MAC_XCODEBUILD := $(UNSIGNED_XCODEBUILD) \
	ARCHS="$(MAC_ARCHS)" \
	ONLY_ACTIVE_ARCH=NO

# Deliberately *not* a dependency of `check`, and it does not depend on it
# either: `check` requires the jailbreak toolchain (ldid, dpkg-deb), and a Mac
# with nothing but Xcode has to be able to produce this zip.
mac-zip-check:
	@command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 69; }
	@command -v codesign >/dev/null || { echo "error: codesign is required" >&2; exit 69; }
	@command -v ditto >/dev/null || { echo "error: ditto is required" >&2; exit 69; }
	@test -x "$(MAC_PACKAGER)" || { echo "error: package-mac.sh is not executable" >&2; exit 66; }
	@plutil -lint "$(MAC_AGENT_PLIST)" "$(MAC_APP_ENTITLEMENTS)" "$(MAC_DAEMON_ENTITLEMENTS)"
	@# BundleProgram is how the agent finds the helper inside the bundle, and
	@# the label is what SMAppService and mac-daemon.sh both address.
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$(MAC_AGENT_PLIST)")" == "Contents/MacOS/ighostvtd" ]] \
		|| { echo "error: the bundled agent's BundleProgram must be Contents/MacOS/ighostvtd" >&2; exit 65; }
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :Label' "$(MAC_AGENT_PLIST)")" == "wiki.qaq.ighostvtd" ]] \
		|| { echo "error: the bundled agent's Label must be wiki.qaq.ighostvtd" >&2; exit 65; }
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :SoftResourceLimits:NumberOfFiles' "$(MAC_AGENT_PLIST)")" == "10240" ]] \
		|| { echo "error: the daemon and its shells require a 10240 soft file-descriptor limit" >&2; exit 65; }
	@# The app asks the helper to exit when it quits with nothing running
	@# (`shutdown`); a KeepAlive that restarts every exit would bring it
	@# straight back, and one that never restarts would leave a crash dead.
	@[[ "$$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$(MAC_AGENT_PLIST)")" == "false" ]] \
		|| { echo "error: the bundled agent's KeepAlive must be { SuccessfulExit = false }" >&2; exit 65; }
	@# The App Sandbox is unsupported here, not merely unused: Background Task
	@# Management refuses a sandboxed app's unsandboxed SMAppService job, and a
	@# sandboxed helper would hand its container to every shell it spawns.
	@for ent in "$(MAC_APP_ENTITLEMENTS)" "$(MAC_DAEMON_ENTITLEMENTS)"; do \
		if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$$ent" >/dev/null 2>&1; then \
			echo "error: $$ent declares com.apple.security.app-sandbox; the helper cannot be sandboxed" >&2; \
			exit 65; \
		fi; \
	done

mac-zip: mac-zip-check
	XCBUILD_LABEL=build-mac-zip-app $(MAC_XCODEBUILD) \
		-configuration "$(MAC_RELEASE_CONFIGURATION)" \
		-scheme "$(SCHEME)" \
		-destination "platform=macOS,variant=Mac Catalyst" \
		build
	XCBUILD_LABEL=build-mac-zip-daemon $(MAC_XCODEBUILD) \
		-configuration "$(MAC_RELEASE_CONFIGURATION)" \
		-scheme "$(DAEMON_SCHEME)" \
		-destination "platform=macOS" \
		build
	"$(MAC_PACKAGER)" \
		"$(MAC_ZIP_APP_BUNDLE)" \
		"$(MAC_ZIP_DAEMON)" \
		"$(MAC_ZIP_DAEMON_IO)" \
		"$(MAC_ZIP_CLI)" \
		"$(MAC_AGENT_PLIST)" \
		"$(MAC_APP_ENTITLEMENTS)" \
		"$(MAC_DAEMON_ENTITLEMENTS)" \
		"$(MAC_ZIP_OUTPUT)" \
		"$(APP_VERSION)" \
		"$(MAC_ZIP_IDENTITY)" \
		"$(MAC_NOTARY_PROFILE)"

# Install the GitHub Release macOS zip over /Applications/iGhostVT.app.
# TAG defaults to the latest release. Needs `gh` and sudo (Touch ID here).
# The script quits the running app, boots out wiki.qaq.ighostvtd — including
# a leftover `make mac-run` sidecar — then copies the new bundle without
# xattrs so SIP-protected provenance from the download does not follow it.
mac-update-from-github:
	@test -x "$(MAC_UPDATE_FROM_GITHUB)" || { echo "error: mac-update-from-github.sh is not executable" >&2; exit 66; }
	@"$(MAC_UPDATE_FROM_GITHUB)" $(TAG)

# The whole cut, end to end: version bump → commit → tag → the GitHub
# Release run → all six assets → the APT repository actually serving the
# version (the APT run's own conclusion is advisory — its verify step has
# raced the CDN cache). INSTALL=1 finishes by replacing
# /Applications/iGhostVT.app with the published zip (Touch ID).
release:
	@test -x "$(RELEASE_SH)" || { echo "error: release.sh is not executable" >&2; exit 66; }
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z [BUILD=n] [INSTALL=1]" >&2; exit 64; }
	@INSTALL="$(INSTALL)" "$(RELEASE_SH)" "$(VERSION)" $(BUILD)

clean:
	rm -rf "$(DERIVED_DATA)"
	rm -rf "$(ROOT_DIR)/build/Packages"
