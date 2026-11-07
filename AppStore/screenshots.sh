#!/bin/bash
# Makes vinnyfin's App Store screenshots and marketing images in AppStore/Screenshots, framed and
# captioned at the sizes App Store Connect takes, one folder per slot. What it takes to make them
# stays out of the repo, in AppStore/Output: the captures in Raw/, one folder per device, the
# showcase server, the builds and the test results.
# The app browses a showcase Jellyfin server this runs in Docker, with a library of original
# titles drawn by Showcase.swift, so nothing on screen belongs to anyone else. The simulators are
# its own, created on first use, with the status bar at 9:41 and full signal and battery.
#
# Usage: AppStore/screenshots.sh [iphone] [ipad] [duo] [tv] [vision] [mac] [marketing]   (default: all)
# Needs Xcode, Docker (Colima works), ffmpeg, and agent-device to fold the iPhone Duo.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
output="$here/Output"
server="$output/Server"
raw="$output/Raw"
build="$output/Build"
sets=("$@")
[ ${#sets[@]} -gt 0 ] || sets=(iphone ipad duo tv vision mac marketing)

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

json() { python3 -c "import sys, json; print($1)"; }

say "Starting the showcase server"
mkdir -p "$server/config" "$server/cache"
# The server is whichever container serves this checkout's Server folder, so another checkout's,
# with the library it drew, is never used. A new one goes on a port Docker picks.
container=""
containers=$(docker ps -aq)
if [ -n "$containers" ]; then
  # shellcheck disable=SC2086 # One argument per container.
  container=$(docker container inspect $containers |
    json "next((c['Id'] for c in json.load(sys.stdin) if any(m['Source'] == '$server/config' for m in c['Mounts'])), '')")
fi
if [ -z "$container" ]; then
  container=$(docker run -d --name "vinnyfin-showcase-$(basename "$root")" -p 127.0.0.1::8096 \
    -v "$server/config:/config" -v "$server/cache:/cache" -v "$server/media:/media:ro" \
    jellyfin/jellyfin:latest)
elif [ "$(docker container inspect -f '{{.State.Running}}' "$container")" != true ]; then
  docker start "$container" >/dev/null
fi
published=$(docker port "$container" 8096/tcp | head -1)
address="http://localhost:${published##*:}"
echo "$(docker container inspect -f '{{.Name}}' "$container" | tr -d /) at $address"
# While starting, Jellyfin answers with a loading page instead of the JSON.
until curl -sf "$address/System/Info/Public" | grep -q StartupWizardCompleted; do sleep 2; done

client='MediaBrowser Client="vinnyfin screenshots", Device="Mac", DeviceId="vinnyfin-screenshots", Version="1"'
api() { # method, path, [json body]
  curl -sf -X "$1" -H "Content-Type: application/json" -H "Authorization: $client${token:+, Token=\"$token\"}" \
    "$address$2" -d "${3:-{\}}"
}
token=""
if curl -sf "$address/System/Info/Public" | grep -q '"StartupWizardCompleted":false'; then
  api POST /Startup/Configuration '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
  api GET /Startup/User >/dev/null
  api POST /Startup/User '{"Name":"showcase","Password":"showcase"}' >/dev/null
  api POST /Startup/Complete >/dev/null
fi
token=$(api POST /Users/AuthenticateByName '{"Username":"showcase","Pw":"showcase"}' | json 'json.load(sys.stdin)["AccessToken"]')
if ! api GET /Library/VirtualFolders | grep -q '"Name":"Movies"'; then
  api POST "/Library/VirtualFolders?name=Movies&collectionType=movies&paths=%2Fmedia%2Fmovies&refreshLibrary=false" >/dev/null
  api POST "/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=%2Fmedia%2Ftv&refreshLibrary=false" >/dev/null
  # The one the app signs in as: no password, so no Save Password sheet.
  api POST /Users/New '{"Name":"Alex","Password":""}' >/dev/null
fi
# Sets these of a library's options on every run, so a server set up before them has them too.
library_options() { # library name, options as JSON
  local update
  update=$(api GET /Library/VirtualFolders | python3 -c '
import json, sys
name, changes = sys.argv[1], json.loads(sys.argv[2])
library = next(library for library in json.load(sys.stdin) if library["Name"] == name)
print(json.dumps({"Id": library["ItemId"], "LibraryOptions": {**library["LibraryOptions"], **changes}}))' "$1" "$2")
  api POST /Library/VirtualFolders/LibraryOptions "$update" >/dev/null
}
# The NFOs lock the metadata against online lookups. The player's scrub previews and chapter
# pictures are drawn from the films, which the player shots show; nothing else needs extracting.
library_options Movies '{"EnableRealtimeMonitor":false,"EnableTrickplayImageExtraction":true,"ExtractTrickplayImagesDuringLibraryScan":false,"EnableChapterImageExtraction":true,"ExtractChapterImagesDuringLibraryScan":true}'
library_options Shows '{"EnableRealtimeMonitor":false,"EnableTrickplayImageExtraction":false,"ExtractTrickplayImagesDuringLibraryScan":false,"EnableChapterImageExtraction":false,"ExtractChapterImagesDuringLibraryScan":false}'
task_state() { # task key
  api GET /ScheduledTasks | json "''.join(t['State'] for t in json.load(sys.stdin) if t['Key'] == '$1')"
}
# Runs one of the server's scheduled tasks now, and waits for it to finish.
run_task() { # task key
  api POST "/ScheduledTasks/Running/$(api GET /ScheduledTasks | json "next(t['Id'] for t in json.load(sys.stdin) if t['Key'] == '$1')")" >/dev/null
  sleep 2
  until [ "$(task_state "$1")" = Idle ]; do sleep 2; done
}
run_task RefreshLibrary
# The scan makes chapter pictures but leaves scrub previews to a task of their own.
run_task RefreshTrickplayImages
count=$(api GET "/Items?recursive=true&includeItemTypes=Movie,Episode" | json 'json.load(sys.stdin)["TotalRecordCount"]')
echo "Library scanned: $count movies and episodes"

# MARK: Devices

# The screenshot simulator for a device type, created on first use and booted. Each is shut down
# once its shots are taken: one left running, Vision Pro's above all, slows the sets after it
# until their tests' waits time out.
simulator() {
  local name="vinnyfin screenshots: $1" udid
  udid=$(xcrun simctl list devices -j | json "next((d['udid'] for r in json.load(sys.stdin)['devices'].values() for d in r if d['name'] == '$name' and d['isAvailable']), '')")
  [ -n "$udid" ] || udid=$(xcrun simctl create "$name" "$1")
  xcrun simctl bootstatus "$udid" -b >/dev/null
  echo "$udid"
}

# A fresh install, dark, with the status bar Apple shows in its own marketing (Apple TV and
# Vision Pro have none). Apple TV is dark from the start, and simctl can't set its appearance.
prepare() {
  local udid=$1 kind=${2:-phone}
  [ "$kind" = tv ] || xcrun simctl ui "$udid" appearance dark
  xcrun simctl uninstall "$udid" net.vinnysaj.vinnyfin
  [ "$kind" = phone ] || return 0
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

# Answers a test's requests for screenshots, each a <name>.request in `folder`, with <name>.png.
answer_requests() { # simulator, folder
  local request
  while true; do
    for request in "$2"/*.request; do
      [ -e "$request" ] || continue
      xcrun simctl io "$1" screenshot "${request%.request}.png" >/dev/null && rm "$request"
    done
    sleep 0.3
  done
}

# Runs one screenshot test and saves its attachments as Raw/<folder>/<name>.png. A test on
# Vision Pro, whose own screenshots come back empty, asks for them instead; the simulator given
# as `answering` takes them.
shoot() {
  local folder=$1 test=$2 destination=$3 answering=${4:-} results="$output/Results/$1.xcresult" answerer=""
  say "Shooting $folder"
  rm -rf "$results" "${raw:?}/$folder" "$output/Results/$folder"
  mkdir -p "$raw/$folder" "$output/Results"
  if [ -n "$answering" ]; then
    answer_requests "$answering" "$raw/$folder" &
    answerer=$!
  fi
  # xcodebuild hands the test runner its TEST_RUNNER_ variables, without the prefix.
  local status=0
  TEST_RUNNER_VINNYFIN_SCREENSHOT_SERVER="$address" TEST_RUNNER_VINNYFIN_SHOTS="$raw/$folder" \
    xcodebuild test-without-building -project "$root/Vinnyfin.xcodeproj" -scheme Vinnyfin -destination "$destination" \
    -derivedDataPath "$build" -resultBundlePath "$results" -only-testing:"VinnyfinUITests/ScreenshotTests/$test" -quiet \
    || status=$?
  if [ -n "$answerer" ]; then
    kill "$answerer"
    # Reaped here, so the shell doesn't report the job it stopped as terminated.
    wait "$answerer" 2>/dev/null || true
  fi
  [ "$status" = 0 ] || fail "The $test screenshots failed; the run is in $results"
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
  xcrun simctl shutdown "$udid"
}

if wants iphone; then
  ios_device "iPhone 6.9-inch" "iPhone 18 Pro Max" testIPhone
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
  # Closed however the run ends: a session left open stops the next run opening it.
  trap 'agent-device close --session vinnyfin-screenshots >/dev/null' EXIT
  # A just-booted Duo can take a while to report its hinge angle, which the fold is checked by.
  fold() {
    for _ in 1 2 3 4 5; do
      agent-device fold "$1" --session vinnyfin-screenshots >/dev/null 2>&1 && return
      sleep 5
    done
    agent-device fold "$1" --session vinnyfin-screenshots >/dev/null
  }
  # Each pose from a fresh install, signed in just before its shots like every other device's:
  # the home's hero turns to its next title a few seconds after it shows.
  fold closed
  shoot "iPhone Duo outer" testDuoOuter "id=$duo"
  fold open
  prepare "$duo"
  shoot "iPhone Duo inner" testDuoInner "id=$duo"
  xcrun simctl shutdown "$duo"
fi
if wants tv; then
  tv=$(simulator "Apple TV 4K (4th generation)")
  prepare "$tv" tv
  build_for tvOS "id=$tv"
  shoot "Apple TV" testTV "id=$tv"
  xcrun simctl shutdown "$tv"
fi
if wants vision; then
  vision=$(simulator "Apple Vision Pro")
  prepare "$vision" vision
  build_for visionOS "id=$vision"
  shoot "Apple Vision Pro" testVision "id=$vision" "$vision"
  xcrun simctl shutdown "$vision"
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
swift "$here/Compose.swift" "$raw" "$here/Screenshots" "$server/media" "${sets[@]}"
say "Done: $here/Screenshots"
