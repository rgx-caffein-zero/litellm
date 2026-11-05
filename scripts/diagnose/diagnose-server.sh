#!/usr/bin/env bash
#
# Claude Desktop / Cowork の推論が失敗するときに、サーバー側のどこで失敗しているかを調べる。
# LiteLLM を動かしているサーバーの、リポジトリのディレクトリで実行する。
# 社内 PC 側の確認は scripts/diagnose/diagnose-client.ps1。
#
# 「テスト接続と管理画面は使えるが、推論だけが失敗する」場合を主に想定している。
# テスト接続（GET /v1/models など）と推論（POST /v1/messages）では、通る経路が次のように違う。
#   - 推論だけが LiteLLM から Bedrock へ接続する（AWS の認証情報・IAM の権限・外向きのプロキシ）
#   - 推論はストリーミングで送られる（IAM の bedrock:InvokeModelWithResponseStream が別に必要）
#   - 推論ではモデル名・tools・thinking・anthropic-beta ヘッダーなどが Bedrock に渡る
#   - 推論のときだけ、キーのチームのモデルの許可と予算が確かめられる
#   - Cowork はアプリ本体とは別の環境から接続することがあり、プロキシやルート CA の扱いが違う
#
# 確かめること:
#   1. コンテナの状態
#   2. nginx に届いたリクエスト。テスト接続と推論を分けて数える
#   3. 失敗した推論のエラーの本文（LiteLLM の利用ログ LiteLLM_SpendLogs）と、LiteLLM のログのエラー
#   4. Bedrock への接続、AWS の認証情報、各モデルを呼ぶ権限（ストリーミングを含む。課金なし）
#   5. --inference: 推論の形（最小・ストリーミング・tools・thinking）と経路（直接・nginx 経由）を
#      変えて送り、どこで失敗するかを切り分ける（少額の利用料が発生する）
#   --follow: リアルタイムで監視する。起動したまま社内 PC で推論を実行すると、届いたリクエストとエラーを表示する
#
# 何も変更しない。キーや認証情報の値は表示しない（ログに含まれる sk-... と AKIA... は伏せる）。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_DIR="$REPO_ROOT/scripts/diagnose"
# nginx/default.conf の推論 API の location と合わせる
readonly INFERENCE_PATH_RE='^/(v1/)?(messages|chat/completions|completions|responses|embeddings|models|images|audio|moderations|rerank)(/|$)'

# 見つかった問題。最後に「考えられる原因」としてまとめて表示する
PROBLEMS=()

usage() {
  cat <<'EOF'
使い方: scripts/diagnose/diagnose-server.sh [--hours <時間>] [--inference]
        scripts/diagnose/diagnose-server.sh --follow

  --hours <時間>  ログを調べる期間（既定は 24 時間前から）
  --inference     推論の形と経路を変えて送り、どこで失敗するかを切り分ける（少額の利用料が発生する）
  --follow        リアルタイムで監視する。起動したまま社内 PC で推論を実行し、Ctrl-C で終了する

  何も変更しない。社内 PC 側の確認は scripts/diagnose/diagnose-client.ps1 を使う。
EOF
}

die() {
  printf 'エラー: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '\n== %s\n' "$*"
}

ok() {
  printf '  OK   %s\n' "$*"
}

ng() {
  printf '  NG   %s\n' "$1"
  PROBLEMS+=("$1${2:+ → $2}")
  if [[ -n "${2:-}" ]]; then
    printf '       → %s\n' "$2"
  fi
}

note() {
  printf '  注意 %s\n' "$*"
}

info() {
  printf '       %s\n' "$*"
}

# ログに含まれるキーとアクセスキー ID を伏せる（-u で 1 行ずつ出力する。--follow で使うため）
mask() {
  sed -u -E 's/sk-[A-Za-z0-9_-]+/sk-***/g; s/(AKIA|ASIA)[0-9A-Z]{16}/\1***/g; s#://[^/@ ]*@#://***@#g'
}

# 列の区切りは \x1f（空の列があっても read で詰められないよう、空白文字以外にする）
db_query() {
  docker compose exec -T db psql -X -A -t -q -F $'\x1f' -v ON_ERROR_STOP=1 -U litellm -d litellm -c "$1"
}

# scripts/diagnose/ の Python のファイルを、動いている LiteLLM のコンテナで実行する（標準入力で渡す）
run_in_litellm() {
  docker compose exec -T litellm python3 - "${@:2}" <"$SCRIPT_DIR/$1" 2>/dev/null
}

