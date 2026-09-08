#!/bin/bash
# Best-effort diagnostic commands report errors, without hiding a test/build failure.
set -u
diagnostics="$RUNNER_TEMP/simulator-diagnostics"
mkdir -p "$diagnostics"
failed=0
collect() {
  local output=$1
  shift
  if "$@" > "$diagnostics/$output" 2>&1; then
    printf 'Collected %s\n' "$output"
  else
    echo "::warning::Could not fully collect $output; partial output retained."
    failed=1
  fi
}
collect xcode-version.log xcodebuild -version
collect simulator-inventory.json xcrun simctl list -j
collect coresimulator-host.log /usr/bin/log show --last 30m --style compact \
  --predicate 'subsystem BEGINSWITH "com.apple.CoreSimulator"'
if [[ -n "${SIMULATOR_ID:-}" ]]; then
  # XCTest can shut down its device before this always() step runs.
  if python3 - "$diagnostics/simulator-inventory.json" "$SIMULATOR_ID" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    devices = json.load(source)['devices']
sys.exit(0 if any(d['udid'] == sys.argv[2] and d['state'] == 'Booted'
                 for group in devices.values() for d in group) else 1)
PY
  then
    collect app-simulator.log xcrun simctl spawn "$SIMULATOR_ID" log show --last 30m --style compact \
      --predicate 'process == "PanPanCamera" OR process == "testmanagerd"'
  else
    echo 'Simulator is shut down; test-device logs are exported from xcresult diagnostics.' \
      > "$diagnostics/app-simulator.log"
  fi
fi
for result in "$RUNNER_TEMP"/*.xcresult; do
  [[ -d "$result" ]] || continue
  collect "$(basename "$result").summary.json" xcrun xcresulttool get test-results summary --path "$result"
  collect "$(basename "$result").tests.json" xcrun xcresulttool get test-results tests --path "$result"
  collect "$(basename "$result").export.log" xcrun xcresulttool export diagnostics --path "$result" \
    --output-path "$diagnostics/$(basename "$result").diagnostics"
done
for reports in "$HOME/Library/Logs/DiagnosticReports" \
  "$HOME/Library/Developer/CoreSimulator/Devices/${SIMULATOR_ID:-missing}/data/Library/Logs/DiagnosticReports"; do
  [[ -d "$reports" ]] || continue
  if ! find "$reports" -type f \( -name '*.crash' -o -name '*.ips' \) -exec cp -p {} "$diagnostics/" \;; then
    echo '::warning::Some crash reports could not be collected.'
    failed=1
  fi
done
printf 'Diagnostic collection incomplete: %s\n' "$failed" > "$diagnostics/collection-status.log"
