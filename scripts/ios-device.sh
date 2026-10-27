#!/bin/bash
# Build, install and launch the iOS app on a real iPhone or iPad.
#
#   scripts/ios-device.sh list                      devices this Mac knows
#   scripts/ios-device.sh build   [-d DEVICE]       build for a device (or any iOS device)
#   scripts/ios-device.sh install [-d DEVICE]       install the last build (closes the app there)
#   scripts/ios-device.sh run     [-d DEVICE]       build, install and launch
#   scripts/ios-device.sh launch  [-d DEVICE]       launch the installed app
#   scripts/ios-device.sh logs    [-d DEVICE]       launch it and stream its log (Ctrl-C to stop)
#   scripts/ios-device.sh uninstall [-d DEVICE]     remove the app (its logins and settings go too)
#
# DEVICE is a name, a name fragment ("iPad"), or an identifier; IOS_DEVICE in the
# environment does the same. With no device, the only connected one is used.
#
# Building FOR a device (not just "any iOS device") lets Xcode register a new iPad with the
# developer account and add it to the provisioning profile, which `-allowProvisioningUpdates`
# does on the first build. The device must be unlocked, plugged in or on the same network,
# with Developer Mode on (Settings > Privacy & Security > Developer Mode).
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID=io.github.raff.tvview.swift
SCHEME=TVView-iOS
DERIVED=swift/build
APP="$DERIVED/Build/Products/Debug-iphoneos/TV View.app"

die() { echo "ios-device: $*" >&2; exit 1; }

usage() { sed -n '2,/^set -e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

devices_json() {
    local f; f=$(mktemp)
    xcrun devicectl list devices --json-output "$f" >/dev/null 2>&1 || die "devicectl failed (is Xcode installed and selected?)"
    cat "$f"; rm -f "$f"
}

# Prints "identifier<TAB>udid<TAB>name<TAB>model<TAB>state" per device.
device_rows() {
    devices_json | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    hw, dp, cp = d["hardwareProperties"], d["deviceProperties"], d["connectionProperties"]
    if hw.get("platform") not in ("iOS", "iPadOS"):
        continue
    state = cp.get("tunnelState", "?")
    print("\t".join([d["identifier"], hw.get("udid", ""), dp["name"], hw.get("marketingName", hw.get("deviceType", "")), state]))
'
}

cmd_list() {
    printf '%-38s %-26s %-18s %s\n' IDENTIFIER NAME MODEL STATE
    device_rows | while IFS=$'\t' read -r id udid name model state; do
        printf '%-38s %-26s %-18s %s\n' "$id" "$name" "$model" "$state"
    done
}

# Sets DEV_ID, DEV_UDID and DEV_NAME from $DEVICE (or the only device there is).
pick_device() {
    local want="${DEVICE:-${IOS_DEVICE:-}}" rows
    rows=$(device_rows)
    [ -n "$rows" ] || die "no iPhone or iPad known to this Mac: connect it, unlock it, trust this computer"
    if [ -n "$want" ]; then
        rows=$(echo "$rows" | awk -F'\t' -v w="$(echo "$want" | tr 'A-Z' 'a-z')" 'index(tolower($0), w)')
        [ -n "$rows" ] || die "no device matches '$want' (try: $0 list)"
    else
        # Prefer the ones that are reachable now.
        local live; live=$(echo "$rows" | awk -F'\t' '$5 != "unavailable" && $5 != "disconnected"')
        [ -n "$live" ] && rows=$live
    fi
    [ "$(echo "$rows" | wc -l)" -eq 1 ] || { echo "More than one device; pick one with -d:" >&2; cmd_list >&2; exit 1; }
    IFS=$'\t' read -r DEV_ID DEV_UDID DEV_NAME _ _ <<<"$rows"
}

cmd_build() {
    local dest='generic/platform=iOS'
    if [ -n "${DEVICE:-${IOS_DEVICE:-}}" ] || [ "${1:-}" = "for-device" ]; then
        pick_device
        dest="id=$DEV_UDID"
        echo "Building for $DEV_NAME ($DEV_UDID)"
    else
        echo "Building for any iOS device (pass -d to build for one, needed the first time for a new device)"
    fi
    make swift-gen
    xcodebuild -project swift/TVView.xcodeproj -scheme "$SCHEME" -configuration Debug \
        -derivedDataPath "$DERIVED" -destination "$dest" -allowProvisioningUpdates build \
        | grep -E "error:|warning: .*provisioning|\*\* BUILD" || true
    [ -d "$APP" ] || die "build failed: $APP is missing (run again without the grep: xcodebuild ... build)"
}

cmd_install() {
    [ -d "$APP" ] || die "nothing built yet: $0 build"
    pick_device
    echo "Installing on $DEV_NAME (this closes the app there)"
    xcrun devicectl device install app --device "$DEV_ID" "$APP"
}

cmd_launch() {
    pick_device
    echo "Launching on $DEV_NAME (it must be unlocked)"
    xcrun devicectl device process launch --device "$DEV_ID" --terminate-existing "$BUNDLE_ID"
}

cmd_logs() {
    pick_device
    echo "Launching on $DEV_NAME with its log here (Ctrl-C to stop; the app stops with it)"
    xcrun devicectl device process launch --device "$DEV_ID" --terminate-existing --console "$BUNDLE_ID"
}

cmd_uninstall() {
    pick_device
    xcrun devicectl device uninstall app --device "$DEV_ID" "$BUNDLE_ID"
}

[ $# -ge 1 ] || { usage; exit 1; }
CMD=$1; shift
DEVICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d|--device) DEVICE=${2:?-d needs a device}; shift 2 ;;
        *) die "unknown argument '$1'" ;;
    esac
done

case "$CMD" in
    list) cmd_list ;;
    build) cmd_build ;;
    install) cmd_install ;;
    launch) cmd_launch ;;
    logs) cmd_logs ;;
    uninstall) cmd_uninstall ;;
    run) cmd_build for-device; cmd_install; cmd_launch ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
esac
