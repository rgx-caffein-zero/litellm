#!/usr/bin/env bash
#
# 品質ゲートの lint ステップ（.harness/project.env の HARNESS_LINT_CMD）。
#   - シェルスクリプトの構文チェック（shellcheck があれば静的解析も行う）
#   - docker-compose.yml の構文と変数展開のチェック

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# git の pathspec の * はサブディレクトリにもマッチする（scripts/certs/ なども対象になる）。
# bash 3.2（macOS の既定）でも動くよう、mapfile は使わない。
shell_files=()
while IFS= read -r file; do
  shell_files+=("$file")
done < <(git ls-files --cached --others --exclude-standard -- 'scripts/*.sh' 'tests/*.sh' 'nginx/*.sh')

printf '== 構文チェック（%d ファイル）\n' "${#shell_files[@]}"
for file in "${shell_files[@]}"; do
  # #!/bin/sh のスクリプト（nginx/entrypoint/ など）は、bash 固有の書き方を
  # 混ぜないよう sh -n で確認する。
  if head -n1 "$file" | grep -q '^#!/bin/sh'; then
    sh -n "$file"
  else
    bash -n "$file"
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  printf '== shellcheck\n'
  shellcheck -x "${shell_files[@]}"
else
  printf '== shellcheck: 未インストールのためスキップ\n'
fi

if command -v docker >/dev/null 2>&1; then
  printf '== docker compose config\n'
  # 必須の変数は .env で設定する。ここでは構文の確認だけが目的なので、ダミーの値を渡す。
  # docker-compose.yml の ${VAR:?...} と同じ変数をすべて並べる。
  LITELLM_MASTER_KEY=lint LITELLM_SALT_KEY=lint POSTGRES_PASSWORD=lint \
    docker compose --env-file /dev/null config --quiet
else
  printf '== docker compose config: docker が未インストールのためスキップ\n'
fi
