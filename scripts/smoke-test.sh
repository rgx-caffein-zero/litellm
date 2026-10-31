#!/usr/bin/env bash
#
# 起動した LiteLLM に HTTPS 経由で接続し、Claude Desktop / Cowork から使える
# 状態になっているかを確認する。
#
# 既定では推論を行わない（課金されない）確認だけを行う。
# --inference を付けると、claude-sonnet-5 に短いストリーミングリクエストを送り、
# Bedrock までの疎通も確認する（少額の利用料が発生する）。

set -euo pipefail

readonly REQUIRED_MODEL="claude-sonnet-5"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

usage() {
  cat <<'EOF'
使い方: LITELLM_API_KEY=<キー> scripts/smoke-test.sh <ベース URL> [--inference]

  ベース URL     Claude Desktop に設定する Gateway base URL（例: https://10.1.2.3）
  --inference    Bedrock への推論リクエストも送る（少額の利用料が発生する）

環境変数:
  LITELLM_API_KEY  確認に使うキー（マスターキーか、発行したキー）。必須
  CA_CERT          ルート CA 証明書のパス。既定はリポジトリの certs/ca/ca.crt
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  if [[ $# -lt 1 || $# -gt 2 || ($# -eq 2 && "$2" != "--inference") ]]; then
    usage >&2
    exit 2
  fi

  local base_url="${1%/}" inference="${2:-}"
  local ca_cert="${CA_CERT:-$REPO_ROOT/certs/ca/ca.crt}"
  # http だとキーが平文で送られるため、https 以外は受け付けない。
  [[ "$base_url" == https://* ]] || die "ベース URL は https:// で指定してください: $base_url"
  [[ -n "${LITELLM_API_KEY:-}" ]] || die "環境変数 LITELLM_API_KEY を設定してください。"
  [[ -f "$ca_cert" ]] || die "ルート CA 証明書が見つかりません: $ca_cert"

  # キーをコマンドライン引数に出さないよう、ヘッダーは標準入力から curl に渡す。
  local -a curl_opts=(--silent --show-error --fail-with-body --cacert "$ca_cert")
  local auth_header="Authorization: Bearer $LITELLM_API_KEY"

  step "HTTPS 接続とヘルスチェック（$base_url/health/liveliness）"
  curl "${curl_opts[@]}" "$base_url/health/liveliness"
  printf '\n'

  step "モデル一覧（/v1/models）に $REQUIRED_MODEL が含まれるか"
  local models
  models="$(curl "${curl_opts[@]}" -H @- "$base_url/v1/models" <<<"$auth_header")"
  # モデルが 0 件のときも下のメッセージを出せるよう、一覧の表示は失敗扱いにしない。
  printf '%s\n' "$models" | grep -o '"id": *"[^"]*"' | sed 's/"id": *//' || true
  grep -q "\"$REQUIRED_MODEL\"" <<<"$models" ||
    die "$REQUIRED_MODEL がありません。Auto モードに必要です（litellm/config.yaml と、キーに許可したモデルを確認してください）。"

  if [[ "$inference" == "--inference" ]]; then
    step "ストリーミング推論（/v1/messages、$REQUIRED_MODEL）"
    # 上流のエラーはストリームの途中で（HTTP 200 のまま）返ることがあるため、
    # ステータスに加えて、エラーイベントがないことと、最後まで届いたことを確認する。
    # 受信したイベントは tee で標準エラー出力にも逐次表示する。少しずつ表示されることが、
    # nginx がストリームをバッファリングしていないことの確認になる（docs/setup.md）。
    local stream
    stream="$(curl "${curl_opts[@]}" -N -H @- "$base_url/v1/messages" \
      -H "content-type: application/json" \
      -H "anthropic-version: 2023-06-01" \
      -d "{\"model\":\"$REQUIRED_MODEL\",\"max_tokens\":32,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}]}" \
      <<<"$auth_header" | tee /dev/stderr)"
    printf '\n'
    if grep -q '^event: error' <<<"$stream"; then
      die "ストリームの途中でエラーが返りました。"
    fi
    grep -q '^event: message_stop' <<<"$stream" || die "ストリームが最後まで届きませんでした（message_stop がありません）。"
  fi

  step "すべての確認に成功しました。"
}

main "$@"
