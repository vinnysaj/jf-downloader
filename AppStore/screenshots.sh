#!/bin/bash
# Makes vinnyfin's App Store screenshots and marketing images in AppStore/Output:
#   App Store/   framed and captioned, at the sizes App Store Connect takes, one folder per slot
#   Raw/         the captures they're made from, one folder per device
# The app browses a showcase Jellyfin server this runs in Docker, with a library of original
# titles drawn by Showcase.swift, so nothing on screen belongs to anyone else. The simulators are
# its own, created on first use, with the status bar at 9:41 and full signal and battery.
#
# Usage: AppStore/screenshots.sh [iphone] [ipad] [duo] [tv] [mac] [marketing]   (default: all)
# Needs Xcode, Docker (Colima works), ffmpeg, and agent-device to fold the iPhone Duo.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
output="$here/Output"
server="$output/Server"
raw="$output/Raw"
build="$output/Build"
port=8099
address="http://localhost:$port"
sets=("$@")
[ ${#sets[@]} -gt 0 ] || sets=(iphone ipad duo tv mac marketing)

wants() { [[ " ${sets[*]} " == *" $1 "* ]]; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

for tool in xcodebuild docker ffmpeg swift python3; do
  command -v "$tool" >/dev/null || fail "$tool isn't installed."
done
if wants duo; then command -v agent-device >/dev/null || fail "agent-device isn't installed; it folds the iPhone Duo."; fi
docker info >/dev/null 2>&1 || fail "Docker isn't running (with Colima: colima start)."

# MARK: The showcase server

say "Drawing the showcase library"
swift "$here/Showcase.swift" "$server/media"

say "Starting the showcase server at $address"
mkdir -p "$server/config" "$server/cache"
if ! docker container inspect vinnyfin-showcase >/dev/null 2>&1; then
  docker run -d --name vinnyfin-showcase -p "$port:8096" \
    -v "$server/config:/config" -v "$server/cache:/cache" -v "$server/media:/media:ro" \
    jellyfin/jellyfin:latest >/dev/null
elif [ "$(docker container inspect -f '{{.State.Running}}' vinnyfin-showcase)" != true ]; then
  docker start vinnyfin-showcase >/dev/null
fi
# While starting, Jellyfin answers with a loading page instead of the JSON.
until curl -sf "$address/System/Info/Public" | grep -q StartupWizardCompleted; do sleep 2; done

client='MediaBrowser Client="vinnyfin screenshots", Device="Mac", DeviceId="vinnyfin-screenshots", Version="1"'
api() { # method, path, [json body]
  curl -sf -X "$1" -H "Content-Type: application/json" -H "Authorization: $client${token:+, Token=\"$token\"}" \
    "$address$2" -d "${3:-{\}}"
}
json() { python3 -c "import sys, json; print($1)"; }
token=""
if curl -sf "$address/System/Info/Public" | grep -q '"StartupWizardCompleted":false'; then
  api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
  api GET /Startup/User >/dev/null
  api POST /Startup/User '{"Name":"showcase","Password":"showcase"}' >/dev/null
  api POST /Startup/Complete >/dev/null
fi
token=$(api POST /Users/AuthenticateByName '{"Username":"showcase","Pw":"showcase"}' | json 'json.load(sys.stdin)["AccessToken"]')
if ! api GET /Library/VirtualFolders | grep -q '"Name":"Movies"'; then
  # The NFOs lock the metadata against online lookups; nothing else needs extracting.
  options='{"LibraryOptions":{"EnableRealtimeMonitor":false,"EnableTrickplayImageExtraction":false,"ExtractTrickplayImagesDuringLibraryScan":false,"EnableChapterImageExtraction":false,"ExtractChapterImagesDuringLibraryScan":false}}'
  api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fmedia%2Fmovies&refreshLibrary=false" "$options" >/dev/null
  api POST "/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=%2Fmedia%2Ftv&refreshLibrary=false" "$options" >/dev/null
  # The one the app signs in as: no password, so no Save Password sheet.
  api POST /Users/New '{"Name":"Alex","Password":""}' >/dev/null
fi
api POST /Library/Refresh >/dev/null
scan_idle() {
  api GET /ScheduledTasks | json '"".join(t["State"] for t in json.load(sys.stdin) if t["Key"] == "RefreshLibrary")'
}
sleep 2
until [ "$(scan_idle)" = Idle ]; do sleep 2; done
count=$(api GET "/Items?recursive=true&includeItemTypes=Movie,Episode" | json 'json.load(sys.stdin)["TotalRecordCount"]')
echo "Library scanned: $count movies and episodes"

# MARK: Devices

# The screenshot simulator for a device type, created on first use and booted.
simulator() {
  local name="vinnyfin screenshots: $1" udid
  udid=$(xcrun simctl list devices -j | json "next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name'] == '$name' and d['isAvailable']), '')")
  [ -n "$udid" ] || udid=$(xcrun simctl create "$name" "$1")
  xcrun simctl bootstatus "$udid" -b >/dev/null
  echo "$udid"
}

# A fresh install, dark, with the status bar Apple shows in its own marketing (Apple TV has none).
prepare() {
  local udid=$1 kind=${2:-phone}
  xcrun simctl ui "$udid" appearance dark
  xcrun simctl uninstall "$udid" com.vinnysaj.vinnyfin
  [ "$kind" = tv ] && return
  xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState discharging --batteryLevel 100
}

built=()
# Builds the app and its UI tests for the platform `destination` is on, once.
build_for() {
  local platform=$1 destination=$2
  [[ " ${built[*]-} " == *" $platform "* ]] && return
  say "Building for $platform"
  xcodebuild build-for-testing -project "$root/Vinnyfin.xcodeproj" -scheme Vinnyfin -destination "$destination" \
    -derivedDataPath "$build" -quiet
  built+=("$platform")
}

# Runs one screenshot test and saves its attachments as Raw/<folder>/<name>.png.
shoot() {
  local folder=$1 test=$2 destination=$3 results="$output/Results/$1.xcresult"
  say "Shooting $folder"
  rm -rf "$results" "$raw/$folder" "$output/Results/$folder"
  mkdir -p "$raw/$folder" "$output/Results"
  # xcodebuild hands the test runner its TEST_RUNNER_ variables, without the prefix.
  TEST_RUNNER_VINNYFIN_SCREENSHOT_SERVER="$address" \
    xcodebuild test-without-building -project "$root/Vinnyfin.xcodeproj" -scheme Vinnyfin -destination "$destination" \
    -derivedDataPath "$build" -resultBundlePath "$results" -only-testing:"VinnyfinUITests/ScreenshotTests/$test" -quiet \
    || fail "The $test screenshots failed; the run is in $results"
  xcrun xcresulttool export attachments --path "$results" --output-path "$output/Results/$folder" >/dev/null
  python3 - "$output/Results/$folder" "$raw/$folder" <<'PY'
import json, re, shutil, sys
exported, destination = sys.argv[1:]
for test in json.load(open(f"{exported}/manifest.json")):
    for attachment in test["attachments"]:
        # Named "01-home", exported as "01-home_0_<UUID>.png", among XCTest's own attachments.
        match = re.fullmatch(r"(\d\d-[a-z-]+)_\d+_[0-9A-F-]{36}\.png", attachment["suggestedHumanReadableName"])
        if match:
            shutil.copy(f"{exported}/{attachment['exportedFileName']}", f"{destination}/{match[1]}.png")
            print(f"  {match[1]}")
PY
}

ios_device() { # folder, device type, test
  local udid
  udid=$(simulator "$2")
  prepare "$udid"
  build_for iOS "id=$udid"
  shoot "$1" "$3" "id=$udid"
}

if wants iphone; then
  ios_device "iPhone 6.9-inch" "iPhone 18 Pro Max" testIPhone
  ios_device "iPhone 6.3-inch" "iPhone 18 Pro" testIPhone
fi
if wants ipad; then
  ios_device "iPad 13-inch" "iPad Pro 13-inch (M5)" testIPad
fi
if wants duo; then
  duo=$(simulator "iPhone Duo")
  prepare "$duo"
  build_for iOS "id=$duo"
  # Its own agent-device session, so one bound to another simulator doesn't get in the way.
  agent-device open --session vinnyfin-screenshots --platform ios --udid "$duo" >/dev/null
  fold() { agent-device fold "$1" --session vinnyfin-screenshots >/dev/null; }
  fold closed
  shoot "iPhone Duo outer" testDuoOuter "id=$duo"
  fold open
  shoot "iPhone Duo inner" testDuoInner "id=$duo"
  fold half-open
  shoot "iPhone Duo half open" testDuoLaptop "id=$duo"
  fold open
  agent-device close --session vinnyfin-screenshots >/dev/null
fi
if wants tv; then
  tv=$(simulator "Apple TV 4K (4th generation)")
  prepare "$tv" tv
  build_for tvOS "id=$tv"
  shoot "Apple TV" testTV "id=$tv"
fi
if wants mac; then
  if automationmodetool | grep -q "requires user authentication"; then
    fail "UI tests on the Mac need Automation Mode. Allow it once with:
  sudo automationmodetool enable-automationmode-without-authentication"
  fi
  build_for macOS "platform=macOS"
  shoot "Mac" testMac "platform=macOS"
fi

# MARK: Framing

say "Framing"
swift "$here/Compose.swift" "$raw" "$output/App Store" "$server/media" "${sets[@]}"
say "Done: $output/App Store"
