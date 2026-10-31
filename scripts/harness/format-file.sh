#!/usr/bin/env bash
#
# Formats a single file with the project's own formatter, if one is available.
#
# Used by the Claude Code post-edit hook. It never installs anything and never
# fails the caller: a missing formatter is not an error, because the full
# quality gate (check.sh) still verifies formatting.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Prints the path of a tool, preferring project-local installations.
find_tool() {
  local root="$1" tool="$2" candidate
  for candidate in "$root/node_modules/.bin/$tool" "$root/.venv/bin/$tool" "$root/vendor/bin/$tool"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  command -v "$tool" 2>/dev/null
}

rust_edition() {
  local root="$1" edition
  edition="$(grep -m1 -E '^edition[[:space:]]*=' "$root/Cargo.toml" 2>/dev/null \
    | sed -E 's/[^0-9]*([0-9]{4}).*/\1/')"
  printf '%s' "${edition:-2021}"
}

format_by_extension() {
  local root="$1" file="$2" tool
  case "$file" in
    *.js | *.jsx | *.ts | *.tsx | *.mjs | *.cjs | *.mts | *.cts | *.json | *.jsonc | *.css | \
      *.scss | *.less | *.html | *.vue | *.svelte | *.md | *.mdx | *.yml | *.yaml | *.graphql)
      if [[ -f "$root/biome.json" || -f "$root/biome.jsonc" ]] && tool="$(find_tool "$root" biome)"; then
        "$tool" format --write "$file" >/dev/null
      elif tool="$(find_tool "$root" prettier)" && [[ "$tool" == "$root/"* ]]; then
        # Only a project-local prettier: a global one may not match the project's version.
        "$tool" --write "$file" >/dev/null
      fi
      ;;
    *.py | *.pyi)
      if tool="$(find_tool "$root" ruff)"; then
        "$tool" format --quiet "$file"
      elif tool="$(find_tool "$root" black)"; then
        "$tool" --quiet "$file"
      fi
      ;;
    *.go)
      if tool="$(find_tool "$root" goimports)"; then
        "$tool" -w "$file"
      elif tool="$(find_tool "$root" gofmt)"; then
        "$tool" -w "$file"
      fi
      ;;
    *.rs)
      if tool="$(find_tool "$root" rustfmt)"; then
        "$tool" --edition "$(rust_edition "$root")" "$file"
      fi
      ;;
    *.sh | *.bash)
      if tool="$(find_tool "$root" shfmt)"; then
        "$tool" -w "$file"
      fi
      ;;
    *.tf | *.tfvars)
      if tool="$(find_tool "$root" terraform)"; then
        "$tool" fmt "$file" >/dev/null
      fi
      ;;
  esac
}

main() {
  local file="${1:-}"
  [[ -n "$file" && -f "$file" ]] || return 0
  # Formatters run from the repository root, so resolve the path first.
  file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

  harness::load_config
  local root
  root="$(harness::root)"

  if [[ "${HARNESS_FORMAT_FILE_CMD:-}" == "$HARNESS_DISABLED" ]]; then
    return 0
  fi
  if [[ -n "${HARNESS_FORMAT_FILE_CMD:-}" ]]; then
    local quoted cmd
    quoted="$(printf '%q' "$file")"
    cmd="${HARNESS_FORMAT_FILE_CMD//\{file\}/$quoted}"
    (cd "$root" && bash -c "$cmd") || harness::warn "format-file: '$cmd' failed"
    return 0
  fi

  (cd "$root" && format_by_extension "$root" "$file") \
    || harness::warn "format-file: formatter failed for $file"
  return 0
}

main "$@"
