#!/usr/bin/env bash
#
# dump-db.sh で作ったダンプを、このリポジトリの環境（移行先）の DB にリストアする。
# 移行の全体の手順は docs/migration.md。
#
# 移行先の DB を作り直してからリストアする。--clean で上書きしないのは、移行先の DB には
# 新しいバージョンの LiteLLM が作ったテーブルがあり、移行元の古いテーブルと混ざると
# 起動時のマイグレーションが失敗するため。
# 誤って別の環境を消さないよう、次の場合は何もせずに終了する。
#   - このディレクトリ以外の docker-compose.yml で作られたコンテナが、同じプロジェクト名で
#     ある（同じホストに移行元がある場合など）
#   - 同じプロジェクト名のボリュームだけが残っていて、どの環境のものか確かめられない
#   - ダンプの SHA-256 が、dump-db.sh が表示した値と一致しない（リストアは DB の管理者の
#     権限で行うため、差し替えられたダンプを入れると、DB コンテナで任意の処理が動く）
#   - 確認に yes と答えなかった
#
# LiteLLM と nginx は止めたままにする。.env の LITELLM_SALT_KEY を確認してから起動する。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
# docker-compose.yml の db サービスの設定と合わせる
readonly DB_USER="litellm"
readonly DB_NAME="litellm"
readonly CONTAINER_DUMP_PATH="/tmp/litellm-restore.dump"
# 件数を表示するテーブル（dump-db.sh の表示と比べる）
readonly COUNT_TABLES="LiteLLM_TeamTable LiteLLM_VerificationToken LiteLLM_ProxyModelTable LiteLLM_CredentialsTable LiteLLM_UserTable LiteLLM_BudgetTable"

