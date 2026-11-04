#!/usr/bin/env bash
#
# DB に保存された認証情報（管理 UI で登録した Azure の API キーなど）を、古いソルトキーから
# .env の LITELLM_SALT_KEY（新しいソルトキー）へ暗号化し直す。移行先のリポジトリで実行する。
# 手順は README.md の「現行環境から移行する」。
#
# 移行元が LITELLM_SALT_KEY を設定せず、マスターキーで暗号化していた場合に使う。
# そのマスターキーが sk-1234 のような公開されている値だと、新しいバージョンの LiteLLM は
# 起動を拒否し、ソルトキーとして使い続けると DB の認証情報を誰でも復号できてしまう。
#
# 暗号化し直す処理と対象の列は、LiteLLM 自身の処理（litellm.proxy.db.master_key_migration の
# reencrypt_stored_values）をそのまま使う。LiteLLM の起動時の移行（LITELLM_MIGRATE_FROM_MASTER_KEY）は、
# ソルトキーを設定している構成では何もしないため、ここで 1 回だけ実行する。
#   - 1 つのトランザクションで行い、古いソルトキーで暗号化された値が 0 件になり、すべて新しい
#     ソルトキーで復号できることを確かめてからコミットする。確かめられなければ何も変えない
#   - 実行中に値が変わらないよう、LiteLLM を止めてから行う（終わっても止めたままにする）
#   - 古いソルトキーは画面で入力する（コマンドライン引数や画面には出さない）
#   - 表示するのは件数だけで、認証情報の値は表示しない

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# LiteLLM のコンテナの中で実行する。古いソルトキーは標準入力の 1 行目から、新しいソルトキーと
# 接続先は、LiteLLM と同じ環境変数（LITELLM_SALT_KEY、DATABASE_URL）から読む。
# 最後の行に結果を 1 つ出力する:
#   DONE <暗号化し直した件数>
#   NOTHING <新しいソルトキーで復号できる件数>（古いソルトキーで暗号化された値がない）
#   SAME（新旧のソルトキーが同じ）/ MISMATCH（確かめられなかったので元に戻した）
#   ERROR <例外の種類>（元に戻した）
# shellcheck disable=SC2016 # Python のコードなので、$（Prisma の引数の $1 など）はシェルで展開せずにそのまま渡す
readonly ROTATE_PY='
import asyncio, os, re, sys
import psycopg
from psycopg.rows import dict_row
from litellm.proxy.db.master_key_migration import count_values_encrypted_with, reencrypt_stored_values


class Database:
    """LiteLLM の SupportsRawQueries を psycopg で実装する（Prisma の $1 形式の引数を %s に変える）。"""

    def __init__(self, conn):
        self.conn = conn

    def _run(self, query, args):
        cur = self.conn.cursor(row_factory=dict_row)
        if args:
            numbers = [int(n) for n in re.findall(r"\$(\d+)", query)]
            query = re.sub(r"\$\d+", "%s", query.replace("%", "%%"))
            cur.execute(query, [args[n - 1] for n in numbers])
        else:
            cur.execute(query)
        return cur

    async def query_raw(self, query, *args):
        return self._run(query, args).fetchall()

    async def execute_raw(self, query, *args):
        return self._run(query, args).rowcount


async def main():
    old_key = sys.stdin.readline().rstrip("\n")
    new_key = os.environ["LITELLM_SALT_KEY"]
    if old_key == new_key:
        print("SAME")
        return
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        db = Database(conn)
        before_old = await count_values_encrypted_with(db, old_key)
        before_new = await count_values_encrypted_with(db, new_key)
        if before_old == 0:
            print("NOTHING", before_new)
            return
        migrated = await reencrypt_stored_values(db, from_key=old_key, to_key=new_key)
        after_old = await count_values_encrypted_with(db, old_key)
        after_new = await count_values_encrypted_with(db, new_key)
        if migrated != before_old or after_old != 0 or after_new != before_new + migrated:
            conn.rollback()
            print("MISMATCH")
            return
        conn.commit()
        print("DONE", migrated)


try:
    asyncio.run(main())
except Exception as e:
    # 本文には接続先などが含まれることがあるため、種類だけを出す（with を抜けるときにロールバックされる）
    print("ERROR", type(e).__name__)
'