# HTTP ステータスから考えられる原因を出力する
status_hint() {
  local status="$1" path="$2"
  if [[ ! "$path" =~ $INFERENCE_PATH_RE && "$path" != /health/liveliness ]]; then
    case "$status" in
      403) printf 'nginx が遮断しています（推論 API 以外のパスは管理者の端末からだけ）。Gateway base URL の末尾に /v1 などを付けていないか確認する。Claude Desktop がこのパスを必要とするなら nginx/default.conf の推論 API の location に加える' ;;
      404) printf 'nginx で無効にしている機能のパスです' ;;
      *) printf '推論 API ではないパスです' ;;
    esac
    return
  fi
  case "$status" in
    400) printf 'リクエストの内容（モデル名・パラメーター）を LiteLLM か Bedrock が受け付けていない（手順 3 のエラーの本文を参照）' ;;
    401) printf 'モデル一覧は取れるのに推論だけ 401 なら、キーのチームで、Claude Desktop が要求したモデルが許可されていない可能性が高い（手順 3 のエラーの本文を参照）' ;;
    403) printf 'キーかチームが停止されているか、権限がない（手順 3 のエラーの本文を参照）' ;;
    404) printf 'Claude Desktop が要求したモデル名が、config.yaml にも管理 UI にもない' ;;
    422) printf 'チームの予算の上限に達している（budget_exceeded）' ;;
    429) printf 'レート制限（チームの RPM・TPM か、Bedrock のクォータ）' ;;
    499) printf '応答が終わる前に社内 PC が接続を切った（PC 側やその途中のプロキシのタイムアウトか、利用者の中断）' ;;
    500) printf 'LiteLLM か Bedrock のエラー（手順 3 のエラーの本文と、手順 4 の Bedrock の確認を参照）' ;;
    502) printf 'nginx が LiteLLM に接続できない（LiteLLM が起動していないか、作り直した後に nginx を再起動していない）' ;;
    504) printf 'LiteLLM の応答がタイムアウトした' ;;
    *) printf '' ;;
  esac
}

# エラーの本文から考えられる原因を出力する。先に当てはまったものを使う
error_hint() {
  local message="${1,,}"
  case "$message" in
    *"unable to locate credentials"* | *invalidclienttokenid* | *unrecognizedclient* | *"security token"* | *signaturedoesnotmatch* | *expiredtoken*)
      printf 'AWS の認証情報がない・無効・期限切れ。.env の AWS_ACCESS_KEY_ID・AWS_SECRET_ACCESS_KEY を確認し、新しいシェルで docker compose up -d --wait litellm で反映する' ;;
    *accessdenied* | *"not authorized"* | *"don't have access"* | *"do not have access"*)
      printf 'IAM の権限が足りない。bedrock:InvokeModel と bedrock:InvokeModelWithResponseStream（ストリーミング）の両方を、推論プロファイル（us.）とそれが使う全リージョンの基盤モデルに許可する。Bedrock コンソールでモデルの利用を有効にしているかも確認する' ;;
    *"model identifier is invalid"* | *resourcenotfound* | *"model not found"* | *"provided model identifier"*)
      printf 'Bedrock のモデル ID（推論プロファイル）が違う。litellm/config.yaml の model を確認する' ;;
    *"invalid model name"* | *"no deployments"* | *"not allowed to access model"* | *"team not allowed"* | *"key not allowed"* | *"only access models"* | *"model access"*)
      printf 'Claude Desktop が要求したモデル名が登録されていないか、キーのチームで許可されていない。エラーの本文のモデル名を config.yaml とチームの Models に揃える' ;;
    *budget*)
      printf 'チームの予算の上限に達している。管理 UI でチームの Max Budget を引き上げる' ;;
    *throttl* | *"too many"* | *"rate limit"* | *serviceunavailable* | *overloaded*)
      printf 'Bedrock のクォータかレート制限。AWS の Service Quotas を確認する' ;;
    *"extra inputs"* | *"not permitted"* | *"unexpected"* | *"invalid beta"* | *unsupported* | *"not supported"* | *validationexception* | *invalid_request*)
      printf 'Bedrock（または LiteLLM）がリクエストのパラメーターを受け付けていない。Claude Desktop が送る新しい機能のパラメーターに未対応の可能性がある。エラーの本文のパラメーター名を確認し、LiteLLM の更新を検討する' ;;
    *timeout* | *"timed out"* | *proxyerror* | *proxy* | *sslerror* | *certificate_verify_failed* | *connecterror* | *"connection"*)
      printf 'LiteLLM から Bedrock への通信の問題。社内プロキシが必要なら .env の LITELLM_HTTPS_PROXY。CERTIFICATE_VERIFY_FAILED ならプロキシが TLS を復号している（社内の CA をコンテナに入れる必要がある）' ;;
    *disconnect* | *cancel*)
      printf '応答が終わる前に社内 PC 側が接続を切った（PC 側やその途中のプロキシのタイムアウトか、利用者の中断）' ;;
    *) printf 'エラーの本文を確認する' ;;
  esac
}

