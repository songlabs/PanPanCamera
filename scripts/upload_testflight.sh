#!/bin/bash
set -euo pipefail
set +e
xcrun altool --upload-app --type ios --file "$RUNNER_TEMP/export/PanPanCamera.ipa" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee "$RUNNER_TEMP/upload.log"
statuses=("${PIPESTATUS[@]}")
set -e
if [[ "${statuses[0]}" -ne 0 || "${statuses[1]}" -ne 0 ]]; then
  echo "App Store Connect upload/log capture failed: altool=${statuses[0]}, tee=${statuses[1]}" >&2
  exit 1
fi
test -s "$RUNNER_TEMP/upload.log"
if grep -Eiq 'UPLOAD FAILED|Failed to upload package\.|Validation fail(ed|ure)|STATE_ERROR\.VALIDATION_ERROR|Invalid Pre-Release Train|Invalid train|App Store Connect.*reject' "$RUNNER_TEMP/upload.log"; then
  echo 'App Store Connect rejected the upload.' >&2
  exit 1
fi
echo 'Upload command completed without known rejection markers; App Store Connect processing is separate.'
