#!/usr/bin/env bash
#
# PostToolUse hook for file edits:
#   1. formats the edited file with the project's formatter (never blocks), and
#   2. reports newly added lint/type-check suppressions back to Claude, so that
#      each one is justified or removed.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/hooks/_lib.sh
source "$HOOK_DIR/_lib.sh"

# Comment markers that silence linters, type checkers, or coverage tools.
readonly SUPPRESSION_PATTERN='eslint-disable|@ts-ignore|@ts-nocheck|@ts-expect-error|biome-ignore|# *noqa|# *type: *ignore|# *pylint: *disable|# *pyright: *ignore|//[[:space:]]*nolint|#\[allow\(|@SuppressWarnings|rubocop:disable|phpcs:ignore|@phpstan-ignore|NOSONAR|#pragma warning disable|istanbul ignore|c8 ignore|pragma: no cover|shellcheck disable'

input="$(cat)"
file="$(hook::json_get "$input" .tool_input.file_path)"
[[ -n "$file" && -f "$file" ]] || exit 0

project="$(hook::project_dir)"
cd "$project" || exit 0

"$project/scripts/harness/format-file.sh" "$file" || true

# Inspect only the text written by this tool call (Edit: new_string, Write: content),
# so suppressions that already existed are not reported again on every edit.
added="$(hook::json_get "$input" .tool_input.new_string)"
[[ -n "$added" ]] || added="$(hook::json_get "$input" .tool_input.content)"
if [[ -z "$added" ]] && git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
  added="$(git diff -U0 --no-color -- "$file" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"
fi

suppressions="$(printf '%s\n' "$added" | grep -E -- "$SUPPRESSION_PATTERN" || true)"
if [[ -n "$suppressions" ]]; then
  {
    echo "Suppression comments were added in ${file#"$project"/}:"
    printf '%s\n' "$suppressions" | head -n 10 | sed 's/^/  /'
    echo "Fix the underlying problem if possible. If a suppression is truly needed,"
    echo "scope it to one rule and one line, state the reason on the same line,"
    echo "and list it in the completion report (AGENTS.md)."
  } >&2
  # Exit code 2 feeds stderr back to Claude without undoing the edit.
  exit 2
fi

exit 0