check_containers() {
  step "1. コンテナの状態"
  local service id state
  for service in nginx litellm db; do
    id="$(docker compose ps --all --quiet "$service")"
    if [[ -z "$id" ]]; then
      ng "$service のコンテナがありません" "docker compose up -d --wait で起動する"
      continue
    fi
    state="$(docker inspect -f '{{.State.Status}}{{if .State.Health}} {{.State.Health.Status}}{{end}} 再起動 {{.RestartCount}} 回' "$id")"
    if [[ "$state" == "running healthy"* || ("$service" == nginx && "$state" == running*) ]]; then
      ok "$service: $state"
    else
      ng "$service: $state" "docker compose logs $service でエラーを確認する"
    fi
  done
}

check_nginx_requests() {
  local hours="$1"
  step "2. nginx に届いたリクエスト（${hours} 時間前から）"
  local lines requests
  # nginx の既定のアクセスログ（combined）から「接続元 時刻 メソッド パス ステータス User-Agent」を取り出す
  lines="$(docker compose logs --no-log-prefix --since "${hours}h" nginx 2>/dev/null |
    sed -nE 's/^([0-9a-fA-F:.]+) - [^ ]+ \[([^]]+)\] "([A-Z]+) ([^ ?"]*)[^"]*" ([0-9]{3}) [^"]*"[^"]*" "([^"]*)".*/\1\t\2\t\3\t\4\t\5\t\6/p')"
  requests="$(awk -F'\t' '$4 != "/health/liveliness"' <<<"$lines")"
  if [[ -z "$requests" ]]; then
    ng "テスト接続も推論も、リクエストが 1 件も届いていません" \
      "社内 PC からサーバーまでの経路の問題。テスト接続が成功しているなら、Claude Desktop の接続先が別のサーバーになっていないか確認する"
    return
  fi

  info "メソッド・パス・ステータス・User-Agent ごとの件数:"
  awk -F'\t' '{print $3, $4, $5, substr($6, 1, 50)}' <<<"$requests" | sort | uniq -c | sort -rn | head -20 | sed 's/^/         /'

  local posts
  posts="$(awk -F'\t' -v re="$INFERENCE_PATH_RE" '$3 == "POST" && $4 ~ re' <<<"$requests")"
  if [[ -z "$posts" ]]; then
    ng "テスト接続などの GET は届いていますが、推論（POST /v1/messages）は 1 件も届いていません" \
      "推論を送る側がサーバーに届いていない。Cowork はアプリ本体とは別の環境から接続することがあるため、社内 PC で diagnose-client.ps1 を実行し、ルート CA が「ローカル コンピューター」のストアにもあるか、プロキシの例外にサーバーの IP があるか、Cowork のログ（coworkd.log・cowork_vm_node.log）のエラーを確認する"
    return
  fi
  ok "推論のリクエストが $(grep -c . <<<"$posts") 件届いています"

  local failed status path count
  failed="$(awk -F'\t' '$5 !~ /^2/ {print $5 "\t" $4}' <<<"$requests" | sort | uniq -c | sort -rn)"
  while read -r count status path; do
    [[ -n "$status" ]] || continue
    ng "$status $path（$count 件）" "$(status_hint "$status" "$path")"
  done <<<"$failed"
  if [[ -n "$failed" ]]; then
    info "失敗したリクエストの直近 10 件（時刻 接続元 ステータス メソッド パス User-Agent）:"
    awk -F'\t' '$5 !~ /^2/ {print $2, $1, $5, $3, $4, substr($6, 1, 60)}' <<<"$requests" | tail -n 10 | sed 's/^/         /'
  fi
  if ! awk -F'\t' '$5 !~ /^2/' <<<"$posts" | grep -q .; then
    note "推論はすべて HTTP 200 で返っています。ストリーミングの途中で失敗している場合は、手順 3 の利用ログに記録されます"
  fi

  local errors
  errors="$(docker compose logs --no-log-prefix --since "${hours}h" nginx 2>/dev/null | grep -E '\[(error|crit|alert|emerg)\]' | mask | tail -n 5 || true)"
  if [[ -n "$errors" ]]; then
    ng "nginx のエラーログがあります" "下の内容を確認する（upstream への接続失敗やタイムアウトなら LiteLLM の停止・再作成・応答の遅れ）"
    cut -c1-300 <<<"$errors" | sed 's/^/         /'
  fi
}

