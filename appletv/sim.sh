#!/bin/bash
# Drive the app in the tvOS simulator: ./sim.sh build | launch | shot [name] | key <up|down|left|right|select|menu|play> [n] | type "text" | log
set -e
cd "$(dirname "$0")"
SIM="Apple TV 4K (3rd generation) (at 1080p)"
BUNDLE=com.nirajgtm.xtreamtv.tv
SHOTS=/private/tmp/claude-501/-Users-nirajgautam/6b6366a3-2338-4a37-b3b5-a181e4f8cceb/scratchpad/shots
mkdir -p "$SHOTS"
case "$1" in
  build)
    xcodegen generate --quiet; xcrun simctl boot "$SIM" 2>/dev/null || true
    open -a Simulator >/dev/null 2>&1 || true
    xcodebuild -project StreamEverything.xcodeproj -scheme StreamEverything -configuration Release \
      -destination "platform=tvOS Simulator,name=$SIM" -derivedDataPath build-sim \
      CODE_SIGNING_ALLOWED=NO -quiet build 2>&1 | grep -E "error:" | head -20 || true
    xcrun simctl install "$SIM" build-sim/Build/Products/Release-appletvsimulator/StreamEverything.app ;;
  launch)
    xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null || true
    shift; xcrun simctl launch --console-pty "$SIM" $BUNDLE "$@" > "$SHOTS/app.log" 2>&1 &
    sleep 1; echo launched ;;
  shot)
    sleep "${3:-0.8}"; xcrun simctl io "$SIM" screenshot --type=png "$SHOTS/${2:-shot}.png" >/dev/null 2>&1; echo "$SHOTS/${2:-shot}.png" ;;
  key)
    case "$2" in up) k=126;; down) k=125;; left) k=123;; right) k=124;; select) k=36;; menu) k=53;; play) k=49;; *) echo "bad key"; exit 1;; esac
    n="${3:-1}"; for i in $(seq 1 "$n"); do osascript -e "tell application \"Simulator\" to activate" -e "tell application \"System Events\" to key code $k" >/dev/null; sleep 0.35; done ;;
  type)
    osascript -e "tell application \"Simulator\" to activate" -e "tell application \"System Events\" to keystroke \"$2\"" >/dev/null ;;
  log) tail -n "${2:-40}" "$SHOTS/app.log" ;;
esac
# usage: ./sim.sh syslog [minutes]  -> app NSLog lines from the unified log
if [ "$1" = "syslog" ]; then
  xcrun simctl spawn "$SIM" log show --last "${2:-2}m" --predicate 'process == "StreamEverything" AND (eventMessage CONTAINS "PLAYER" OR eventMessage CONTAINS "XtreamPerf" OR eventMessage CONTAINS "UI ")' --style compact 2>/dev/null | grep -v "^Timestamp" | cut -c1-200
fi
