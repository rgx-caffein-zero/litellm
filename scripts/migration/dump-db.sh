#!/usr/bin/env bash
#
# 移行元（現行）の LiteLLM の PostgreSQL をダンプする。移行元のサーバーで実行する。
# 移行の全体の手順は docs/migration.md。
#
# 移行元に影響を与えないことを最優先にしている。
#   - pg_dump は読み取り専用のトランザクションで動き、DB に書き込まない
#   - 取るロックは ACCESS SHARE だけなので、LiteLLM の通常の読み書きは止めない。
#     ただし、ダンプが終わるまで全テーブルのロックを持ち続けるため、その間にテーブル定義の
#     変更（LiteLLM の起動時のマイグレーションなど）が来ると、変更がロックを待ち、
#     その後ろに通常の読み書きが並んで移行元が止まる。ダンプ中は移行元の LiteLLM を再起動しない。
#     止まったときは Ctrl-C で中断する（移行元の DB で動いている pg_dump も終了させる）
#   - 開始時にロックをすぐに取れなければ、待たずに失敗する（--lock-wait-timeout）
#   - 出力先の空き容量が DB のサイズの 2 倍より少なければ始めない
#     （DB と同じディスクを使い切って、移行元を止めないため）
#   - コンテナの中にはファイルを作らない（標準出力でホストに書き出す）
#
# 移行元のサーバーにこのリポジトリがなくても、このファイルだけをコピーすれば動く。

set -euo pipefail

readonly LOCK_WAIT_TIMEOUT="10s"
readonly SPEND_LOGS_TABLE='"LiteLLM_SpendLogs"'
# 中断したときに、この名前の接続だけを終了させる
readonly DUMP_APP_NAME="litellm-migration-dump-$$"
# 件数を表示するテーブル（移行先の restore-db.sh の表示と比べる）
readonly COUNT_TABLES="LiteLLM_TeamTable LiteLLM_VerificationToken LiteLLM_ProxyModelTable LiteLLM_CredentialsTable LiteLLM_UserTable LiteLLM_BudgetTable"

