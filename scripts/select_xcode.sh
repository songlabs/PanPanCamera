#!/bin/bash
set -euo pipefail
sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer
xcodebuild -version | tee "$RUNNER_TEMP/xcode-version.log"
grep -qx 'Xcode 26.3' "$RUNNER_TEMP/xcode-version.log"
xcrun --sdk iphoneos --show-sdk-version | tee "$RUNNER_TEMP/iphoneos-sdk-version.log"
test "$(cut -d. -f1 "$RUNNER_TEMP/iphoneos-sdk-version.log")" = 26
