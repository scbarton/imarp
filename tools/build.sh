#!/bin/bash
# Builds imarp for the iPad and for this Mac (as an iPad app, "Designed for
# iPad"), so the two never drift apart:
#
#   1. iPad: build (for any iPad, so the iPad itself isn't needed), then
#      install and launch it if the iPad is reachable (if it isn't, say so
#      and carry on).
#   2. Mac: build, wrap it the way macOS runs iPad apps (Xcode normally does
#      this step), and relaunch it from build/dd-mac/iMarp.app.
#
# Stops at the first build error. Options: --ipad-only, --mac-only.
#
# The iPad's device ID (from `xcrun devicectl list devices`) is read from
# tools/ipad-id, which is git-ignored so it stays out of the public repo, or
# from the IMARP_IPAD_ID environment variable.
set -uo pipefail

cd "$(dirname "$0")/.."
IPAD_ID="${IMARP_IPAD_ID:-$(tr -d '[:space:]' < tools/ipad-id 2>/dev/null)}"
BUNDLE_ID="org.powrbox.imarp"
do_ipad=1; do_mac=1
case "${1:-}" in
    --ipad-only) do_mac=0 ;;
    --mac-only) do_ipad=0 ;;
    "") ;;
    *) echo "usage: $0 [--ipad-only|--mac-only]" >&2; exit 2 ;;
esac

build() { # destination, derived data path
    local log
    log=$(xcodebuild -scheme imarp -destination "$1" -derivedDataPath "$2" -allowProvisioningUpdates -quiet build 2>&1)
    if echo "$log" | grep -q "error:"; then
        echo "$log" | grep "error:" >&2
        return 1
    fi
}

if [ $do_ipad = 1 ]; then
    echo "iPad: building..."
    build "generic/platform=iOS" build/dd || { echo "iPad build failed" >&2; exit 1; }
    state=""
    if [ -n "$IPAD_ID" ]; then
        state=$(xcrun devicectl list devices 2>/dev/null | grep "$IPAD_ID" | awk '{for (i=1; i<=NF; i++) if ($i ~ /^(connected|available|unavailable)$/) print $i}')
    fi
    if [ -z "$IPAD_ID" ]; then
        echo "iPad: built, not installed (no device ID: put it in tools/ipad-id; see xcrun devicectl list devices)"
    elif [ "$state" = "unavailable" ] || [ -z "$state" ]; then
        echo "iPad: built, but the iPad isn't reachable (unlock it or replug the cable), not installed"
    else
        if ! xcrun devicectl device install app --device "$IPAD_ID" build/dd/Build/Products/Debug-iphoneos/imarp.app >/dev/null 2>&1; then
            echo "iPad: built, but the install failed (unlock it or replug the cable)"
        elif xcrun devicectl device process launch --device "$IPAD_ID" --terminate-existing "$BUNDLE_ID" >/dev/null 2>&1; then
            echo "iPad: installed and launched"
        else
            echo "iPad: installed, but not launched (is it locked?)"
        fi
    fi
fi

if [ $do_mac = 1 ]; then
    echo "Mac: building..."
    build "platform=macOS,arch=arm64,variant=Designed for iPad" build/dd-mac || { echo "Mac build failed" >&2; exit 1; }
    pkill -f "Wrapper/imarp.app/imarp" 2>/dev/null
    wrapper=build/dd-mac/iMarp.app
    rm -rf "$wrapper"
    mkdir -p "$wrapper/Wrapper"
    cp -R build/dd-mac/Build/Products/Debug-iphoneos/imarp.app "$wrapper/Wrapper/"
    ln -s Wrapper/imarp.app "$wrapper/WrappedBundle"
    open "$wrapper" && echo "Mac: launched $wrapper"
fi
