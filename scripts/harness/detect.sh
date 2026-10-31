#!/usr/bin/env bash
#
# Shows the detected ecosystems and the command each quality gate step will run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/harness/detect.sh [--env]

  (default)   print a human-readable report
  --env       print resolved commands in .harness/project.env format
EOF
}

# Joins multiple commands for one step into a single shell command.
joined_cmds() {
  local step="$1" cmd joined=""
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    if [[ -z "$joined" ]]; then
      joined="$cmd"
    else
      joined="$joined && $cmd"
    fi
  done < <(harness::resolve_cmds "$step")
  printf '%s' "$joined"
}

print_report() {
  local root ecosystems step cmd origin var
  root="$(harness::root)"
  ecosystems="$(harness::detect_ecosystems "$root" | tr '\n' ' ' | sed 's/ $//')"

  printf 'Repository : %s\n' "$root"
  printf 'Ecosystems : %s\n\n' "${ecosystems:-(none detected)}"
  printf '%-11s %-9s %s\n' "STEP" "SOURCE" "COMMAND"
  for step in $HARNESS_COMMAND_STEPS; do
    var="$(harness::step_var "$step")"
    if [[ -n "${!var:-}" ]]; then
      origin="config"
    else
      origin="detected"
    fi
    cmd="$(joined_cmds "$step")"
    if [[ "${!var:-}" == "$HARNESS_DISABLED" ]]; then
      cmd="(disabled)"
    elif [[ -z "$cmd" ]]; then
      cmd="(none)"
    fi
    printf '%-11s %-9s %s\n' "$step" "$origin" "$cmd"
  done

  printf '\nOptional tools: '
  local tool
  for tool in jq gitleaks shellcheck shfmt; do
    if harness::has "$tool"; then
      printf '%s ✓  ' "$tool"
    else
      printf '%s ✗  ' "$tool"
    fi
  done
  printf '\n'
}

print_env() {
  local step
  for step in $HARNESS_COMMAND_STEPS; do
    printf '%s=%q\n' "$(harness::step_var "$step")" "$(joined_cmds "$step")"
  done
}

main() {
  harness::load_config
  case "${1:-}" in
    "") print_report ;;
    --env) print_env ;;
    -h | --help) usage ;;
    *)
      usage >&2
      return 2
      ;;
  esac
}

main "$@"
