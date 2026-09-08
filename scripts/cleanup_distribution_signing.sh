#!/bin/bash
set -euo pipefail
: "${RUNNER_TEMP:?}"
[[ "$RUNNER_TEMP" == /* && "$RUNNER_TEMP" != / ]] || { echo 'Unsafe RUNNER_TEMP' >&2; exit 1; }
directory="$RUNNER_TEMP/panpan-signing"
keychain="$RUNNER_TEMP/panpan-signing.keychain-db"
# Keep cleaning other materials even if an individual cleanup command fails.
failed=0
if [[ -f "$directory/installed-profile.txt" ]]; then
  IFS= read -r profile < "$directory/installed-profile.txt"
  prefix="$HOME/Library/MobileDevice/Provisioning Profiles/"
  uuid="${profile#"$prefix"}"
  if [[ "$profile" == "$prefix"* && "$uuid" =~ ^[A-Fa-f0-9-]{36}\.mobileprovision$ ]]; then
    if ! rm -f "$profile"; then failed=1; fi
  else
    echo 'Unexpected profile cleanup path rejected.' >&2
    failed=1
  fi
fi
if [[ -f "$directory/original-keychains.txt" ]]; then
  if ! python3 - "$directory/original-keychains.txt" <<'PY'
from pathlib import Path
import shlex, subprocess, sys
paths = shlex.split(Path(sys.argv[1]).read_text())
if not paths:
    sys.exit('Original keychain list is empty')
subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *paths], check=True)
PY
  then failed=1; fi
fi
if [[ -f "$keychain" ]]; then
  if ! security delete-keychain "$keychain"; then failed=1; fi
fi
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  prefix="$HOME/.appstoreconnect/private_keys/"
  filename="${ASC_KEY_PATH#"$prefix"}"
  if [[ "$ASC_KEY_PATH" == "$prefix"* && "$filename" =~ ^AuthKey_[A-Z0-9]{10}\.p8$ ]]; then
    if ! rm -f "$ASC_KEY_PATH"; then failed=1; fi
  else
    echo 'Unexpected API key cleanup path rejected.' >&2
    failed=1
  fi
fi
if ! rm -rf "$directory"; then failed=1; fi
exit "$failed"
