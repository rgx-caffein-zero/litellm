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
#
# 実行には、この環境のコンテナが作られていればよい（LiteLLM が起動に失敗していても構わない）。
# 処理は LiteLLM のイメージから作る一時的なコンテナで行い、LiteLLM の本体は起動しないため。
#
# --check を付けると、DB を変えずに、暗号化された値の件数と、入力した候補の鍵それぞれで
# 復号できる件数だけを表示する（古いソルトキーが分からないときに使う）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT

# LiteLLM のコンテナの中で実行する。最初の引数でモードを選ぶ。新しいソルトキーと接続先は、
# LiteLLM と同じ環境変数（LITELLM_SALT_KEY、DATABASE_URL）から読む。
#
# rotate: 古いソルトキーを標準入力の 1 行目から読み、最後の行に結果を 1 つ出力する。
#   DONE <暗号化し直した件数>
#   NOTHING <新しいソルトキーで復号できる件数>（古いソルトキーで暗号化された値がない）
#   SAME（新旧のソルトキーが同じ）/ MISMATCH（確かめられなかったので元に戻した）
#   ERROR <例外の種類>（元に戻した）
# check: 候補の鍵を標準入力から 1 行に 1 つ読み、DB を変えずに次を出力する。
#   CIPHERTEXTS <暗号化されているように見える値の件数>
#   NEW <新しいソルトキーで復号できる件数>
#   KEY <候補の番号> <その鍵で復号できる件数>
# shellcheck disable=SC2016 # Python のコードなので、$（Prisma の引数の $1 など）はシェルで展開せずにそのまま渡す
readonly ROTATE_PY='
import asyncio, base64, os, re, sys
import psycopg
from psycopg.rows import dict_row
from litellm.proxy.common_utils.encrypt_decrypt_utils import V2_GCM_PREFIX
# 対象の列と行の取り出しは、暗号化し直す処理と同じものを使う（LiteLLM のバージョンは固定している）
from litellm.proxy.db.master_key_migration import (
    _rows_of,
    _secret_columns_in,
    count_values_encrypted_with,
    reencrypt_stored_values,
    replace_ciphertexts,
)

# nacl の暗号文は URL セーフな Base64 で、ノンス（24 バイト）と MAC（16 バイト）の 40 バイト以上になる
_LEGACY_CIPHERTEXT = re.compile(r"[A-Za-z0-9_-]+={0,2}")


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


def looks_encrypted(value):
    if value.startswith(V2_GCM_PREFIX):
        return True
    if not _LEGACY_CIPHERTEXT.fullmatch(value):
        return False
    try:
        return len(base64.urlsafe_b64decode(value)) >= 40
    except ValueError:
        return False


async def count_encrypted_looking(db):
    total = 0
    for secret_column in await _secret_columns_in(db):
        for row in await _rows_of(db, secret_column):
            total += replace_ciphertexts(row[secret_column.column], lambda v: v if looks_encrypted(v) else None)[1]
    return total


async def check():
    candidates = [line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")]
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        db = Database(conn)
        print("CIPHERTEXTS", await count_encrypted_looking(db))
        print("NEW", await count_values_encrypted_with(db, os.environ["LITELLM_SALT_KEY"]))
        for number, key in enumerate(candidates, start=1):
            print("KEY", number, await count_values_encrypted_with(db, key))
        conn.rollback()


async def rotate():
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
    asyncio.run(check() if sys.argv[1] == "check" else rotate())
except Exception as e:
    # 本文には接続先などが含まれることがあるため、種類だけを出す（with を抜けるときにロールバックされる）
    print("ERROR", type(e).__name__)
'

usage() {
  cat <<'EOF'
使い方: scripts/migration/rotate-salt-key.sh [--check]

  事前に .env の LITELLM_SALT_KEY を新しい値にしておく（生成例: printf 'sk-%s\n' "$(openssl rand -hex 32)"）。
  実行すると古いソルトキー（移行元が暗号化に使っていた値）の入力を求め、DB の認証情報を
  新しいソルトキーで暗号化し直す。LiteLLM は止めたままになる。
  LiteLLM が起動に失敗していても実行できる（リストア済みのコンテナがあればよい）。

  --check  DB を変えずに、暗号化された値の件数と、入力した候補の鍵それぞれで復号できる
           件数を表示する。候補は 1 つずつ入力し、空のまま Enter で終わる
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
    die "この環境のコンテナがありません。restore-db.sh でリストアしてから実行してください（LiteLLM が起動に失敗していても構いません）。"
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

# 候補の鍵を 1 行に 1 つずつ出力する。端末からは表示せずに入力してもらい、空行で終わる。
# 端末でなければ、標準入力の各行を使う。
read_candidate_keys() {
  local value number=1
  if [[ -t 0 ]]; then
    printf '候補の鍵を 1 つずつ入力してください（画面には表示されません。空のまま Enter で終わります）\n' >&2
    while :; do
      printf '  候補 %s: ' "$number" >&2
      IFS= read -rs value || break
      printf '\n' >&2
      [[ -n "$value" ]] || break
      printf '%s\n' "$value"
      number=$((number + 1))
    done
  else
    while IFS= read -r value; do
      [[ -z "$value" ]] || printf '%s\n' "$value"
    done
  fi
}

# LiteLLM のイメージから一時的なコンテナを作り、Python のコードを実行する。
# 鍵は標準入力で渡す（コマンドライン引数に出さない）。
run_in_litellm_image() {
  docker compose run --rm --no-deps -T --entrypoint python3 litellm -c "$ROTATE_PY" "$1" 2>/dev/null
}

check_keys() {
  local candidates output
  candidates="$(read_candidate_keys)"

  step "DB を起動"
  docker compose up -d --wait db

  step "暗号化された値の確認（DB は変更しません）"
  # printf は bash の組み込みコマンドなので、引数は ps に表示されない。
  output="$(printf '%s\n' "$candidates" | run_in_litellm_image check)" || output=""
  if [[ "$output" == *"ERROR "* || "$output" != *"CIPHERTEXTS "* ]]; then
    die "確認できませんでした（$(printf '%s' "$output" | tail -n 1)）。scripts/migration/check-db.sh で DB に接続できるか確認してください。"
  fi
  printf '%s\n' "$output" | while read -r kind first second; do
    case "$kind" in
      CIPHERTEXTS) printf '  暗号化されているように見える値:       %s 件\n' "$first" ;;
      NEW) printf '  .env の LITELLM_SALT_KEY で復号できる値: %s 件\n' "$first" ;;
      KEY) printf '  候補 %s で復号できる値:                %s 件\n' "$first" "$second" ;;
    esac
  done
  cat <<'EOF'

  暗号化されているように見える値が 0 件なら、暗号化し直すものはありません。
  候補で復号できた件数が、暗号化されているように見える値の件数と同じなら、その候補が古いソルトキーです。
EOF
}

main() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    --check | "") ;;
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

  if [[ "${1:-}" == "--check" ]]; then
    check_keys
    return
  fi

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
  result="$(printf '%s\n' "$old_key" | run_in_litellm_image rotate | tail -n 1)" || result=""

  case "$result" in
    "DONE "*)
      printf '  %s 件を暗号化し直しました。古いソルトキーで暗号化された値は残っていません。\n' "${result#DONE }"
      ;;
    "NOTHING "*)
      printf '  古いソルトキーで暗号化された値はありません（新しいソルトキーで復号できる値: %s 件）。\n' "${result#NOTHING }"
      printf '  DB は変更していません。--check を付けて実行すると、暗号化された値があるかと、どの鍵で復号できるかを確かめられます。\n'
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
