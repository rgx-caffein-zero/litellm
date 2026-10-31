#!/usr/bin/env bash
#
# Copies the harness into another repository without overwriting existing files.
#
#   scripts/harness/install.sh /path/to/repo           # skip files that already exist
#   scripts/harness/install.sh /path/to/repo --force   # overwrite harness-owned files only
#
# Project-owned files (CONTRIBUTING.md, SECURITY.md, .editorconfig, ...) are never
# overwritten, even with --force, because they usually contain project decisions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/harness/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Files the harness owns. --force may overwrite these.
readonly HARNESS_FILES=(
  AGENTS.md
  CLAUDE.md
  .harness/PROJECT.md
  .harness/project.env
  .harness/secrets-allowlist
  scripts/harness/lib.sh
  scripts/harness/check.sh
  scripts/harness/detect.sh
  scripts/harness/format-file.sh
  scripts/harness/scan-secrets.sh
  scripts/harness/init.sh
  scripts/harness/install.sh
  .githooks/pre-commit
  .githooks/commit-msg
  .claude/settings.json
  .claude/hooks/_lib.sh
  .claude/hooks/session-start.sh
  .claude/hooks/guard-bash.sh
  .claude/hooks/protect-files.sh
  .claude/hooks/post-edit.sh
  .claude/hooks/stop-verify.sh
  .claude/agents/code-reviewer.md
  .claude/agents/readability-reviewer.md
  .claude/agents/security-reviewer.md
  .claude/skills/task-plan/SKILL.md
  .claude/skills/quality-gate/SKILL.md
  .claude/skills/team-review/SKILL.md
  .claude/skills/pr-ready/SKILL.md
  .claude/skills/adr-new/SKILL.md
  .claude/skills/harness-setup/SKILL.md
  docs/harness/CODING_STANDARDS.md
  docs/harness/REVIEW_CHECKLIST.md
  docs/harness/DEFINITION_OF_DONE.md
  docs/harness/WORKFLOW.md
  docs/harness/COMMIT_CONVENTION.md
  docs/adr/0000-template.md
  .github/workflows/quality.yml
)

# Files that become the project's own once installed. Never overwritten.
readonly PROJECT_FILES=(
  docs/adr/README.md
  .github/pull_request_template.md
  .github/ISSUE_TEMPLATE/bug_report.md
  .github/ISSUE_TEMPLATE/feature_request.md
  .editorconfig
  .gitattributes
  CONTRIBUTING.md
  SECURITY.md
)

COPIED=0
SKIPPED=0

copy_file() {
  local rel="$1" target="$2" allow_overwrite="$3"
  local src="$HARNESS_SRC/$rel" dest="$target/$rel"

  [[ -f "$src" ]] || harness::die "missing source file: $rel"
  if [[ -e "$dest" && "$allow_overwrite" -ne 1 ]]; then
    harness::info "skip   $rel (exists)"
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -p "$src" "$dest"
  harness::info "copy   $rel"
  COPIED=$((COPIED + 1))
}

main() {
  local target="" force=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      -h | --help)
        sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        return 0
        ;;
      -*) harness::die "unknown option: $arg" ;;
      *) target="$arg" ;;
    esac
  done

  [[ -n "$target" ]] || harness::die "usage: install.sh <target-repo> [--force]"
  [[ -d "$target" ]] || harness::die "not a directory: $target"
  target="$(cd "$target" && pwd)"
  [[ "$target" != "$HARNESS_SRC" ]] || harness::die "target is the harness itself"

  local rel
  for rel in "${HARNESS_FILES[@]}"; do
    copy_file "$rel" "$target" "$force"
  done
  for rel in "${PROJECT_FILES[@]}"; do
    copy_file "$rel" "$target" 0
  done

  harness::ok "installed: $COPIED copied, $SKIPPED skipped"
  if [[ $SKIPPED -gt 0 ]]; then
    harness::info "Skipped files were left untouched; merge them manually if needed."
  fi
  harness::info "Next: cd $target && scripts/harness/init.sh"
}

main "$@"
