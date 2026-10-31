#!/usr/bin/env bash
#
# Detects likely credentials before they reach the repository.
#
# Uses HARNESS_SECRETS_CMD if set, then gitleaks if installed, and otherwise a
# built-in scanner for well-known token formats. The built-in scanner is a safety
# net, not a replacement for a dedicated tool: install gitleaks for full coverage.
#
# Only file names and line numbers are printed, never the matched values, so the
# output is safe to show in CI logs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/harness/scan-secrets.sh [--staged]

  (default)   scan all files tracked by git
  --staged    scan only the staged version of staged files (for pre-commit)
EOF
}

# Well-known credential formats (extended regular expressions).
readonly PATTERNS=(
  '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'ASIA[0-9A-Z]{16}'
  'gh[pousr]_[A-Za-z0-9]{36,}'
  'github_pat_[A-Za-z0-9_]{60,}'
  'glpat-[A-Za-z0-9_-]{20,}'
  'xox[abposr]-[A-Za-z0-9-]{10,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  'sk-(proj-)?[A-Za-z0-9]{32,}'
  'AIza[0-9A-Za-z_-]{35}'
  'npm_[A-Za-z0-9]{36}'
)

join_patterns() {
  local IFS='|'
  printf '%s' "${PATTERNS[*]}"
}

# Prints git pathspecs that exclude this script and the allowlisted paths.
exclude_pathspecs() {
  local root="$1" line
  printf '%s\n' ":(exclude)scripts/harness/scan-secrets.sh"
  [[ -f "$root/.harness/secrets-allowlist" ]] || return 0
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')"
    if [[ -n "$line" ]]; then
      printf ':(exclude,glob)%s\n' "$line"
    fi
  done <"$root/.harness/secrets-allowlist"
  return 0
}

scan_tracked() {
  local regex="$1"
  shift
  # git grep exits 1 when nothing matches, which is the success case here.
  git grep -nIE -e "$regex" -- . "$@" | cut -d: -f1,2 || true
}

scan_staged() {
  local regex="$1" file
  shift
  while IFS= read -r -d '' file; do
    git show ":$file" 2>/dev/null | grep -nIE -e "$regex" | cut -d: -f1 \
      | awk -v file="$file" '{ print file ":" $0 }' || true
  done < <(git diff --cached --name-only -z --diff-filter=ACMR -- . "$@")
}

run_gitleaks() {
  local staged="$1"
  if [[ "$staged" -eq 1 ]]; then
    gitleaks protect --staged --redact --no-banner
  else
    gitleaks detect --redact --no-banner
  fi
}

main() {
  local staged=0
  case "${1:-}" in
    "") ;;
    --staged) staged=1 ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  harness::load_config
  local root
  root="$(harness::root)"
  cd "$root"

  if [[ "${HARNESS_SECRETS_CMD:-}" == "$HARNESS_DISABLED" ]]; then
    harness::info "secrets: disabled in .harness/project.env"
    return 0
  fi
  if [[ -n "${HARNESS_SECRETS_CMD:-}" ]]; then
    bash -c "$HARNESS_SECRETS_CMD"
    return
  fi
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    harness::warn "secrets: not a git repository, skipping"
    return 0
  fi
  if harness::has gitleaks; then
    run_gitleaks "$staged"
    return
  fi

  local excludes=() line
  while IFS= read -r line; do
    excludes+=("$line")
  done < <(exclude_pathspecs "$root")

  local regex findings
  regex="$(join_patterns)"
  if [[ "$staged" -eq 1 ]]; then
    findings="$(scan_staged "$regex" "${excludes[@]}")"
  else
    findings="$(scan_tracked "$regex" "${excludes[@]}")"
  fi

  if [[ -n "$findings" ]]; then
    harness::error "secrets: possible credentials found (values hidden):"
    printf '%s\n' "$findings" | sed 's/^/  /' >&2
    harness::error "remove them and rotate the credential, or add a justified entry to .harness/secrets-allowlist"
    return 1
  fi
  harness::info "secrets: no known credential patterns found (install gitleaks for deeper scanning)"
}

main "$@"
