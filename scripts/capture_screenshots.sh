#!/bin/bash
set -euo pipefail
: "${SIMULATOR_ID:?}"
: "${APP_BUNDLE_ID:?}"
app="$RUNNER_TEMP/DerivedData/Build/Products/Debug-iphonesimulator/PanPanCamera.app"
test -d "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" = "$APP_BUNDLE_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl ui "$SIMULATOR_ID" appearance light
# An untouched simctl capture supplies the native framebuffer dimensions.
xcrun simctl io "$SIMULATOR_ID" screenshot --type=png "$RUNNER_TEMP/native-resolution.png"

capture() {
  local language=$1 locale=$2 screen=$3
  local container ready
  # A new installation for every image resets all app preferences and panel state.
  xcrun simctl install "$SIMULATOR_ID" "$app"
  container=$(xcrun simctl get_app_container "$SIMULATOR_ID" "$APP_BUNDLE_ID" data)
  ready="$container/tmp/panpan-screenshot-ready.json"
  xcrun simctl launch "$SIMULATOR_ID" "$APP_BUNDLE_ID" \
    --screenshot-mode --screenshot-screen "$screen" \
    -AppleLanguages "($language)" -AppleLocale "$locale" \
    2>&1 | tee -a "$RUNNER_TEMP/app-launch.log"
  for ((attempt=0; attempt<30; attempt++)); do
    [[ -s "$ready" ]] && break
    sleep 1
  done
  python3 - "$ready" "$screen" "$language" "$locale" <<'PY'
import json
from pathlib import Path
import sys
record = json.loads(Path(sys.argv[1]).read_text())
expected = dict(zip(['screen', 'language', 'locale'], sys.argv[2:]))
if record != expected:
    sys.exit(f'App readiness/localization mismatch: {record}; expected {expected}')
print(f'App rendered: {record}')
PY
  mkdir -p "screenshots/$language"
  sleep 1
  xcrun simctl io "$SIMULATOR_ID" screenshot --type=png "screenshots/$language/$screen.png"
  # A crashed or already-terminated process fails here rather than producing false success.
  xcrun simctl terminate "$SIMULATOR_ID" "$APP_BUNDLE_ID"
  xcrun simctl uninstall "$SIMULATOR_ID" "$APP_BUNDLE_ID"
}

for spec in 'ja|ja_JP' 'zh-Hans|zh_CN' 'zh-Hant|zh_TW' 'en|en_US' 'ko|ko_KR'; do
  IFS='|' read -r language locale <<< "$spec"
  capture "$language" "$locale" camera
done
for screen in beauty reshape filter makeup settings; do
  capture ja ja_JP "$screen"
done
python3 scripts/verify_screenshots.py screenshots "$RUNNER_TEMP/native-resolution.png" --macos-read \
  | tee "$RUNNER_TEMP/screenshot-inventory.log"
