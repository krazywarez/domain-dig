# Simulator selection shared by the test scripts. Sourced, not executed.
#
# The caller sets PROJECT and SCHEME first, then calls
# read_deployment_target once and select_sim per tier.
#
# Runtime coverage is not nested: a result on one iOS version does not imply
# the same result on another, in either direction. Scripts/audit-a11y.sh
# documents the measured accessibility differences; the unit suite has its own
# case, a Swift runtime bug in MarkerItem::create that aborts on releasing a
# main-actor-isolated object under iOS 18.6 and is fixed by iOS 26.5. Both are
# reasons to run floor and current rather than whichever simulator is handy.

# Sets DEPLOYMENT_TARGET, DT_MAJOR, DT_MINOR and FLOOR_RANK from the project,
# so the floor cannot drift away from the build setting.
read_deployment_target() {
  DEPLOYMENT_TARGET=$(
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ IPHONEOS_DEPLOYMENT_TARGET = /{print $2; exit}'
  )

  if [[ -z "${DEPLOYMENT_TARGET:-}" ]]; then
    echo "error: could not read IPHONEOS_DEPLOYMENT_TARGET" >&2
    return 1
  fi

  DT_MAJOR="${DEPLOYMENT_TARGET%%.*}"
  DT_MINOR="${DEPLOYMENT_TARGET##*.}"
  [[ "$DT_MINOR" = "$DEPLOYMENT_TARGET" ]] && DT_MINOR=0
  FLOOR_RANK=$(( DT_MAJOR * 1000 + DT_MINOR ))
}

# Pick an iPhone simulator at or above the deployment target. A runtime BELOW it
# is useless — the app cannot install there — which is why this filters rather
# than just taking the oldest installed runtime.
select_sim() {
  local which="$1"
  xcrun simctl list devices available --json \
    | jq -c --argjson floor "$FLOOR_RANK" --arg which "$which" '
        [ .devices | to_entries[]
          | (.key | capture("SimRuntime\\.iOS-(?<maj>[0-9]+)-(?<min>[0-9]+)$")) as $v
          | (($v.maj | tonumber) * 1000 + ($v.min | tonumber)) as $rank
          | select($rank >= $floor)
          | .value[]
          | select(.name | startswith("iPhone"))
          | { rank: $rank, udid: .udid, name: .name, os: "\($v.maj).\($v.min)" }
        ]
        | sort_by(.rank, .name)
        | if length == 0 then empty
          elif $which == "floor" then first
          else last end
      '
}

# True when the chosen "floor" simulator is a major version above the
# deployment target, i.e. the floor is not actually covered.
floor_is_approximate() {
  local sim="$1"
  [[ "$(echo "$sim" | jq -r .rank)" -ge $(( (DT_MAJOR + 1) * 1000 )) ]]
}
