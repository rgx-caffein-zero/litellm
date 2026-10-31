#!/usr/bin/env bash
#
# Runs the project's quality gate through a single, stack-agnostic entry point.
# Commands are auto-detected from the repository and can be pinned in .harness/project.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/harness/check.sh [MODE] [OPTIONS]

Modes:
  full        format, lint, typecheck, test, build, secrets (default)
  quick       format, lint, typecheck, secrets (no tests, no build)
  fix         apply automatic formatting
  <step>      run a single step: format | format_fix | lint | typecheck | test | build | secrets

Options:
  --fail-fast   stop at the first failing step
  --strict      fail when a step listed in HARNESS_REQUIRED_STEPS has no command
  -h, --help    show this help

Exit status is 0 only if every executed step succeeds.
EOF
}

# Results are collected as "step|status|seconds" lines for the summary.
RESULTS=()
FAILED=0

record() {
  RESULTS+=("$1|$2|$3")
  if [[ "$2" == "fail" ]]; then
    FAILED=1
  fi
}

run_secrets_step() {
  local started=$SECONDS
  if "$SCRIPT_DIR/scan-secrets.sh"; then
    record secrets pass $((SECONDS - started))
  else
    record secrets fail $((SECONDS - started))
  fi
}

run_command_step() {
  local step="$1" strict="$2" started=$SECONDS cmd status=pass
  local cmds=()

  while IFS= read -r cmd; do
    if [[ -n "$cmd" ]]; then
      cmds+=("$cmd")
    fi
  done < <(harness::resolve_cmds "$step")

  if [[ ${#cmds[@]} -eq 0 ]]; then
    if [[ "$strict" -eq 1 ]] && harness::is_required "$step"; then
      harness::error "$step: required step has no command (set $(harness::step_var "$step") in .harness/project.env)"
      record "$step" fail 0
    else
      harness::info "$step: no command detected, skipping"
      record "$step" skip 0
    fi
    return 0
  fi

  for cmd in "${cmds[@]}"; do
    harness::info "$step: $cmd"
    if ! bash -c "$cmd"; then
      status=fail
      harness::error "$step failed: $cmd"
    fi
  done
  record "$step" "$status" $((SECONDS - started))
}

print_summary() {
  local entry step status secs color
  printf '\n%-12s %-6s %s\n' "STEP" "RESULT" "TIME"
  for entry in "${RESULTS[@]}"; do
    IFS='|' read -r step status secs <<<"$entry"
    case "$status" in
      pass) color="$_HARNESS_GREEN" ;;
      fail) color="$_HARNESS_RED" ;;
      *) color="$_HARNESS_YELLOW" ;;
    esac
    printf '%-12s %s%-6s%s %ss\n' "$step" "$color" "$status" "$_HARNESS_RESET" "$secs"
  done
}

main() {
  local mode="full" fail_fast=0 strict=0 arg

  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        usage
        return 0
        ;;
      --fail-fast) fail_fast=1 ;;
      --strict) strict=1 ;;
      -*)
        usage >&2
        return 2
        ;;
      *) mode="$arg" ;;
    esac
  done

  local steps
  case "$mode" in
    full) steps="format lint typecheck test build secrets" ;;
    quick) steps="format lint typecheck secrets" ;;
    fix) steps="format_fix" ;;
    format | format_fix | lint | typecheck | test | build | secrets) steps="$mode" ;;
    *)
      harness::error "unknown mode: $mode"
      usage >&2
      return 2
      ;;
  esac

  harness::load_config
  cd "$(harness::root)"

  local step
  for step in $steps; do
    if [[ "$step" == "secrets" ]]; then
      run_secrets_step
    else
      run_command_step "$step" "$strict"
    fi
    if [[ "$fail_fast" -eq 1 && "$FAILED" -eq 1 ]]; then
      break
    fi
  done

  print_summary
  if [[ "$FAILED" -eq 1 ]]; then
    harness::error "quality gate failed"
    return 1
  fi
  harness::ok "quality gate passed"
}

main "$@"
