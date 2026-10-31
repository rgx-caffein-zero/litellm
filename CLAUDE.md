# CLAUDE.md

@AGENTS.md

## Claude Code 固有の補足

- 品質ゲートやガードレールは `.claude/settings.json` の hooks で自動的に動きます。hooks からのフィードバックは指示として扱い、根本原因を修正してください。
- 作業終了時、変更があれば `scripts/harness/check.sh quick` が自動実行されます。失敗した場合は修正を続けてください。
- 独立レビューには `.claude/agents/` のサブエージェント（`code-reviewer` / `readability-reviewer` / `security-reviewer`）を使います。レビュアーには実装の経緯を渡さず、目的と差分の範囲だけを渡してください。
- よく使う手順は skills にあります: `task-plan`, `quality-gate`, `team-review`, `pr-ready`, `adr-new`, `harness-setup`。