check_failures() {
  local hours="$1"
  step "3. 失敗した推論のエラーの本文（${hours} 時間前から）"
  local window="\"startTime\" > (now() AT TIME ZONE 'UTC') - interval '$hours hours'"
  local succeeded
  succeeded="$(db_query "SELECT coalesce(model_group, model, '-') || ' ' || count(*) || ' 件（最新 ' || to_char(max(\"startTime\"), 'MM-DD HH24:MI') || ' UTC）'
    FROM \"LiteLLM_SpendLogs\" WHERE $window AND status = 'success' GROUP BY 1 ORDER BY 1" 2>/dev/null || true)"
  if [[ -n "$succeeded" ]]; then
    info "成功した推論（モデルごと）:"
    sed 's/^/         /' <<<"$succeeded"
  else
    info "成功した推論はありません"
  fi

  # 失敗した推論は status が success 以外で記録され、metadata.error_information にエラーの本文が入る
  local failures
  failures="$(db_query "SELECT to_char(max(\"startTime\"), 'MM-DD HH24:MI'), count(*),
      coalesce(model_group, model, '-'),
      coalesce(metadata->>'user_api_key_alias', '-') || ' / ' || coalesce(metadata->>'user_api_key_team_alias', '-'),
      left(coalesce(metadata->>'user_agent', '-'), 60),
      coalesce(nullif(metadata->'error_information'->>'error_code', ''), '-'),
      coalesce(nullif(metadata->'error_information'->>'error_class', ''), '-'),
      left(regexp_replace(regexp_replace(coalesce(metadata->'error_information'->>'error_message', ''),
        'sk-[A-Za-z0-9_-]+', 'sk-***', 'g'), '(AKIA|ASIA)[0-9A-Z]{16}', '\\1***', 'g'), 500)
    FROM \"LiteLLM_SpendLogs\" WHERE $window AND coalesce(status, '') <> 'success'
    GROUP BY 3, 4, 5, 6, 7, 8 ORDER BY 1 DESC LIMIT 10" 2>/dev/null || true)"
  if [[ -z "$failures" ]]; then
    ok "利用ログに失敗した推論はありません"
    info "（キーの認証・モデルの許可・予算のエラーは、利用ログに残らないことがあります。手順 2 のステータスと下の LiteLLM のログを見てください）"
  else
    local latest count model key agent code class message
    while IFS=$'\x1f' read -r latest count model key agent code class message; do
      ng "推論の失敗 ${count} 件（最新 ${latest} UTC）: モデル ${model}、HTTP ${code}、${class}" "$(error_hint "$class $message")"
      info "キー / チーム: ${key}、User-Agent: ${agent}"
      info "エラーの本文: ${message}"
    done <<<"$failures"
  fi

  local errors
  errors="$(docker compose logs --no-log-prefix --since "${hours}h" litellm 2>/dev/null | mask |
    grep -E 'ERROR|Exception|Error:|refused to start' |
    sed -E 's/\x1b\[[0-9;]*m//g; s/^[0-9:. -]+//; s/litellm_call_id=[^ ]+ - //' | cut -c1-300 | sort | uniq -c | sort -rn | head -10 || true)"
  if [[ -n "$errors" ]]; then
    info "LiteLLM のログのエラー（同じ内容をまとめた件数）:"
    sed 's/^/         /' <<<"$errors"
  fi
}

check_bedrock() {
  step "4. Bedrock への接続・認証情報・権限（課金なし）"
  local output kind result message stream_denied=""
  output="$(run_in_litellm bedrock_check.py || true)"
  if [[ -z "$output" ]]; then
    ng "確認できませんでした（LiteLLM のコンテナが動いていない可能性）" "docker compose ps で litellm が healthy か確認する"
    return
  fi
  while read -r kind result message; do
    case "$kind $result" in
      "REGION OK") ok "リージョン: $message" ;;
      "PROXY OK") ok "外向きのプロキシ: $message" ;;
      "REACH OK") ok "Bedrock に接続できます（$message）" ;;
      "REACH NG") ng "Bedrock に接続できません: $message" \
        "社内からインターネットへの出口にプロキシが必要なら .env の LITELLM_HTTPS_PROXY。CERTIFICATE_VERIFY_FAILED ならプロキシが TLS を復号している（社内の CA をコンテナに入れる必要がある）" ;;
      "CREDS OK") ok "AWS の認証情報: $message" ;;
      "CREDS NG") ng "AWS の認証情報: $message" \
        ".env の AWS_ACCESS_KEY_ID・AWS_SECRET_ACCESS_KEY を確認し、新しいシェルで docker compose up -d --wait litellm で反映する" ;;
      "MODEL OK") ok "${message}: 認証と権限は通っています" ;;
      "MODEL NG")
        [[ "$message" == *InvokeModelWithResponseStream:*AccessDenied* ]] && stream_denied=1
        ng "$message" "$(error_hint "$message")"
        ;;
    esac
  done <<<"$output"
  if [[ -n "$stream_denied" ]]; then
    note "ストリーミング（InvokeModelWithResponseStream）だけが拒否されています。ストリーミングしないリクエスト（テスト接続など）は成功し、推論だけが失敗する症状と一致します"
  fi
}

