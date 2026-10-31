#!/usr/bin/env bash
#
# PreToolUse hook for file edits: asks before changing quality-gate configuration
# or secret files.
#
# The most common way for an agent to "pass" a failing check is to weaken the
# check itself. Requiring confirmation keeps that decision with a human.

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/hooks/_lib.sh
source "$HOOK_DIR/_lib.sh"

input="$(cat)"
file="$(hook::json_get "$input" .tool_input.file_path)"
[[ -n "$file" ]] || file="$(hook::json_get "$input" .tool_input.notebook_path)"
[[ -n "$file" ]] || exit 0

project="$(hook::project_dir)"
rel="${file#"$project"/}"
name="$(basename "$rel")"

case "$name" in
  .env | .env.local | .env.*.local | .env.production | *.pem | *.key | id_rsa | id_ed25519)
    hook::decide ask "'$rel' may contain secrets. Confirm that this edit is intended and that no real credentials are written."
    ;;
esac

case "$rel" in
  .harness/* | .githooks/* | scripts/harness/* | .claude/settings.json | .claude/hooks/* | \
    .github/workflows/*)
    hook::decide ask "'$rel' is part of the quality harness. Confirm that this change does not weaken the quality gate."
    ;;
esac

case "$name" in
  .eslintrc* | eslint.config.* | .prettierrc* | prettier.config.* | biome.json | biome.jsonc | \
    tsconfig*.json | ruff.toml | .ruff.toml | mypy.ini | .flake8 | .pylintrc | pytest.ini | \
    .golangci.y*ml | .golangci.toml | clippy.toml | rustfmt.toml | .rustfmt.toml | \
    .rubocop.yml | phpstan.neon* | phpcs.xml* | .php-cs-fixer*.php | .editorconfig | \
    checkstyle*.xml | .stylelintrc* | .markdownlint* | .gitleaks.toml)
    hook::decide ask "'$rel' configures a formatter, linter, or type checker. Confirm that rules are not being relaxed to hide problems."
    ;;
esac

exit 0