usage() {
  cat <<'EOF'
使い方: dump-db.sh --db-container <DB のコンテナ> [オプション]

  --db-container <名前>       移行元の PostgreSQL のコンテナ名（docker ps で確認）。必須
  --litellm-container <名前>  移行元の LiteLLM のコンテナ名。指定すると、LITELLM_SALT_KEY を
                              設定しているかを表示する（値は表示しない）
  --db-user <ユーザー>         DB のユーザー。既定はコンテナの POSTGRES_USER（なければ postgres）
  --db-name <DB 名>            DB 名。既定はコンテナの POSTGRES_DB（なければユーザー名と同じ）
  --exclude-spend-logs        利用ログ（LiteLLM_SpendLogs）の中身を含めない。ダンプが小さく速くなる。
                              チームやキーの利用額は別のテーブルにあるので、予算は引き継がれる
  --output <ファイル>          出力先。既定は ./backups/litellm-source-<日時>.dump。
                              既にあるファイルは上書きしない
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

# 移行元のコンテナで psql を実行し、結果だけを出力する。
db_query() {
  docker exec "$DB_CONTAINER" psql -X -A -t -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "$1"
}

# コンテナの環境変数を出力する。設定されていなければ何も出力しない。
container_env() {
  docker exec "$1" printenv "$2" 2>/dev/null || true
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

# LiteLLM のコンテナに LITELLM_SALT_KEY が設定されているかを表示する。値は表示しない。
# 停止中のコンテナでも読めるよう、exec ではなく inspect で起動時の環境変数を見る。
print_salt_key_status() {
  local container="$1" env_lines
  env_lines="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" 2>/dev/null)" ||
    die "コンテナ $container の環境変数を読めませんでした（docker ps -a で名前を確認してください）。"
  if grep -q '^LITELLM_SALT_KEY=.' <<<"$env_lines"; then
    printf '  設定あり: 移行先の LITELLM_SALT_KEY を、移行元の LITELLM_SALT_KEY と同じ値にしてください。\n'
  elif grep -q '^LITELLM_SALT_KEY=$' <<<"$env_lines"; then
    printf '  空の値で設定されています。LiteLLM は空の文字列で暗号化しているため、移行先では認証情報を復号できません。\n'
    printf '  移行先の管理 UI で、認証情報を登録し直してください。\n'
  else
    printf '  設定なし: 移行先の LITELLM_SALT_KEY を、移行元の LITELLM_MASTER_KEY と同じ値にしてください。\n'
    printf '  （LITELLM_SALT_KEY がない場合、LiteLLM はマスターキーで認証情報を暗号化します）\n'
  fi
}

# Ctrl-C などで中断したときに呼ぶ。docker exec を止めても、コンテナの中の pg_dump は
# ロックを持ったまま動き続けるため、移行元の DB でこのダンプの接続を終了させる。
cancel_dump() {
  trap - INT TERM
  printf '\n中断しました。移行元の DB で動いている pg_dump を終了します。\n' >&2
  db_query "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$DUMP_APP_NAME'" >/dev/null ||
    printf '警告: pg_dump を終了できませんでした。移行元の DB の pg_stat_activity で、application_name が %s の接続を確認してください。\n' "$DUMP_APP_NAME" >&2
  wait "$DUMP_PID" 2>/dev/null || true
  exit 130
}

main() {
  DB_CONTAINER=""
  DB_USER=""
  DB_NAME=""
  local litellm_container="" exclude_spend_logs="" output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --db-container | --litellm-container | --db-user | --db-name | --output)
        [[ $# -ge 2 && -n "$2" ]] || {
          usage >&2
          exit 2
        }
        case "$1" in
          --db-container) DB_CONTAINER="$2" ;;
          --litellm-container) litellm_container="$2" ;;
          --db-user) DB_USER="$2" ;;
          --db-name) DB_NAME="$2" ;;
          --output) output="$2" ;;
        esac
        shift 2
        ;;
      --exclude-spend-logs)
        exclude_spend_logs=1
        shift
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  done
  [[ -n "$DB_CONTAINER" ]] || {
    usage >&2
    exit 2
  }

  command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
  [[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" == "true" ]] ||
    die "コンテナ $DB_CONTAINER が見つからないか、停止しています（docker ps で名前を確認してください）。"

  [[ -n "$DB_USER" ]] || DB_USER="$(container_env "$DB_CONTAINER" POSTGRES_USER)"
  [[ -n "$DB_USER" ]] || DB_USER="postgres"
  [[ -n "$DB_NAME" ]] || DB_NAME="$(container_env "$DB_CONTAINER" POSTGRES_DB)"
  [[ -n "$DB_NAME" ]] || DB_NAME="$DB_USER"

  [[ -n "$output" ]] || output="backups/litellm-source-$(date +%Y%m%d-%H%M%S).dump"
  [[ ! -e "$output" ]] || die "$output は既にあります。別の出力先を指定してください。"
  local out_dir
  out_dir="$(dirname "$output")"
  # ダンプにはキーのハッシュや暗号化された認証情報が含まれるため、所有者だけが読めるようにする。
  umask 077
  mkdir -p "$out_dir"

  step "移行元の DB（コンテナ $DB_CONTAINER、ユーザー $DB_USER、DB $DB_NAME）"
  local server_version db_bytes
  server_version="$(db_query "SHOW server_version")" ||
    die "DB に接続できません。--db-user と --db-name を確認してください。"
  db_bytes="$(db_query "SELECT pg_database_size(current_database())")" ||
    die "DB のサイズを取得できませんでした。"
  printf '  PostgreSQL %s、DB のサイズ %s MB\n' "$server_version" "$((db_bytes / 1024 / 1024))"

  step "出力先（$out_dir）の空き容量"
  local avail_bytes
  avail_bytes="$(($(df -Pk "$out_dir" | awk 'NR == 2 {print $4}') * 1024))"
  printf '  %s MB\n' "$((avail_bytes / 1024 / 1024))"
  # ダンプは圧縮されるので DB のサイズより小さくなる。書き終えた後も、DB のサイズ以上の
  # 空きが残るよう、DB のサイズの 2 倍を下限にする。
  ((avail_bytes > db_bytes * 2)) ||
    die "空き容量が DB のサイズの 2 倍より少ないため中止しました。別のディスクを --output で指定してください。"

  if [[ -n "$litellm_container" ]]; then
    step "LITELLM_SALT_KEY の設定（移行先の .env に設定する値が決まる）"
    print_salt_key_status "$litellm_container"
  fi

  step "テーブルの件数（目安。移行先で比べる）"
  print_table_counts

  step "ダンプ（$output）"
  local -a dump_opts=(--format=custom "--lock-wait-timeout=$LOCK_WAIT_TIMEOUT")
  if [[ -n "$exclude_spend_logs" ]]; then
    dump_opts+=("--exclude-table-data=$SPEND_LOGS_TABLE")
    printf '  利用ログ（LiteLLM_SpendLogs）の中身は含めません。\n'
  fi
  # 途中で失敗したときに不完全なファイルが残らないよう、一時ファイルに書いてから名前を変える。
  # EXIT の trap は main を抜けた後に動くため、パスはグローバル変数に持つ。
  PARTIAL_FILE="$output.partial"
  trap 'rm -f "$PARTIAL_FILE"' EXIT
  # バックグラウンドで実行して wait で待つ。前面で実行すると、終わるまで中断の trap が動かない。
  docker exec -e "PGAPPNAME=$DUMP_APP_NAME" "$DB_CONTAINER" \
    pg_dump -U "$DB_USER" -d "$DB_NAME" "${dump_opts[@]}" >"$PARTIAL_FILE" &
  DUMP_PID=$!
  trap cancel_dump INT TERM
  wait "$DUMP_PID" ||
    die "pg_dump に失敗しました。ロックを取れなかった場合は、LiteLLM の再起動などが終わってからやり直してください。"
  trap - INT TERM

  # 目次（TOC）を読めることだけを確かめる。データの中身は、移行先のリストアで確かめる。
  step "ダンプの目次を読めるかの確認"
  local toc
  toc="$(docker exec -i "$DB_CONTAINER" pg_restore --list <"$PARTIAL_FILE")" ||
    die "ダンプの目次を読めませんでした。"
  printf '  %s テーブル分のデータを含みます。\n' "$(grep -c ' TABLE DATA ' <<<"$toc" || true)"
  mv "$PARTIAL_FILE" "$output"

  step "完了しました。"
  printf '  ファイル: %s（%s KB）\n' "$output" "$(($(wc -c <"$output") / 1024))"
  printf '  SHA-256:  %s\n' "$(sha256sum "$output" | cut -d' ' -f1)"
  cat <<'EOF'

移行先のサーバーに、scp などの暗号化された経路でコピーしてください。
SHA-256 は、ファイルとは別の経路で（この画面から直接）控え、restore-db.sh の --sha256 に渡してください。
コピーした後は、このファイルを削除してください。
EOF
}

main "$@"
