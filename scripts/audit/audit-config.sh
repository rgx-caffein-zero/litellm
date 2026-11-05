#!/usr/bin/env bash
#
# 今の環境の設定を点検し、次の 3 つに分けて表示する。リポジトリのディレクトリで実行する。
#   1. 現在の設定
#   2. 設定したほうがよいもの
#   3. 変更したほうがよいもの
# 判定の基準は README.md の運用の方針（予算はチームに設定する、モデル名の先頭は案件名にする など）。
#
# 読むだけで、何も変更しない（DB は読み取り専用で接続し、コンテナの起動・停止・作り直しもしない）。
# パスワードやキーなどの値は表示しない（文字数と、伏せ字のキー名 sk-...abcd だけを表示する）。
#
# 確かめる場所:
#   - .env、証明書、コンテナの状態（このスクリプト）
#   - config.yaml と DB（scripts/audit/audit_config.py。LiteLLM のイメージから作る一時的な
#     コンテナで、ファイルの今の内容と同じ環境変数を使って実行する）
# DB のコンテナが動いている必要がある（LiteLLM が止まっていても構わない）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly AUDIT_PY="$REPO_ROOT/scripts/audit/audit_config.py"
# サーバー証明書の残りの日数がこれより少なければ、更新を促す
readonly CERT_RENEW_DAYS=60

# 結果。要素は「分類<TAB>内容」
SET_ITEMS=()
ADD_ITEMS=()
CHANGE_ITEMS=()
# 「現在の設定」を表示する分類の順番（最初に出てきた順）
CATEGORIES=()
declare -A SEEN_CATEGORIES=()

usage() {
  cat <<'EOF'
使い方: scripts/audit/audit-config.sh

  今の環境の設定を点検し、「現在の設定」「設定したほうがよいもの」「変更したほうがよいもの」を表示する。
  何も変更しない。DB のコンテナが動いている必要がある。
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

# record <SET|ADD|CHANGE> <分類> <内容>
record() {
  local kind="$1" category="$2" message="$3"
  if [[ -z "${SEEN_CATEGORIES[$category]+set}" ]]; then
    SEEN_CATEGORIES[$category]=1
    CATEGORIES+=("$category")
  fi
  case "$kind" in
    SET) SET_ITEMS+=("$category"$'\t'"$message") ;;
    ADD) ADD_ITEMS+=("$category"$'\t'"$message") ;;
    CHANGE) CHANGE_ITEMS+=("$category"$'\t'"$message") ;;
  esac
}

# .env の値を出力する。Docker Compose と同じく、全体を囲む引用符は外す。
env_value() {
  local value
  value="$(sed -n "s/^$1=//p" .env | tail -n 1)"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$value"
}

env_names() {
  sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1" | sort -u
}

