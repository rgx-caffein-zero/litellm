#!/usr/bin/env bash
#
# ルート CA（create-ca.sh で作成）を使って、LiteLLM サーバー（nginx）用の
# サーバー証明書を発行する。SAN にはサーバーの IP アドレスを入れる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/certs/lib.sh
source "$SCRIPT_DIR/lib.sh"

# Windows には上限がないが、Apple 製品が受け付ける最長の有効期間（825 日）に合わせておく。
# 管理者が macOS から管理 UI に接続する場合でも使えるようにするため。
readonly SERVER_VALID_DAYS=825

usage() {
  cat <<'EOF'
使い方: scripts/certs/issue-server-cert.sh <サーバーの IP アドレス> [CA のディレクトリ] [出力先ディレクトリ]

  サーバーの IP アドレス  Claude Desktop の Gateway base URL に指定する IP アドレス（例: 10.1.2.3）
  CA のディレクトリ       ca.crt と ca.key があるディレクトリ。既定はリポジトリの certs/ca
  出力先                  既定はリポジトリの certs。server.crt と server.key を作成（既存なら上書き）する
                          （既定のパスは、実行するディレクトリによらない）

作成したファイルは docker-compose.yml の nginx が読み込む。発行後は nginx を再起動する:
  docker compose restart nginx
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -lt 1 || $# -gt 3 ]]; then
    usage >&2
    exit 2
  fi

  local ip="$1" ca_dir="${2:-$(certs::repo_root)/certs/ca}" out_dir="${3:-$(certs::repo_root)/certs}"
  certs::is_ipv4 "$ip" || certs::die "IPv4 アドレスを指定してください: $ip"
  [[ -f "$ca_dir/ca.crt" && -f "$ca_dir/ca.key" ]] ||
    certs::die "$ca_dir に ca.crt と ca.key がありません。先に scripts/certs/create-ca.sh を実行してください。"

  # 証明書を作る前に docker compose up すると、Docker が server.crt / server.key という
  # 空のディレクトリを root で作る。そのままだと mv がディレクトリの中へ移動しようとして失敗する。
  local name
  for name in server.crt server.key; do
    [[ ! -d "$out_dir/$name" ]] ||
      certs::die "$out_dir/$name がディレクトリになっています（証明書を作る前に docker compose up を実行すると Docker が作成します）。docker compose down の後、sudo rm -r \"$out_dir/$name\" で削除してから再実行してください。"
  done
  mkdir -p "$out_dir"

  # EXIT の trap は main を抜けた後に動くため、作業ディレクトリはグローバル変数に持つ。
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  cat >"$WORK_DIR/server_ext.cnf" <<EOF
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = serverAuth
subjectAltName         = IP:$ip
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid
EOF

  # CN はホスト名に見えない文字列にする。OpenSSL などは、ホスト名に見える CN を
  # DNS 名として Name Constraints と照合するため、CA の制約に違反してしまう。
  (
    umask 077
    openssl req -new \
      -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$WORK_DIR/server.key" -out "$WORK_DIR/server.csr" \
      -subj "/CN=LiteLLM Gateway"
  )
  # シリアル番号のファイル（ca.srl）は作業ディレクトリに作り、CA のディレクトリに残さない。
  openssl x509 -req -in "$WORK_DIR/server.csr" \
    -CA "$ca_dir/ca.crt" -CAkey "$ca_dir/ca.key" -CAcreateserial -CAserial "$WORK_DIR/ca.srl" \
    -out "$WORK_DIR/server.crt" -days "$SERVER_VALID_DAYS" -extfile "$WORK_DIR/server_ext.cnf"

  # CA の Name Constraints の範囲外の IP だと、クライアントが接続を拒否する。
  # 配置する前に、ここで検出する（-purpose sslserver で、CA の用途制限との整合も確認する）。
  if ! openssl verify -CAfile "$ca_dir/ca.crt" -purpose sslserver -verify_ip "$ip" "$WORK_DIR/server.crt" >/dev/null; then
    certs::die "発行した証明書を CA で検証できません。IP アドレス $ip が CA の許可範囲に含まれているか確認してください。"
  fi

  # 鍵は nginx のマスタープロセス（root）が起動時に読むため 600 でよい。
  # 鍵と証明書の組が途中で食い違わないよう、出力先に一時ファイルとして置いてから mv で置き換える。
  install -m 600 "$WORK_DIR/server.key" "$out_dir/.server.key.tmp"
  install -m 644 "$WORK_DIR/server.crt" "$out_dir/.server.crt.tmp"
  mv "$out_dir/.server.key.tmp" "$out_dir/server.key"
  mv "$out_dir/.server.crt.tmp" "$out_dir/server.crt"

  printf 'サーバー証明書を発行しました（IP: %s、有効期間: %d 日）。\n' "$ip" "$SERVER_VALID_DAYS"
  printf '  証明書: %s\n' "$out_dir/server.crt"
  printf '  秘密鍵: %s\n' "$out_dir/server.key"
  printf '  有効期限: '
  openssl x509 -in "$out_dir/server.crt" -noout -enddate | cut -d= -f2
}

main "$@"
