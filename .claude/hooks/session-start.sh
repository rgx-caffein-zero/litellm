#!/usr/bin/env bash
#
# SessionStart hook: gives Claude a short, factual snapshot of the repository.
# Everything printed to stdout is added to Claude's context.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/hooks/_lib.sh
source "$HOOK_DIR/_lib.sh"

cat >/dev/null # The event payload is not needed.

project="$(hook::project_dir)"
cd "$project" || exit 0

# shellcheck source=scripts/harness/lib.sh
source "$project/scripts/harness/lib.sh"

ecosystems="$(harness::detect_ecosystems "$project" | tr '\n' ' ' | sed 's/ $//')"

echo "## Harness context"
echo "- Detected ecosystems: ${ecosystems:-none}"
echo "- Quality gate: scripts/harness/check.sh (quick | full | fix | <step>)"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git branch --show-current 2>/dev/null)"
  changed="$(git status --porcelain | wc -l | tr -d ' ')"
  echo "- Branch: ${branch:-detached} (uncommitted files: $changed)"
fi

if grep -q '<!-- このプロジェクトは何をするものか' .harness/PROJECT.md 2>/dev/null; then
  echo "- .harness/PROJECT.md is not filled in yet. Suggest running the harness-setup skill before large changes."
fi

exit 0
