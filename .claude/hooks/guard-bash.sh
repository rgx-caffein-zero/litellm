#!/usr/bin/env bash
#
# PreToolUse hook for Bash: blocks destructive commands and asks before risky ones.
#
# This is a guardrail against mistakes, not a security boundary. Patterns are
# intentionally conservative so that normal development commands pass silently.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/hooks/_lib.sh
source "$HOOK_DIR/_lib.sh"

input="$(cat)"
command="$(hook::json_get "$input" .tool_input.command)"
# Without a JSON parser, inspect the raw event: false positives beat missed blocks.
[[ -n "$command" ]] || command="$input"

# Collapse whitespace so patterns do not depend on spacing.
command="$(printf '%s' "$command" | tr '\n\t' '  ' | tr -s ' ')"

matches() { printf '%s' "$command" | grep -Eq -- "$1"; }

# --- Deny: irreversible or bypasses the quality process ---------------------------

readonly RM_RECURSIVE_FORCE='(^|[;&|( ])rm( +-[a-zA-Z-]+)* +-([a-zA-Z]*r[a-zA-Z]*f|[a-zA-Z]*f[a-zA-Z]*r)[a-zA-Z]*'
# "$HOME" is matched literally, as typed in the command, so it must not expand here.
# shellcheck disable=SC2016
readonly RM_DANGEROUS_TARGET=' (/|/\*|~|~/|~/\*|\$HOME|\$HOME/|\$HOME/\*|\.|\./|\.\.|\*)( |;|&|\||$)'
if matches "$RM_RECURSIVE_FORCE" && matches "$RM_DANGEROUS_TARGET"; then
  hook::decide deny "Recursive force delete of a root, home, or current directory is blocked. Delete specific paths instead."
fi

if matches '(^|[ ;&|])git( +-[^ ]+)* +(commit|push|merge|rebase|am)( .*)? --no-verify'; then
  hook::decide deny "Bypassing git hooks with --no-verify is not allowed (AGENTS.md). Fix the reported problem instead."
fi

if matches 'git( +-[^ ]+)* +push( .*)? (--force|-f)( |$)' || matches 'git( +-[^ ]+)* +push( .*)? \+[^ ]+'; then
  hook::decide deny "Force push is blocked. Use --force-with-lease on your own branch only if the user explicitly asks."
fi

if matches '(^|[ ;&|])(mkfs(\.[a-z0-9]+)?|dd +[^;]*of=/dev/)'; then
  hook::decide deny "Writing to block devices or formatting filesystems is blocked."
fi

# --- Ask: legitimate in some cases, but the user should confirm -------------------

if matches 'git( +-[^ ]+)* +push( .*)? (origin +)?(main|master|HEAD:(main|master))( |$)'; then
  hook::decide ask "Pushing directly to the main branch. Normally changes go through a pull request."
fi

if matches 'git( +-[^ ]+)* +reset( .*)? --hard' \
  || matches 'git( +-[^ ]+)* +clean( +-[a-zA-Z]+)* +-[a-zA-Z]*f' \
  || matches 'git( +-[^ ]+)* +checkout +(-- +)?\.( |$)' \
  || matches 'git( +-[^ ]+)* +restore( +--[a-z-]+)* +\.( |$)' \
  || matches 'git( +-[^ ]+)* +branch +-D '; then
  hook::decide ask "This command discards uncommitted work or branches. Confirm that nothing will be lost."
fi

if matches '(curl|wget)[^|]*\| *(sudo +)?(ba|z|da)?sh( |$)'; then
  hook::decide ask "Piping a downloaded script into a shell executes unreviewed code."
fi

if matches '(^|[ ;&|])sudo '; then
  hook::decide ask "This command requests elevated privileges."
fi

exit 0
