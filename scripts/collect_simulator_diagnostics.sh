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
if [[ -n "${SIMULATOR_ID:-}" ]]; then
  collect app-simulator.log xcrun simctl spawn "$SIMULATOR_ID" log show --last 30m --style compact \
    --predicate 'process == "PanPanCamera" OR process == "testmanagerd"'
fi
for result in "$RUNNER_TEMP"/*.xcresult; do
  [[ -d "$result" ]] || continue
  collect "$(basename "$result").summary.json" xcrun xcresulttool get test-results summary --path "$result"
  collect "$(basename "$result").tests.json" xcrun xcresulttool get test-results tests --path "$result"
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
