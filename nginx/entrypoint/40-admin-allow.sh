#!/bin/sh
#
# nginx コンテナの起動時に実行し、環境変数 ADMIN_ALLOW_CIDRS（空白区切りの IP 範囲）から、
# 管理系エンドポイントへの allow 行を生成する。生成したファイルは nginx/default.conf が include する。
#
# nginx 公式イメージは /docker-entrypoint.d/ のスクリプトをファイル名の順に実行する。
# 40- は、イメージ同梱のスクリプト（10-〜30-）の後に動かすための番号。
# 実行権限が必要（ないと nginx の entrypoint が読み飛ばし、include するファイルが
# できないため nginx が起動しない）。
#
# ADMIN_ALLOW_CIDRS は任意。未設定・空の場合は接続元を制限しない（allow all）。
# その場合も管理系は LiteLLM のマスターキーで保護されるが、起動時に警告を出す。
# 値が不正な場合はエラーで終了し、nginx を起動させない（意図しない設定で起動しないため）。
# 全開放（/0）を明示した値も不正として扱う（制限しないなら未設定にする）。
# テスト（tests/admin-allow.test.sh）では、ADMIN_ALLOW_CONF で出力先を差し替える。

set -eu

OUTPUT="${ADMIN_ALLOW_CONF:-/etc/nginx/admin-allow.conf}"

: >"$OUTPUT.tmp"
# 空白で分割するためにクォートしない。* などがファイル名に展開されないよう set -f にする。
set -f
for cidr in ${ADMIN_ALLOW_CIDRS:-}; do
  # 数字・ドット・スラッシュ以外を含む値は拒否する（nginx の設定への差し込みを防ぐ）。
  # アドレスとしての正しさは、起動時に nginx 自身が検査する。
  case "$cidr" in
    *[!0-9./]* | */0)
      echo "エラー: ADMIN_ALLOW_CIDRS に不正な値があります: $cidr" >&2
      rm -f "$OUTPUT.tmp"
      exit 1
      ;;
  esac
  echo "allow $cidr;" >>"$OUTPUT.tmp"
done
set +f

if [ ! -s "$OUTPUT.tmp" ]; then
  echo "allow all;" >"$OUTPUT.tmp"
  mv "$OUTPUT.tmp" "$OUTPUT"
  echo "警告: ADMIN_ALLOW_CIDRS が未設定のため、管理 UI・管理 API への接続元を制限しません（マスターキーによる認証のみ）。" >&2
  exit 0
fi
mv "$OUTPUT.tmp" "$OUTPUT"

echo "管理系エンドポイントを許可する IP 範囲: $ADMIN_ALLOW_CIDRS"
