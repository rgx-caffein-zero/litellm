#!/usr/bin/env bash
#
# scripts/certs/ の各スクリプトが共有する関数。単体では実行しない。

# 二重に読み込まれたときに readonly の再定義でエラーにならないようにする。
if [[ -n "${CERTS_LIB_LOADED:-}" ]]; then
  return 0
fi
CERTS_LIB_LOADED=1

# ルート CA の許可範囲として受け付ける最も広いプレフィックス長。
# これより広い範囲（/0 など）を許すと、Name Constraints で被害を限定する意味がなくなる。
readonly CERTS_MIN_PREFIX=8

# リポジトリのルートを出力する。各スクリプトの既定のパス（certs/ など）はここを基準にする。
certs::repo_root() {
  (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
}

# エラーメッセージを表示して終了する。
certs::die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

# 引数が IPv4 アドレス（例: 10.1.2.3）なら 0 を返す。
# 先頭が 0 のオクテット（例: 010）は拒否する。実装によって 8 進数と解釈されるため。
certs::is_ipv4() {
  local ip="$1" octet
  local part='(0|[1-9][0-9]{0,2})'
  [[ "$ip" =~ ^$part\.$part\.$part\.$part$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    ((octet <= 255)) || return 1
  done
}

# IPv4 アドレスを 32 ビットの整数にして出力する。
certs::ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%d\n' $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

# ルート CA の許可範囲を検査し、CIDR 表記（例: 10.1.2.0/24）を、OpenSSL の nameConstraints が受け付ける
# 「アドレス/サブネットマスク」形式（例: 10.1.2.0/255.255.255.0）に変換して出力する。
# 次の場合は失敗する（検証の実装によって解釈が分かれる値や、広すぎる範囲を CA に入れないため）。
#   - プレフィックス長が CERTS_MIN_PREFIX より短い
#   - アドレスのホスト部が 0 でない（例: 10.1.2.3/24。ネットワークアドレス 10.1.2.0/24 を指定する）
certs::ca_range_to_ip_mask() {
  local cidr="$1" ip prefix mask
  [[ "$cidr" =~ ^([0-9.]+)/(0|[1-9][0-9]?)$ ]] || return 1
  ip="${BASH_REMATCH[1]}"
  prefix="${BASH_REMATCH[2]}"
  certs::is_ipv4 "$ip" || return 1
  ((prefix >= CERTS_MIN_PREFIX && prefix <= 32)) || return 1

  mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  (($(certs::ipv4_to_int "$ip") & ~mask & 0xFFFFFFFF)) && return 1

  printf '%s/%d.%d.%d.%d\n' "$ip" \
    $(((mask >> 24) & 255)) $(((mask >> 16) & 255)) $(((mask >> 8) & 255)) $((mask & 255))
}
