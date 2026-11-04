# shellcheck shell=bash
#
# Where accessibility audit passes are recorded, and which changes need one.
# Sourced by Scripts/audit-a11y.sh, which records a pass, and
# .githooks/pre-push, which checks for it.

# Paths whose changes can alter the rendered UI.
AUDIT_INPUTS='\.(swift|xcassets|xcodeproj)|\.pbxproj|xcscheme'

# One tree hash per line. Under the common git dir, so worktrees share it.
audit_pass_file() {
  echo "$(git rev-parse --git-common-dir)/a11y-audit-passed"
}
