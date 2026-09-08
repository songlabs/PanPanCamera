#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${APPLE_TEAM_ID:?}"
: "${APPLE_DISTRIBUTION_P12_BASE64:?}"
: "${APPLE_DISTRIBUTION_P12_PASSWORD:?}"
: "${PROFILE_PANPAN_BASE64:?}"
umask 077
directory="$RUNNER_TEMP/panpan-signing"
keychain="$RUNNER_TEMP/panpan-signing.keychain-db"
mkdir -p "$directory"
# Record cleanup locations before any partial installation can fail.
echo "SIGNING_KEYCHAIN_PATH=$keychain" >> "$GITHUB_ENV"
security list-keychains -d user > "$directory/original-keychains.txt"
printf '%s' "$APPLE_DISTRIBUTION_P12_BASE64" | base64 --decode > "$directory/distribution.p12"
printf '%s' "$PROFILE_PANPAN_BASE64" | base64 --decode > "$directory/profile.mobileprovision"
security cms -D -i "$directory/profile.mobileprovision" > "$directory/profile.plist"
password=$(openssl rand -hex 32)
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$directory/distribution.p12" -k "$keychain" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db
security find-identity -v -p codesigning "$keychain" > "$directory/identities.txt"
SIGNING_CERTIFICATE_SHA1=$(python3 - "$directory/identities.txt" <<'PY'
from pathlib import Path
import re, sys
identities = re.findall(r'\b([A-Fa-f0-9]{40}) "Apple Distribution:[^"\n]+"', Path(sys.argv[1]).read_text())
if len(identities) != 1:
    sys.exit(f'Expected exactly one valid Apple Distribution identity, found {len(identities)}')
print(identities[0].upper())
PY
)
export SIGNING_CERTIFICATE_SHA1
echo "SIGNING_CERTIFICATE_SHA1=$SIGNING_CERTIFICATE_SHA1" >> "$GITHUB_ENV"
python3 scripts/validate_signing.py
uuid=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$directory/profile.plist")
profiles="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$profiles"
installed="$profiles/$uuid.mobileprovision"
test ! -e "$installed" || { echo 'Refusing to overwrite an existing provisioning profile.' >&2; exit 1; }
printf '%s\n' "$installed" > "$directory/installed-profile.txt"
cp "$directory/profile.mobileprovision" "$installed"