# 所有者以外が読み書きできる権限なら 0 を返す
is_group_or_other_accessible() {
  local mode
  mode="$(stat -c '%a' "$1")"
  (((8#$mode & 8#077) != 0))
}

# URL に含まれるユーザー名とパスワードを伏せる
mask_userinfo() {
  sed -E 's#://[^/@]*@#://***@#' <<<"$1"
}

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%s' "$(((a << 24) | (b << 16) | (c << 8) | d))"
}

# 2 つの IPv4 の範囲（CIDR）が重なれば 0 を返す
cidrs_overlap() {
  local a_ip="${1%/*}" b_ip="${2%/*}" a_len=32 b_len=32 len mask
  [[ "$1" == */* ]] && a_len="${1#*/}"
  [[ "$2" == */* ]] && b_len="${2#*/}"
  len=$((a_len < b_len ? a_len : b_len))
  mask=$(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
  (((($(ip_to_int "$a_ip") ^ $(ip_to_int "$b_ip")) & mask) == 0))
}

check_env_file() {
  local category=".env" name value
  if is_group_or_other_accessible .env; then
    record CHANGE "$category" ".env の権限が $(stat -c '%a' .env) です。所有者だけが読めるよう chmod 600 .env にしてください"
  else
    record SET "$category" "権限 $(stat -c '%a' .env)"
  fi

  # 秘密の値は、設定の有無と文字数だけを表示する
  for name in LITELLM_MASTER_KEY LITELLM_SALT_KEY POSTGRES_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    value="$(env_value "$name")"
    if [[ -n "$value" ]]; then
      record SET "$category" "$name: 設定あり（${#value} 文字）"
    else
      record SET "$category" "$name: 未設定"
    fi
  done
  for name in AWS_REGION_NAME HTTPS_PORT ADMIN_ALLOW_CIDRS LITELLM_HTTP_PROXY LITELLM_HTTPS_PROXY LITELLM_NO_PROXY; do
    value="$(env_value "$name")"
    record SET "$category" "$name: $(mask_userinfo "${value:-（空）}")"
  done

  # docker-compose.yml が参照しない変数は、.env に書いてもコンテナに届かない
  local extra
  extra="$(comm -13 <(env_names .env.example) <(env_names .env) | grep -v '^COMPOSE_' || true)"
  for name in $extra; do
    record CHANGE "$category" "$name は docker-compose.yml で使われていないため、コンテナに届きません。必要なら docker-compose.yml の environment に加え、不要なら削除してください"
  done

  value="$(env_value POSTGRES_PASSWORD)"
  # DATABASE_URL は postgresql://litellm:<パスワード>@db:5432/litellm の形で組み立てている
  if [[ "$value" =~ [^A-Za-z0-9._~-] ]]; then
    record CHANGE "$category" "POSTGRES_PASSWORD に URL の区切りと見なされる記号が含まれます。openssl rand -hex 24 で作り直し、scripts/migration/check-db.sh --fix-password で DB にも反映してください"
  elif ((${#value} > 0 && ${#value} < 16)); then
    record CHANGE "$category" "POSTGRES_PASSWORD が短すぎます（${#value} 文字）。openssl rand -hex 24 で作り直し、scripts/migration/check-db.sh --fix-password で DB にも反映してください"
  fi

  value="$(env_value AWS_ACCESS_KEY_ID)"
  if [[ -z "$value" || -z "$(env_value AWS_SECRET_ACCESS_KEY)" ]]; then
    record ADD "$category" "AWS_ACCESS_KEY_ID・AWS_SECRET_ACCESS_KEY を設定してください。ないと Bedrock のモデルへのリクエストが 500 エラーになります"
  elif [[ "$value" == ASIA* ]]; then
    record CHANGE "$category" "AWS_ACCESS_KEY_ID が一時的な認証情報（ASIA で始まる）です。期限が切れると Bedrock を使えなくなるため、IAM ユーザーのアクセスキー（AKIA で始まる）にしてください"
  fi

  check_admin_allow_cidrs "$(env_value ADMIN_ALLOW_CIDRS)"
}

check_admin_allow_cidrs() {
  local category=".env" cidrs="$1" cidr subnet subnets
  if [[ -z "$cidrs" ]]; then
    record ADD "$category" "ADMIN_ALLOW_CIDRS が空のため、どの PC からも管理 UI・管理 API に接続できます（マスターキーの認証だけ）。管理者の端末の IP 範囲を設定してください"
    return
  fi
  # 外からの接続元が Docker のブリッジのゲートウェイに見える構成では、重なる範囲を許可すると全 PC が管理系に届く
  subnets="$(docker network inspect $(docker network ls -q) -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null |
    tr ' ' '\n' | grep -E '^[0-9.]+/[0-9]+$' || true)"
  set -f
  for cidr in $cidrs; do
    if [[ ! "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
      record CHANGE "$category" "ADMIN_ALLOW_CIDRS の $cidr は IPv4 の範囲ではありません"
      continue
    fi
    if [[ "$cidr" == */* ]] && ((${cidr#*/} < 16)); then
      record CHANGE "$category" "ADMIN_ALLOW_CIDRS の $cidr は範囲が広すぎます。管理者の端末のセグメントだけにしてください"
    fi
    for subnet in $subnets; do
      if cidrs_overlap "$cidr" "$subnet"; then
        record CHANGE "$category" "ADMIN_ALLOW_CIDRS の $cidr が Docker のネットワーク（$subnet）と重なります。全 PC が管理系に届くおそれがあるため外してください"
      fi
    done
  done
  set +f
}

# 起動後に変更されたファイルがあれば、反映の方法を記録する
check_modified_after_start() {
  local service="$1" started="$2" how="$3" file
  shift 3
  for file in "$@"; do
    [[ -e "$file" ]] || continue
    if (($(stat -c '%Y' "$file") > started)); then
      record CHANGE "コンテナ" "$file が $service の起動後に変更されています。$how で反映してください"
    fi
  done
}

# 0 を返せば DB を確認できる
check_containers() {
  local category="コンテナ" service hash id working_dir state started_at started label db_running=""
  declare -A expected=()
  while read -r service hash; do
    expected[$service]="$hash"
  done < <(docker compose config --hash '*')

  for service in nginx litellm db; do
    id="$(docker compose ps --all --quiet "$service")"
    if [[ -z "$id" ]]; then
      record CHANGE "$category" "$service のコンテナがありません。docker compose up -d --wait で起動してください"
      continue
    fi
    working_dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$id")"
    # 同じプロジェクト名の別の環境を点検しないよう、このディレクトリのコンテナだけを見る
    [[ "$working_dir" == "$REPO_ROOT" ]] ||
      die "同じプロジェクト名のコンテナが、別のディレクトリ（$working_dir）にあります。COMPOSE_PROJECT_NAME を確認してください。"

    state="$(docker inspect -f '{{.State.Status}}{{if .State.Health}}（{{.State.Health.Status}}）{{end}}' "$id")"
    started_at="$(docker inspect -f '{{.State.StartedAt}}' "$id")"
    started="$(date -d "$started_at" +%s)"
    label="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$id")"
    record SET "$category" "$service: $state、起動 $(date -d "$started_at" '+%Y-%m-%d %H:%M')、イメージ $(docker inspect -f '{{.Config.Image}}' "$id" | sed 's/@sha256:.*//')"

    if [[ "$state" != running* ]]; then
      record CHANGE "$category" "$service が動いていません（$state）。docker compose up -d --wait で起動してください"
    elif [[ "$state" == *unhealthy* ]]; then
      record CHANGE "$category" "$service が unhealthy です。docker compose logs $service でエラーを確認してください"
    fi
    if [[ "$label" != "${expected[$service]:-}" ]]; then
      record CHANGE "$category" "$service: .env か docker-compose.yml の変更が反映されていません。新しいシェルで docker compose up -d --wait を実行してください（litellm を作り直したら docker compose restart nginx も）"
    fi
    case "$service" in
      litellm) check_modified_after_start litellm "$started" "docker compose restart litellm" litellm/config.yaml ;;
      nginx) check_modified_after_start nginx "$started" "docker compose restart nginx" \
        nginx/default.conf nginx/entrypoint/40-admin-allow.sh certs/server.crt certs/server.key ;;
      db) if [[ "$state" == running* ]]; then db_running=1; fi ;;
    esac
  done

  if docker compose exec -T nginx test -f /etc/nginx/admin-allow.conf 2>/dev/null; then
    record SET "$category" "nginx が管理系を許可している接続元: $(docker compose exec -T nginx cat /etc/nginx/admin-allow.conf | tr '\n' ' ')"
  fi
  [[ -n "$db_running" ]]
}

check_certificates() {
  local category="証明書" crt=certs/server.crt key=certs/server.key ca=certs/ca/ca.crt end days
  if [[ ! -f "$crt" ]]; then
    record CHANGE "$category" "$crt がありません。scripts/certs/issue-server-cert.sh で発行してください"
    return
  fi
  end="$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)"
  days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
  record SET "$category" "サーバー証明書: $(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')、期限 $(date -d "$end" +%F)（残り $days 日）"
  if ((days < 0)); then
    record CHANGE "$category" "サーバー証明書の期限が切れています。README.md の「サーバー証明書を更新する」で更新してください"
  elif ((days < CERT_RENEW_DAYS)); then
    record CHANGE "$category" "サーバー証明書の期限まで $days 日です。README.md の「サーバー証明書を更新する」で更新してください"
  fi

  if [[ -f "$ca" ]]; then
    end="$(openssl x509 -in "$ca" -noout -enddate | cut -d= -f2)"
    record SET "$category" "ルート CA: 期限 $(date -d "$end" +%F)、拇印（SHA-1） $(openssl x509 -in "$ca" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
    if ! openssl verify -CAfile "$ca" "$crt" >/dev/null 2>&1; then
      record CHANGE "$category" "サーバー証明書を $ca で検証できません。同じルート CA で発行し直してください"
    fi
  else
    record CHANGE "$category" "$ca がありません。社内 PC に配布したルート CA 証明書を置いてください（smoke-test.sh が使います）"
  fi

  if [[ -f "$key" ]]; then
    if [[ "$(openssl x509 -in "$crt" -noout -pubkey)" != "$(openssl pkey -in "$key" -pubout 2>/dev/null)" ]]; then
      record CHANGE "$category" "$key が $crt と対になっていません。issue-server-cert.sh で発行し直してください"
    fi
    if is_group_or_other_accessible "$key"; then
      record CHANGE "$category" "$key の権限が $(stat -c '%a' "$key") です。chmod 600 にしてください"
    fi
  fi
  if [[ -f certs/ca/ca.key ]]; then
    record CHANGE "$category" "ルート CA の秘密鍵 certs/ca/ca.key がサーバーにあります。安全な場所に移し、サーバーからは削除してください（README.md の「証明書の作成」）"
  fi
}

check_config_and_db() {
  local kind category message ended=""
  # Python のコードは標準入力で渡す。LiteLLM のログなどが混ざらないよう、決まった形の行だけを読む
  while IFS=$'\t' read -r kind category message; do
    case "$kind" in
      SET | ADD | CHANGE) record "$kind" "$category" "$message" ;;
      END) ended=1 ;;
    esac
  done < <(docker compose run --rm --no-deps -T --entrypoint python3 litellm - <"$AUDIT_PY" 2>/dev/null || true)
  [[ -n "$ended" ]] ||
    record CHANGE "DB" "config.yaml と DB を最後まで確認できませんでした。docker compose run --rm --no-deps --entrypoint python3 litellm - < $AUDIT_PY でエラーを確認してください"
}

# print_items <見出し> <要素...>。「現在の設定」と同じ分類の順に並べる
print_items() {
  local title="$1" category item
  shift
  printf '\n== %s（%s 件）\n' "$title" "$#"
  (($# > 0)) || {
    printf '  なし\n'
    return
  }
  for category in "${CATEGORIES[@]}"; do
    for item in "$@"; do
      if [[ "${item%%$'\t'*}" == "$category" ]]; then
        printf '  - [%s] %s\n' "$category" "${item#*$'\t'}"
      fi
    done
  done
}

print_report() {
  local category item
  printf '\n== 1. 現在の設定\n'
  for category in "${CATEGORIES[@]}"; do
    printf '\n[%s]\n' "$category"
    for item in "${SET_ITEMS[@]}"; do
      if [[ "${item%%$'\t'*}" == "$category" ]]; then
        printf '  %s\n' "${item#*$'\t'}"
      fi
    done
  done
  print_items "2. 設定したほうがよいもの" "${ADD_ITEMS[@]}"
  print_items "3. 変更したほうがよいもの" "${CHANGE_ITEMS[@]}"
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
  command -v openssl >/dev/null 2>&1 || die "openssl が見つかりません。"
  [[ -f .env ]] || die ".env がありません（README.md の「構築」）。"
  # シェルに環境変数として残っていると、Docker Compose は .env よりそちらを優先する。
  # どちらの値を点検したのか分からなくなるため、新しいシェルで実行してもらう。
  local name
  for name in $(env_names .env); do
    [[ -z "${!name+set}" ]] ||
      die "このシェルには $name が環境変数として残っています（set -a; . ./.env を実行したシェルなど）。新しいシェルで実行してください。"
  done

  printf '設定を点検しています（何も変更しません）...\n' >&2
  check_env_file
  if check_containers; then
    check_config_and_db
  else
    record CHANGE "DB" "DB のコンテナが動いていないため、config.yaml と DB を確認できませんでした。docker compose start db で起動してから実行してください"
  fi
  check_certificates
  print_report
}

main "$@"
