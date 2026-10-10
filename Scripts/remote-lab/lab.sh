#!/usr/bin/env bash
# Remote access over a bad network, on one Mac: the host is this Mac's own
# iGhostVT (its `ighostvtd-remote`, registered with the relay the app was
# given), the device is `Tests/RemoteLab` — a paired client with no window —
# or GhostRemote in a simulator, and between the device and the relay sits
# `netem-proxy.py`, which delays, throttles and blacks out the path.
#
#   lab.sh build                  compile the client into $LAB
#   lab.sh pair                   pair it with this Mac (once; kept in $LAB)
#   lab.sh proxy PROFILE [opts]   (re)start the proxy toward the relay
#   lab.sh sz PROFILE [MiB] [opts] receive a random file with sz through it
#                                 (REORDER=N swaps N pairs of output chunks)
#   lab.sh matrix [MiB]           sz under every profile, one line each
#   lab.sh scenario NAME PROFILE [SIZE] [opts]
#                                 trickle idle echo flood paste reattach storm upload
#   lab.sh suite                  every scenario under several profiles
#   lab.sh sim-relay              a .vtrpsc for a simulator, pointing at the proxy
#   lab.sh sim UDID [APP]         install a Debug GhostRemote there, paired and
#                                 sent through the proxy (start one with `proxy`)
#   lab.sh stop                   stop the proxy
#   lab.sh unpair                 revoke every lab device on this Mac and forget it
#
# Profiles are netem-proxy.py's: clean wifi cellular awful flapping tunnel
# deadzone.
# The relay is the one in the Mac app's own file; its key never leaves $LAB
# (0700), and nothing here writes into the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAB="${REMOTE_LAB_DIR:-/private/tmp/ighostvt-remote-lab}"
CLI="${IGHOSTVT_CLI:-/Applications/iGhostVT.app/Contents/MacOS/ighostvt-cli}"
RELAY_FILE="${RELAY_FILE:-$HOME/Library/Application Support/iGhostVT/Relay.vtrpsc}"
PROXY_PORT="${PROXY_PORT:-46499}"
SZ="${SZ:-$(command -v sz || echo /opt/homebrew/bin/sz)}"
VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/Configuration/Version.xcconfig")"

mkdir -p "$LAB"
chmod 700 "$LAB"

relay_endpoint() {
    python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["endpoint"])' "$RELAY_FILE"
}

build() {
    xcrun --sdk macosx swiftc -swift-version 5 -O \
        -I "$ROOT/Shared/XPCShim" -I "$ROOT/Shared/CoreCryptoShim" \
        "$ROOT/Shared/Protocol/iGhostVTProtocol.swift" \
        "$ROOT/Shared/Protocol/iGhostVTXPC.swift" \
        $(find "$ROOT/Shared/Wire" "$ROOT/Shared/Remote" "$ROOT/Tests/RemoteLab" -name '*.swift' | sort) \
        "$ROOT/iGhostVT/Backend/Zmodem/ZmodemCRC.swift" \
        "$ROOT/iGhostVT/Backend/Zmodem/ZmodemFrame.swift" \
        "$ROOT/iGhostVT/Backend/Zmodem/ZmodemTransfer.swift" \
        "$ROOT/iGhostVT/Backend/Zmodem/ZmodemEngine.swift" \
        -o "$LAB/remote-lab"
    echo "$LAB/remote-lab"
}

ensure_built() {
    [[ -x "$LAB/remote-lab" ]] || build >/dev/null
}

host_id() {
    "$CLI" remote status | sed -n 's/^host id: *//p'
}

pair() {
    ensure_built
    local id code
    id="$(host_id)"
    [[ -n "$id" ]] || { echo "error: remote access is off on this Mac ($CLI remote on)" >&2; exit 69; }
    code="$("$CLI" remote pair 2>/dev/null | head -1)"
    "$LAB/remote-lab" pair --state "$LAB" --host-id "$id" --address "127.0.0.1:46404" \
        --code "$code" --version "$VERSION" --name "Remote Lab"
    "$CLI" remote pair --end >/dev/null 2>&1 || true
}

stop_proxy() {
    if [[ -f "$LAB/proxy.pid" ]]; then
        kill "$(cat "$LAB/proxy.pid")" 2>/dev/null || true
        rm -f "$LAB/proxy.pid"
    fi
}

start_proxy() {
    local profile="$1"
    shift
    stop_proxy
    python3 -I "$ROOT/Scripts/remote-lab/netem-proxy.py" --listen "127.0.0.1:$PROXY_PORT" \
        --target "$(relay_endpoint)" --profile "$profile" "$@" >>"$LAB/proxy.log" 2>&1 &
    echo $! >"$LAB/proxy.pid"
    for _ in $(seq 50); do
        nc -z 127.0.0.1 "$PROXY_PORT" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "error: the proxy did not start; see $LAB/proxy.log" >&2
    exit 70
}

test_file() {
    local mib="$1" file="$LAB/payload-${1}m.bin"
    [[ -f "$file" ]] || head -c "$((mib * 1024 * 1024))" /dev/urandom >"$file"
    echo "$file"
}

run_sz() {
    local profile="$1" mib="${2:-8}"
    shift 2 || shift $#
    ensure_built
    [[ -f "$LAB/device.json" ]] || pair >/dev/null
    start_proxy "$profile" "$@"
    local status=0
    "$LAB/remote-lab" sz --state "$LAB" --relay "$RELAY_FILE" --via "127.0.0.1:$PROXY_PORT" \
        --file "$(test_file "$mib")" --sz "$SZ" --version "$VERSION" \
        ${REORDER:+--reorder "$REORDER"} || status=$?
    stop_proxy
    return "$status"
}

