#!/usr/bin/env bash
#
# Stop hook: runs the quality gate before Claude finishes a turn that changed files.
# If the gate fails, Claude is asked to continue and fix the problems.
#
# Mode is set by HARNESS_STOP_CHECK in .harness/project.env (quick | full | off).

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/hooks/_lib.sh
source "$HOOK_DIR/_lib.sh"

readonly MAX_OUTPUT_LINES=60

input="$(cat)"

# Claude is already continuing because of this hook; do not loop forever.
if [[ "$(hook::json_get "$input" .stop_hook_active)" == "true" ]]; then
  exit 0
fi

project="$(hook::project_dir)"
cd "$project" || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Nothing changed in this working tree: nothing to verify.
[[ -n "$(git status --porcelain)" ]] || exit 0

# shellcheck source=scripts/harness/lib.sh
source "$project/scripts/harness/lib.sh"
harness::load_config
mode="${HARNESS_STOP_CHECK:-quick}"
[[ "$mode" != "off" ]] || exit 0

if output="$("$project/scripts/harness/check.sh" "$mode" 2>&1)"; then
  exit 0
fi

{
  echo "The quality gate (scripts/harness/check.sh $mode) failed. Fix the root cause before finishing."
  echo "Do not disable rules, skip tests, or weaken assertions to make it pass."
  echo "If the failure is unrelated to your change, say so in your report instead of fixing it."
  echo
  printf '%s\n' "$output" | tail -n "$MAX_OUTPUT_LINES"
} >&2
exit 2
