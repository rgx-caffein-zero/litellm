#!/usr/bin/env bash
#
# LiteLLM サーバー用のルート CA を作成する。
#
# このルート CA は社内 PC の「信頼されたルート証明機関」に入れるため、秘密鍵が
# 漏れると PC の通信の盗聴や、署名の偽造に悪用されるおそれがある。
# 被害を限定するため、CA 証明書に次の制約を入れる。
#   - Extended Key Usage: サーバー認証（serverAuth）だけ。コード署名・S/MIME・
#     クライアント認証などの証明書は、この CA の下では検証に通らない
#   - Name Constraints: 引数で指定した IP アドレス範囲だけを許可する。
#     DNS 名・メールアドレス・URI は、実在しないドメイン（.invalid）だけを許可して
#     実質的に禁止する（一般の Web サイトの偽証明書は作れない）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/certs/lib.sh
source "$SCRIPT_DIR/lib.sh"

readonly CA_VALID_DAYS=3650

usage() {
  cat <<EOF
使い方: scripts/certs/create-ca.sh <許可する IP 範囲（CIDR）> [出力先ディレクトリ]

  許可する IP 範囲  この CA が署名できる IP アドレスの範囲。
                    サーバーの IP だけに限定する場合は /32 を指定する（例: 10.1.2.3/32）。
                    サーバーの IP が変わる可能性がある場合は、そのネットワークを指定する（例: 10.1.2.0/24）。
                    プレフィックス長は /$CERTS_MIN_PREFIX 以上。ホスト部は 0 にする。
  出力先            既定はリポジトリの certs/ca（実行するディレクトリによらない）。
                    既に CA がある場合は上書きせずに終了する。

作成されるファイル:
  ca.crt  ルート CA 証明書。各 PC にインストールする（README.md の「社内 PC の設定」）
  ca.key  ルート CA の秘密鍵。サーバー証明書の発行後はサーバーから外し、安全な場所に保管する
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 2
  fi

  local cidr="$1" out_dir="${2:-$(certs::repo_root)/certs/ca}" ip_mask
  ip_mask="$(certs::ca_range_to_ip_mask "$cidr")" ||
    certs::die "IP 範囲は /$CERTS_MIN_PREFIX〜/32 の CIDR 表記で、ホスト部を 0 にして指定してください（例: 10.1.2.3/32、10.1.2.0/24）: $cidr"

  if [[ -e "$out_dir/ca.key" || -e "$out_dir/ca.crt" ]]; then
    certs::die "$out_dir に既に CA があります。作り直す場合は、既存のファイルを退避してから実行してください。"
  fi

  # 途中で失敗したときに鍵だけが残らないよう、作業ディレクトリで作ってから移動する。
  # EXIT の trap は main を抜けた後に動くため、パスはグローバル変数に持つ。
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  cat >"$WORK_DIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no

[dn]
CN = LiteLLM Gateway Root CA

[ca_ext]
basicConstraints     = critical, CA:TRUE, pathlen:0
keyUsage             = critical, keyCertSign, cRLSign
extendedKeyUsage     = serverAuth
subjectKeyIdentifier = hash
nameConstraints      = critical, permitted;IP:$ip_mask, permitted;DNS:.invalid, permitted;email:.invalid, permitted;URI:.invalid
EOF

  (
    umask 077
    openssl req -x509 -new \
      -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$WORK_DIR/ca.key" -out "$WORK_DIR/ca.crt" \
      -days "$CA_VALID_DAYS" -config "$WORK_DIR/ca.cnf" -extensions ca_ext
  )

  mkdir -p "$out_dir"
  chmod 700 "$out_dir"
  install -m 600 "$WORK_DIR/ca.key" "$out_dir/ca.key"
  install -m 644 "$WORK_DIR/ca.crt" "$out_dir/ca.crt"

  printf 'ルート CA を作成しました。\n'
  printf '  証明書: %s（各 PC にインストールする）\n' "$out_dir/ca.crt"
  printf '  秘密鍵: %s（サーバー証明書の発行後は安全な場所に移して保管する）\n' "$out_dir/ca.key"
  printf '  署名できる範囲: IP %s（用途はサーバー認証のみ）\n' "$cidr"
  # Windows の証明書画面は SHA-1 の拇印を表示する。各 PC でのインストール時に照合する。
  printf '  拇印（SHA-1。Windows での照合用）: '
  openssl x509 -in "$out_dir/ca.crt" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':'
}

main "$@"
