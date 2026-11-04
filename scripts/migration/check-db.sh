#!/usr/bin/env bash
#
# 移行先の LiteLLM が DB に接続できない・起動しないときに、原因を確かめる。
# 移行先のリポジトリのディレクトリで実行する。手順は README.md の「現行環境から移行する」。
#
# 表示するのは結果（OK / NG）、エラーの種類、マイグレーションの名前と件数だけで、
# パスワードなどの値は表示しない。確かめること:
#   1. .env の POSTGRES_PASSWORD（空でないか、URL にそのまま使えない記号を含まないか）
#   2. LiteLLM と同じ接続先（DATABASE_URL）で、DB に認証できるか
#   3. DB に記録されたマイグレーションの件数と、失敗・未完了のもの
#
# --fix-password を付けると、2 で認証できなかった場合に、DB の litellm ユーザーのパスワードを
# .env の POSTGRES_PASSWORD に合わせる。PostgreSQL のパスワードは DB を最初に作ったとき
# （初回の起動時）にしか設定されないため、その後 .env を変えると一致しなくなる。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
# docker-compose.yml の db サービスの設定と合わせる
readonly DB_USER="litellm"
readonly DB_NAME="litellm"

# LiteLLM のコンテナの中で、LiteLLM と同じ DATABASE_URL を使って認証を試す。
# 接続時のエラーには SQLSTATE が付かないため、本文から種類を判定する。本文には接続先
# （パスワードの一部を含むことがある）が含まれるため、表示するのは次の種類だけにする。
#   OK / NG auth（パスワードの不一致）/ NG url（パスワードの記号で URL が崩れている）/ NG other
readonly AUTH_CHECK_PY='
import os, psycopg
try:
    with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=10) as conn:
        conn.execute("SELECT 1")
    print("OK")
except psycopg.Error as e:
    message = str(e)
    if "password authentication failed" in message:
        print("NG auth")
    elif "failed to resolve host" in message or "invalid integer value" in message:
        print("NG url")
    else:
        print("NG other")
'

usage() {
  cat <<'EOF'
使い方: scripts/migration/check-db.sh [--fix-password]

  --fix-password  DB に認証できない場合に、DB の litellm ユーザーのパスワードを
                  .env の POSTGRES_PASSWORD に合わせる（DB のデータは変わらない）
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

# .env の POSTGRES_PASSWORD の値を出力する。Docker Compose と同じく、全体を囲む引用符は外す。
env_postgres_password() {
  local value
  value="$(sed -n 's/^POSTGRES_PASSWORD=//p' .env | tail -n 1)"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$value"
}

# LiteLLM と同じ接続先で認証を試し、OK か「NG <エラーの種類>」を出力する。
check_auth() {
  docker compose run --rm --no-deps -T --entrypoint python3 litellm -c "$AUTH_CHECK_PY" 2>/dev/null |
    tail -n 1
}

print_migration_status() {
  local total failed
  if ! total="$(db_query 'SELECT count(*) FROM _prisma_migrations' 2>/dev/null)"; then
    printf '  マイグレーションの記録（_prisma_migrations）がありません。\n'
    return
  fi
  printf '  記録されたマイグレーション: %s 件\n' "$total"
  failed="$(db_query "SELECT migration_name || '  開始 ' || to_char(started_at, 'YYYY-MM-DD HH24:MI') FROM _prisma_migrations WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL ORDER BY started_at")"
  if [[ -n "$failed" ]]; then
    printf '  失敗・未完了のマイグレーション:\n'
    printf '%s\n' "$failed" | sed 's/^/    /'
  else
    printf '  失敗・未完了のマイグレーション: なし\n'
  fi
}

main() {
  local fix_password=""
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    --fix-password) fix_password=1 ;;
    "") ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  [[ $# -le 1 ]] || {
    usage >&2
    exit 2
  }

  cd "$REPO_ROOT"
  command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
  [[ -f .env ]] || die ".env がありません（README.md の「構築」）。"
  # シェルに環境変数として残っていると、Docker Compose は .env よりそちらを優先する。
  # どちらの値で確かめたのか分からなくなるため、新しいシェルで実行してもらう。
  [[ -z "${POSTGRES_PASSWORD+set}" ]] ||
    die "このシェルには POSTGRES_PASSWORD が環境変数として残っています（set -a; . ./.env を実行したシェルなど）。新しいシェルで実行してください。"

  step "1. .env の POSTGRES_PASSWORD"
  local password
  password="$(env_postgres_password)"
  [[ -n "$password" ]] || die ".env の POSTGRES_PASSWORD が空です。"
  printf '  設定あり（%s 文字）\n' "${#password}"
  # DATABASE_URL は postgresql://litellm:<パスワード>@db:5432/litellm の形で組み立てている。
  # @ : / # % などを含むと、URL の区切りと見なされて正しく解釈されない。
  if [[ "$password" =~ [^A-Za-z0-9._~-] ]]; then
    printf '  注意: 英数字と . _ ~ - 以外の記号を含みます。DATABASE_URL が正しく解釈されないことがあります。\n'
    printf '        openssl rand -hex 24 で作り直し、--fix-password で DB にも反映することをおすすめします。\n'
  fi

  step "DB を起動"
  docker compose up -d --wait db

  step "2. LiteLLM と同じ接続先での認証"
  local result
  result="$(check_auth)"
  if [[ "$result" == "OK" ]]; then
    printf '  OK\n'
  elif [[ "$result" == "NG url" ]]; then
    printf '  NG: パスワードの記号のため、DATABASE_URL が正しく解釈されていません。\n'
    printf '  .env の POSTGRES_PASSWORD を openssl rand -hex 24 の値に変え、--fix-password を付けて実行してください。\n'
  elif [[ "$result" == "NG auth" ]]; then
    printf '  NG: パスワードが一致しません。\n'
    if [[ -z "$fix_password" ]]; then
      printf '  DB を最初に作った後に .env の POSTGRES_PASSWORD を変えると、この状態になります。\n'
      printf '  --fix-password を付けて実行すると、DB のパスワードを .env に合わせます。\n'
    else
      step "DB の $DB_USER ユーザーのパスワードを .env に合わせる"
      # パスワードを docker や psql のコマンドライン引数に出さないよう、SQL は標準入力で渡す。
      # printf は bash の組み込みコマンドなので、引数は ps に表示されない。
      printf "ALTER ROLE %s PASSWORD '%s';\n" "$DB_USER" "${password//\'/\'\'}" |
        docker compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U "$DB_USER" -d postgres
      result="$(check_auth)"
      [[ "$result" == "OK" ]] || die "パスワードを変更しましたが、まだ認証できません（$result）。"
      printf '  変更しました。認証できることを確かめました。\n'
    fi
  else
    printf '  NG: 接続できません（%s）。\n' "${result:-LiteLLM のコンテナを起動できません}"
    printf '  docker compose ps -a で db が healthy か、docker compose logs db にエラーがないかを確認してください。\n'
  fi

  step "3. マイグレーションの状態"
  print_migration_status

  if [[ "$result" == "OK" ]]; then
    step "DB には接続できます。"
    printf '新しいシェルで docker compose up -d --wait を実行してください。\n'
  else
    exit 1
  fi
}

main "$@"