usage() {
  cat <<'EOF'
使い方: scripts/migration/rotate-salt-key.sh

  事前に .env の LITELLM_SALT_KEY を新しい値にしておく（生成例: printf 'sk-%s\n' "$(openssl rand -hex 32)"）。
  実行すると古いソルトキー（移行元が暗号化に使っていた値）の入力を求め、DB の認証情報を
  新しいソルトキーで暗号化し直す。LiteLLM は止めたままになる。
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

# この環境のコンテナがあり、すべてこのディレクトリの docker-compose.yml から作られたことを確かめる。
# 違えば、別の環境の DB を書き換えてしまうので中止する。
ensure_project_is_this_repo() {
  local ids id working_dir
  ids="$(docker compose ps --all --quiet)" ||
    die "docker compose ps に失敗しました。別の環境を操作しないよう中止しました。"
  [[ -n "$ids" ]] ||
    die "この環境のコンテナがありません。restore-db.sh でリストアし、一度起動してから実行してください。"
  for id in $ids; do
    working_dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")" ||
      die "コンテナ $id のラベルを読めませんでした。"
    [[ "$working_dir" == "$REPO_ROOT" ]] ||
      die "同じプロジェクト名のコンテナが、別のディレクトリ（$working_dir）にあります。別の環境を操作しないよう中止しました。"
  done
}

# 古いソルトキーを読む。端末からは表示せずに入力してもらい、端末でなければ標準入力の 1 行目を使う。
read_old_salt_key() {
  local value
  if [[ -t 0 ]]; then
    printf '古いソルトキー（移行元の LITELLM_SALT_KEY。未設定だった場合は移行元の LITELLM_MASTER_KEY）を入力してください: ' >&2
    IFS= read -rs value
    printf '\n' >&2
  else
    IFS= read -r value || true
  fi
  printf '%s' "$value"
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    "") ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  cd "$REPO_ROOT"
  command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
  [[ -f .env ]] || die ".env がありません（README.md の「構築」）。"
  # シェルに環境変数として残っていると、Docker Compose は .env よりそちらを優先し、
  # 意図しない値で暗号化してしまう。新しいシェルで実行してもらう。
  [[ -z "${LITELLM_SALT_KEY+set}" ]] ||
    die "このシェルには LITELLM_SALT_KEY が環境変数として残っています（set -a; . ./.env を実行したシェルなど）。新しいシェルで実行してください。"

  ensure_project_is_this_repo

  local old_key
  old_key="$(read_old_salt_key)"
  [[ -n "$old_key" ]] || die "古いソルトキーが空です。"

  step "LiteLLM を停止"
  docker compose stop litellm

  step "DB を起動"
  docker compose up -d --wait db

  step "認証情報を新しいソルトキーで暗号化し直す"
  local result
  # 古いソルトキーをコマンドライン引数に出さないよう、標準入力で渡す。
  # printf は bash の組み込みコマンドなので、引数は ps に表示されない。
  result="$(printf '%s\n' "$old_key" |
    docker compose run --rm --no-deps -T --entrypoint python3 litellm -c "$ROTATE_PY" 2>/dev/null |
    tail -n 1)" || result=""

  case "$result" in
    "DONE "*)
      printf '  %s 件を暗号化し直しました。古いソルトキーで暗号化された値は残っていません。\n' "${result#DONE }"
      ;;
    "NOTHING "*)
      printf '  古いソルトキーで暗号化された値はありません（新しいソルトキーで復号できる値: %s 件）。\n' "${result#NOTHING }"
      printf '  0 件なら、入力した古いソルトキーが違う可能性があります。DB は変更していません。\n'
      exit 1
      ;;
    SAME)
      die ".env の LITELLM_SALT_KEY が、入力した古いソルトキーと同じです。.env を新しい値にしてから実行してください。"
      ;;
    MISMATCH)
      die "暗号化し直した結果を確かめられなかったため、元に戻しました。DB は変更していません。"
      ;;
    *)
      die "暗号化し直す処理を実行できませんでした（${result:-結果なし}）。DB は変更していません。scripts/migration/check-db.sh で DB に接続できるか確認してください。"
      ;;
  esac

  step "完了しました。"
  cat <<'EOF'
LiteLLM は停止しています。次の手順で確認してください。
  1. 新しいシェルで docker compose up -d --wait を実行する
  2. 管理 UI で Azure のモデルを開き、エラーにならないことを確認する
  3. 新しいソルトキーを含む .env をバックアップする（これより前の DB のバックアップは、古いソルトキーでないと復号できない）
EOF
}

main "$@"
