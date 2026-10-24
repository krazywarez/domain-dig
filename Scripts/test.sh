#!/usr/bin/env bash
#
# Run the deterministic unit suite against real simulator runtimes.
#
#   ./Scripts/test.sh            # floor + current
#   ./Scripts/test.sh floor      # oldest supported runtime only
#   ./Scripts/test.sh current    # newest installed runtime only
#
# Why both rather than one simulator: the suite's result is not runtime
# independent. Releasing a main-actor-isolated object aborts the test runner
# under iOS 18.6 with "pointer being freed was not allocated" — a Swift runtime
# bug in MarkerItem::create, fixed by iOS 26.5 — so a test that constructs and
# releases a view model passes on current and dies on floor. Pinning one
# destination hides whichever direction it is pinned away from.
#
# This covers DomainDigTests only. Scripts/audit-a11y.sh covers the
# accessibility suite, which has its own reason for running both tiers.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="DomainDig.xcodeproj"
SCHEME="DomainDig"
TIER="${1:-both}"

# shellcheck source=lib/simulators.sh
source "$(dirname "$0")/lib/simulators.sh"

case "$TIER" in
  floor | current | both) ;;
  *)
    echo "usage: $0 [floor|current|both]" >&2
    exit 2
    ;;
esac

echo "==> Reading deployment target from $PROJECT"
read_deployment_target
echo "    deployment target: $DEPLOYMENT_TARGET (rank $FLOOR_RANK)"

run_tier() {
  local which="$1"
  local sim udid label

  sim=$(select_sim "$which")
  if [[ -z "$sim" ]]; then
    echo "error: no iPhone simulator at or above iOS $DEPLOYMENT_TARGET installed" >&2
    echo "hint: install one with 'xcodebuild -downloadPlatform iOS'" >&2
    return 1
  fi

  udid=$(echo "$sim" | jq -r .udid)
  label=$(echo "$sim" | jq -r '"\(.name) (iOS \(.os))"')

  echo
  echo "==> $which: $label"

  if [[ "$which" = "floor" ]] && floor_is_approximate "$sim"; then
    echo "    NOTE: nearest installed runtime is a major version above the $DEPLOYMENT_TARGET"
    echo "          deployment target, so this is not true floor coverage."
  fi

  set -o pipefail
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$udid" \
    -only-testing:DomainDigTests 2>&1 \
    | grep -E 'Executed [0-9]+ test|\*\* TEST (SUCCEEDED|FAILED)|error:|malloc: \*\*\*|^Test Case .* failed'
}

status=0
if [[ "$TIER" = "both" ]]; then
  run_tier floor || status=1
  run_tier current || status=1
else
  run_tier "$TIER" || status=1
fi

echo
if [[ "$status" -eq 0 ]]; then
  echo "==> Done. Green on every tier run."
else
  echo "==> At least one tier failed."
fi
exit "$status"
