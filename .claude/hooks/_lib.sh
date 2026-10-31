#!/usr/bin/env bash
#
# Shared helpers for Claude Code hooks. Source this file; do not execute it.
#
# Hooks receive a JSON event on stdin. jq is preferred for parsing; python3 and
# node are used as fallbacks so the hooks work without extra installation.

# Prints the value at a dotted path (e.g. ".tool_input.command") of a JSON string.
# Prints nothing if the path is missing, the value is false/null, or no parser exists.
hook::json_get() {
  local json="$1" path="$2"

  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$path // empty" 2>/dev/null
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
for key in sys.argv[1].strip(".").split("."):
    value = value.get(key) if isinstance(value, dict) else None
if value is True:
    print("true")
elif value not in (None, False):
    print(value)
' "$path" 2>/dev/null
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    printf '%s' "$json" | node -e '
let input = "";
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  let value = JSON.parse(input);
  for (const key of process.argv[1].replace(/^\./, "").split(".")) {
    value = value && typeof value === "object" ? value[key] : undefined;
  }
  if (value !== undefined && value !== null && value !== false) console.log(String(value));
});
' "$path" 2>/dev/null
    return 0
  fi
  return 0
}

# Escapes a string for use inside a JSON string literal.
hook::json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# Emits a PreToolUse permission decision ("deny" or "ask") and exits successfully.
hook::decide() {
  local decision="$1" reason
  reason="$(hook::json_escape "$2")"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' \
    "$decision" "$reason"
  exit 0
}

# Prints the project directory Claude Code is working in.
hook::project_dir() {
  printf '%s' "${CLAUDE_PROJECT_DIR:-$(pwd)}"
}