usage() {
  cat <<'EOF'
使い方: scripts/migration/restore-db.sh <ダンプファイル> --sha256 <ハッシュ> [--yes]

  ダンプファイル      scripts/migration/dump-db.sh で作ったファイル
  --sha256 <ハッシュ>  dump-db.sh が表示した SHA-256。ファイルとは別の経路で控えたものを渡す。必須
  --yes               確認を省略する（このリポジトリの環境の DB の内容は、すべて失われる）

リストアの後、LiteLLM と nginx は停止したままになります。
.env の LITELLM_SALT_KEY を移行元に合わせてから起動してください（docs/migration.md）。
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

db_query() {
  docker compose exec -T db psql -X -A -t -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "$1"
}

# DB から読んだ値を端末に出す前に、制御文字（端末の表示を書き換えるエスケープシーケンスなど）を取り除く。
strip_control_chars() {
  LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# .env の LITELLM_SALT_KEY の値が空でないかを確かめる（引用符と空白だけの値も空とみなす）。
salt_key_is_set() {
  local value
  value="$(sed -n 's/^LITELLM_SALT_KEY=//p' .env | tail -n 1)"
  value="${value//[\"\'[:space:]]/}"
  [[ -n "$value" ]]
}

# 同じプロジェクト名のコンテナが、すべてこのディレクトリの docker-compose.yml から
# 作られたものであることを確かめる。違えば、別の環境を操作してしまうので中止する。
# コンテナがなく、同じプロジェクト名のボリュームだけがある場合も、どの環境のものか
# 確かめられないので中止する。
ensure_project_is_this_repo() {
  local ids id working_dir project volumes
  ids="$(docker compose ps --all --quiet)" ||
    die "docker compose ps に失敗しました。別の環境を操作しないよう中止しました。"
  for id in $ids; do
    working_dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")" ||
      die "コンテナ $id のラベルを読めませんでした。"
    [[ "$working_dir" == "$REPO_ROOT" ]] ||
      die "同じプロジェクト名のコンテナが、別のディレクトリ（$working_dir）にあります。別の環境を操作しないよう中止しました。COMPOSE_PROJECT_NAME で別の名前を指定してください。"
  done
  if [[ -z "$ids" ]]; then
    project="$(docker compose config | sed -n 's/^name: //p' | head -n 1)"
    [[ -n "$project" ]] || die "プロジェクト名を取得できませんでした。"
    volumes="$(docker volume ls --quiet --filter "label=com.docker.compose.project=$project")" ||
      die "docker volume ls に失敗しました。"
    [[ -z "$volumes" ]] ||
      die "プロジェクト $project のコンテナはなく、ボリューム（$(printf '%s' "$volumes" | tr '\n' ' ')）だけがあります。この環境のものか確かめられないため中止しました。この環境のボリュームであれば、docker compose up -d で起動してから実行してください。"
  fi
}

confirm() {
  local answer
  if [[ ! -t 0 ]]; then
    die "確認のため、端末から実行してください（確認を省略する場合は --yes を付けます）。"
  fi
  printf '\nこの環境（%s）の DB の内容をすべて削除し、%s の内容で置き換えます。\n' "$REPO_ROOT" "$DUMP_FILE"
  printf '続ける場合は yes と入力してください: '
  read -r answer
  [[ "$answer" == "yes" ]] || die "中止しました。"
}

print_table_counts() {
  local table count
  for table in $COUNT_TABLES; do
    if count="$(db_query "SELECT count(*) FROM \"$table\"" 2>/dev/null)"; then
      printf '  %-28s %s\n' "$table" "$count"
    else
      printf '  %-28s %s\n' "$table" "（テーブルなし）"
    fi
  done
}

# litellm/config.yaml のモデル名と、DB に登録されたモデル名を比べる。
# 同じ名前があると、LiteLLM はそれらの間で負荷分散する（docs/operations.md）。
print_model_name_conflicts() {
  local config_names db_names conflicts
  config_names="$(sed -n 's/^ *- model_name: *//p' litellm/config.yaml | sort -u)"
  db_names="$(db_query 'SELECT DISTINCT model_name FROM "LiteLLM_ProxyModelTable"' 2>/dev/null | strip_control_chars | sort -u)" || db_names=""
  conflicts="$(comm -12 <(printf '%s\n' "$config_names") <(printf '%s\n' "$db_names") | sed '/^$/d')"
  if [[ -n "$conflicts" ]]; then
    printf '  注意: 次のモデル名は litellm/config.yaml と DB の両方にあります。管理 UI で DB 側を削除するか、名前を変えてください。\n'
    printf '%s\n' "$conflicts" | sed 's/^/    /'
  else
    printf '  litellm/config.yaml と同じ名前のモデルは、DB にありません。\n'
  fi
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  local dump_arg="" expected_sha256="" assume_yes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha256)
        [[ $# -ge 2 ]] || {
          usage >&2
          exit 2
        }
        expected_sha256="$2"
        shift 2
        ;;
      --yes)
        assume_yes=1
        shift
        ;;
      -*)
        usage >&2
        exit 2
        ;;
      *)
        [[ -z "$dump_arg" ]] || {
          usage >&2
          exit 2
        }
        dump_arg="$1"
        shift
        ;;
    esac
  done
  [[ -n "$dump_arg" && -n "$expected_sha256" ]] || {
    usage >&2
    exit 2
  }
  [[ -f "$dump_arg" ]] || die "ダンプファイルが見つかりません: $dump_arg"
  DUMP_FILE="$(cd "$(dirname "$dump_arg")" && pwd)/$(basename "$dump_arg")"

  local actual_sha256
  actual_sha256="$(sha256sum "$DUMP_FILE" | cut -d' ' -f1)"
  # 大文字で控えた場合も一致とみなす
  [[ "$actual_sha256" == "$(printf '%s' "$expected_sha256" | tr 'A-F' 'a-f')" ]] ||
    die "ダンプの SHA-256（$actual_sha256）が、指定した値と一致しません。ダンプを取り直すか、コピーし直してください。"

  cd "$REPO_ROOT"
  command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
  [[ -f .env ]] || die ".env がありません（docs/setup.md）。"
  salt_key_is_set ||
    die ".env の LITELLM_SALT_KEY が空です。移行元に合わせた値を設定してください（docs/migration.md）。"

  ensure_project_is_this_repo
  [[ -n "$assume_yes" ]] || confirm

  step "DB を起動"
  docker compose up -d --wait db

  step "ダンプの目次を読めるかの確認"
  # dump-db.sh は pg_dump の出力をパイプで受けるため、ダンプにはデータの位置が記録されない。
  # 標準入力のように読み戻せない入力から読むと、目次と順番の違うデータを探せずに失敗することがある。
  # そのため、コンテナにファイルとしてコピーしてから読む。
  # EXIT の trap は main を抜けた後に動くため、コピー先はグローバル変数（定数）で持つ。
  trap 'docker compose exec -T db rm -f "$CONTAINER_DUMP_PATH" >/dev/null 2>&1 || true' EXIT
  local cp_output
  # 進捗の表示が多いため、失敗したときだけ表示する。
  cp_output="$(docker compose cp "$DUMP_FILE" "db:$CONTAINER_DUMP_PATH" 2>&1)" || {
    printf '%s\n' "$cp_output" >&2
    die "ダンプをコンテナにコピーできませんでした。"
  }
  docker compose exec -T db pg_restore --list "$CONTAINER_DUMP_PATH" >/dev/null ||
    die "ダンプの目次を読めませんでした。dump-db.sh で作ったファイルか確認してください。"

  step "LiteLLM と nginx を停止"
  docker compose stop nginx litellm

  step "DB を作り直す"
  docker compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE)" \
    -c "CREATE DATABASE $DB_NAME OWNER $DB_USER"

  step "リストア"
  # 移行元と DB のユーザー名が違っても使えるよう、所有者と権限は移行先のユーザーに揃える。
  # 1 つのトランザクションで行い、途中で失敗したら何も入れない。
  docker compose exec -T db pg_restore -U "$DB_USER" -d "$DB_NAME" \
    --no-owner --no-privileges --exit-on-error --single-transaction "$CONTAINER_DUMP_PATH" ||
    die "リストアに失敗しました。DB は空のままです。原因を取り除いてから、もう一度実行してください。"

  step "テーブルの件数（dump-db.sh の表示と比べる）"
  print_table_counts

  step "DB に保存された設定（通知やコールバックの設定があれば、移行先からも動く）"
  local config_params
  config_params="$(db_query 'SELECT param_name FROM "LiteLLM_Config" ORDER BY param_name' 2>/dev/null | strip_control_chars)" || config_params=""
  if [[ -n "$config_params" ]]; then
    printf '%s\n' "$config_params" | sed 's/^/  /'
    printf '  管理 UI の Settings で、通知（Slack・メールなど）とコールバックの設定を確認してください。\n'
  else
    printf '  （なし）\n'
  fi

  step "モデル名の重複"
  print_model_name_conflicts

  step "リストアが完了しました。"
  cat <<'EOF'
LiteLLM と nginx は停止しています。次の手順で起動してください（docs/migration.md）。
  1. .env の LITELLM_SALT_KEY が移行元に合っていることを確認する
  2. 新しいシェルで docker compose up -d --wait を実行する
     （起動時に、DB が新しいバージョンのスキーマにマイグレーションされる）
  3. 管理 UI で、チーム・キー・モデルが移行元と同じであることを確認する
EOF
}

main "$@"
