#!/usr/bin/env bash
#
# Activates the harness in the current repository: enables the git hooks,
# makes the scripts executable, and reports what was detected.
# Safe to run more than once.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/harness/lib.sh
source "$SCRIPT_DIR/lib.sh"

main() {
  case "${1:-}" in
    "") ;;
    -h | --help)
      echo "Usage: scripts/harness/init.sh"
      return 0
      ;;
    *)
      echo "Usage: scripts/harness/init.sh" >&2
      return 2
      ;;
  esac

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || harness::die "run this inside a git repository (git init first)"

  local root
  root="$(harness::root)"
  cd "$root"

  chmod +x scripts/harness/*.sh .githooks/* .claude/hooks/*.sh 2>/dev/null || true

  local current
  current="$(git config --get core.hooksPath || true)"
  if [[ -n "$current" && "$current" != ".githooks" ]]; then
    harness::warn "core.hooksPath is already '$current'; leaving it unchanged."
    harness::warn "Call .githooks/pre-commit and .githooks/commit-msg from your existing hooks."
  else
    git config core.hooksPath .githooks
    harness::ok "git hooks enabled (core.hooksPath=.githooks)"
  fi

  echo
  "$SCRIPT_DIR/detect.sh"
  echo

  if ! harness::has jq; then
    harness::warn "jq is not installed; Claude Code hooks will fall back to python3/node for JSON parsing."
  fi
  if ! harness::has gitleaks; then
    harness::info "Optional: install gitleaks for deeper secret scanning."
  fi
  if grep -q '<!-- このプロジェクトは何をするものか' .harness/PROJECT.md 2>/dev/null; then
    harness::info "Next: fill in .harness/PROJECT.md (in Claude Code, run the 'harness-setup' skill)."
  fi
  harness::info "Then run: scripts/harness/check.sh"
}

main "$@"
