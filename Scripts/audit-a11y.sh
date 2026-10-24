#!/usr/bin/env bash
#
# Run the accessibility audit suite against real simulator runtimes.
#
#   ./Scripts/audit-a11y.sh            # floor + current
#   ./Scripts/audit-a11y.sh floor      # oldest supported runtime only
#   ./Scripts/audit-a11y.sh current    # newest installed runtime only
#
# Why this exists rather than living entirely in CI: audit coverage is NOT
# nested across OS versions — each runtime reports findings the others miss, in
# both directions. Measured on Tracked Domains, iOS 18.6 reported 2 findings and
# iOS 27.0 reported 6; at accessibility text sizes the Dashboard produced a
# hit-region finding on 18.6 that 27.0 did not. The GitHub macos-26 image ships
# only iOS 26.x runtimes, so it structurally cannot cover the floor. This machine
# can.
#
# Scripts/test.sh does the same for the unit suite, for its own reasons.
#
# CI covers "current" on a clean checkout (which a local run cannot, since it
# would miss an uncommitted file). This script covers "floor" (which CI cannot).
# Together they cover both; neither duplicates the other.
#
# The deployment target is read from the project rather than hard-coded, so it
# cannot drift out of sync.

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

  # Findings are printed by the suite itself; surface them plus the verdict.
  set -o pipefail
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "id=$udid" \
    CODE_SIGNING_ALLOWED=NO 2>&1 \
    | grep -E 'finding\(s\)|no accessibility findings|^  • |did not complete in time|Executed [0-9]+ test|\*\* TEST (SUCCEEDED|FAILED)' \
    || true

  return 0
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
  echo "==> Done. Findings above are the burndown list for issue #21."
  echo "    They are reported, not enforced — widen"
  echo "    AccessibilityAuditHarness.enforcedAuditTypes as each phase lands."
fi
exit "$status"