run_scenario() {
    local name="$1" profile="${2:-clean}" size="${3:-0}"
    shift 3 || shift $#
    ensure_built
    [[ -f "$LAB/device.json" ]] || pair >/dev/null
    start_proxy "$profile" "$@"
    local status=0
    "$LAB/remote-lab" scenario --name "$name" --size "$size" --state "$LAB" --relay "$RELAY_FILE" \
        --via "127.0.0.1:$PROXY_PORT" --version "$VERSION" || status=$?
    stop_proxy
    return "$status"
}

case "${1:-}" in
build) build ;;
scenario)
    shift
    run_scenario "$@"
    ;;
suite)
    # Every scenario under every profile named (default: a spread), one
    # line each; logs in $LAB/suite-<scenario>-<profile>.log.
    for profile in ${PROFILES:-clean cellular flapping awful}; do
        for name in ${SCENARIOS:-trickle echo flood paste reattach storm upload}; do
            log="$LAB/suite-$name-$profile.log"
            if run_scenario "$name" "$profile" 0 >"$log" 2>&1; then verdict=ok; else verdict=FAILED; fi
            printf '%-9s %-9s %-7s %s\n' "$name" "$profile" "$verdict" \
                "$(grep -E '^  (FAIL|ok)' "$log" | grep -m1 FAIL | sed 's/^ *//')"
        done
    done
    ;;
pair) pair ;;
proxy)
    shift
    start_proxy "${1:-clean}" "${@:2}"
    echo "proxy on 127.0.0.1:$PROXY_PORT -> $(relay_endpoint), log $LAB/proxy.log"
    ;;
stop) stop_proxy ;;
sz)
    shift
    run_sz "$@"
    ;;
matrix)
    mib="${2:-8}"
    for profile in ${PROFILES:-clean wifi cellular flapping tunnel deadzone awful}; do
        log="$LAB/sz-$profile.log"
        if run_sz "$profile" "$mib" >"$log" 2>&1; then verdict=ok; else verdict=FAILED; fi
        printf '%-9s %-7s %s\n' "$profile" "$verdict" "$(grep -E '^  received' "$log" | sed 's/^ *//')"
    done
    ;;
sim-relay)
    out="$LAB/lab-relay.vtrpsc"
    python3 -I -c '
import json, sys
config = json.load(open(sys.argv[1]))
config["endpoint"] = "127.0.0.1:" + sys.argv[2]
config["name"] = "Lab (" + config.get("name", "relay") + ")"
json.dump(config, open(sys.argv[3], "w"))
' "$RELAY_FILE" "$PROXY_PORT" "$out"
    chmod 600 "$out"
    echo "$out"
    ;;
sim)
    # A Debug GhostRemote in a booted simulator, paired with this Mac as a
    # device of its own and sent through the proxy only: its relay file
    # points at the proxy, and `RemoteLab.relayOnly` (Debug builds) keeps
    # it off the direct path Bonjour would otherwise always find here.
    udid="${2:?usage: lab.sh sim UDID [GhostRemote.app]}"
    app="${3:-/private/tmp/ighostvt-deriveddata/Build/Products/Debug-iphonesimulator/GhostRemote.app}"
    bundle=wiki.qaq.GhostRemote
    ensure_built
    xcrun simctl install "$udid" "$app"
    state="$LAB/sim-$udid"
    if [[ ! -f "$state/device.json" ]]; then
        id="$(host_id)"
        code="$("$CLI" remote pair 2>/dev/null | head -1)"
        "$LAB/remote-lab" pair --state "$state" --host-id "$id" --address "127.0.0.1:46404" \
            --code "$code" --version "$VERSION" --name "Lab Simulator ${udid:0:4}" >/dev/null
        "$CLI" remote pair --end >/dev/null 2>&1 || true
    fi
    container="$(xcrun simctl get_app_container "$udid" "$bundle" data)"
    support="$container/Library/Application Support"
    mkdir -p "$support"
    python3 -I -c '
import json, sys, time
device = json.load(open(sys.argv[1]))
now = time.time() - 978307200  # JSONEncoder dates: seconds since 2001
hosts = [{
    "id": device["hostID"], "name": device["hostName"],
    "deviceID": device["deviceID"], "deviceKey": device["deviceKey"],
    "pairedAt": now, "lastSeen": now,
}]
json.dump(hosts, open(sys.argv[2], "w"))
' "$state/device.json" "$support/RemoteHosts.json"
    cp "$("$0" sim-relay)" "$support/Relay.vtrpsc"
    chmod 600 "$support/RemoteHosts.json" "$support/Relay.vtrpsc"
    xcrun simctl spawn "$udid" defaults write "$bundle" RemoteLab.relayOnly -bool YES
    xcrun simctl spawn "$udid" defaults write "$bundle" Transfer.zmodemEnabled -bool YES
    xcrun simctl spawn "$udid" defaults write "$bundle" Debug.verboseTerminalLog -bool YES
    xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" "$bundle"
    echo "journal: $container/Documents (Journal under the bundle id folder, or Library/Logs)"
    ;;
unpair)
    for state in "$LAB" "$LAB"/sim-*; do
        [[ -f "$state/device.json" ]] || continue
        id="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["deviceID"])' "$state/device.json")"
        "$CLI" remote revoke "$id" || true
        rm -f "$state/device.json"
    done
    ;;
*)
    sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
