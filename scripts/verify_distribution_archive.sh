#!/bin/bash
set -euo pipefail
archive=${1:?Usage: verify_distribution_archive.sh ARCHIVE_PATH}
shopt -s nullglob
apps=("$archive"/Products/Applications/*.app)
test "${#apps[@]}" -eq 1 || { echo 'Expected exactly one Main App in archive.' >&2; exit 1; }
app="${apps[0]}"
embedded=("$app"/PlugIns/*.appex "$app"/Watch/*.app "$app"/AppClips/*.app)
test "${#embedded[@]}" -eq 0 || { echo 'Unexpected embedded app/extension in PanPan archive.' >&2; exit 1; }
test -s "$app/embedded.mobileprovision"
codesign --verify --deep --strict --verbose=2 "$app"
directory="$RUNNER_TEMP/panpan-signing"
security cms -D -i "$app/embedded.mobileprovision" > "$directory/embedded.plist"
codesign -d --entitlements :- "$app" > "$directory/entitlements.plist"
codesign -d --extract-certificates="$directory/archive-certificate" "$app"
python3 scripts/validate_signing.py "$app"