check_inference() {
  step "5. 推論の形と経路を変えた確認（少額の利用料が発生する）"
  info "形: minimal（最小）/ stream（ストリーミング）/ tools（tools・cache_control・beta ヘッダー）/ thinking（拡張思考）"
  info "経路: direct（LiteLLM に直接）/ nginx（nginx を通す）"
  local output route pattern model status result summary failed="" key
  output="$(run_in_litellm reproduce.py || true)"
  if [[ -z "$output" ]]; then
    ng "確認できませんでした（LiteLLM のコンテナが動いていない可能性）" "docker compose ps で litellm が healthy か確認する"
    return
  fi
  # 同じエラーの本文は 1 件にまとめ、どの形・経路・モデルで起きたかを並べる
  declare -A cases_by_error=()
  local -a errors=()
  while IFS=$'\t' read -r _ route pattern model status result summary; do
    if [[ "$result" == OK ]]; then
      ok "$route $pattern $model"
      continue
    fi
    failed=1
    key="HTTP $status: $summary"
    if [[ -z "${cases_by_error[$key]+set}" ]]; then
      errors+=("$key")
      cases_by_error[$key]="$route $pattern $model"
    else
      cases_by_error[$key]+=", $route $pattern $model"
    fi
  done < <(grep '^RESULT' <<<"$output")
  for key in "${errors[@]}"; do
    ng "$key" "$(error_hint "$key")"
    info "起きた確認: ${cases_by_error[$key]}"
  done
  if [[ -z "$failed" ]]; then
    note "サーバー内ではすべて成功しました。失敗の原因は、社内 PC からの経路（PC 側のプロキシ・Cowork の環境）か、Claude Desktop が送るリクエストの中身です。--follow で監視しながら社内 PC で推論を実行してください"
  fi
}

follow() {
  step "リアルタイムの監視（Ctrl-C で終了）"
  printf '社内 PC で推論を 1 回実行してください。nginx に届いたリクエストと、LiteLLM のエラーを表示します。\n'
  printf '何も表示されなければ、推論のリクエストはサーバーに届いていません。\n\n'
  docker compose logs --follow --since 0s nginx litellm 2>&1 |
    grep --line-buffered -v -E 'health/liveliness' |
    grep --line-buffered -E '"(GET|POST|PUT|DELETE) |ERROR|Exception|Error|Traceback|\[(error|warn)\]| [45][0-9]{2} ' |
    mask
}

main() {
  local hours=24 inference="" follow_mode=""
  while (($# > 0)); do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --hours)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || {
          usage >&2
          exit 2
        }
        hours="$2"
        shift
        ;;
      --inference) inference=1 ;;
      --follow) follow_mode=1 ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  cd "$REPO_ROOT"
  command -v docker >/dev/null 2>&1 || die "docker が見つかりません。"
  [[ -f .env ]] || die ".env がありません（README.md の「構築」）。"

  if [[ -n "$follow_mode" ]]; then
    follow
    return
  fi

  check_containers
  check_nginx_requests "$hours"
  check_failures "$hours"
  check_bedrock
  if [[ -n "$inference" ]]; then
    check_inference
  fi

  step "考えられる原因（${#PROBLEMS[@]} 件）"
  if ((${#PROBLEMS[@]} == 0)); then
    printf '  サーバー側では問題が見つかりませんでした。--inference で推論を送って確かめるか、--follow で監視しながら社内 PC で推論を実行してください。\n'
  else
    printf '  - %s\n' "${PROBLEMS[@]}"
  fi
}

main "$@"
