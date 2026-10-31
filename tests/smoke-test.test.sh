#!/usr/bin/env bash
#
# Tests for scripts/smoke-test.sh. None of these cases reach a server: the
# checks that need responses use a fake curl placed first on PATH.
# Usage: tests/smoke-test.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMOKE_TEST="$ROOT/scripts/smoke-test.sh"
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

readonly TEST_KEY="sk-test-key-must-not-leak"

# Creates ./bin/curl, a fake that answers by URL path with the contents of
# ./models.json (for /v1/models) and ./stream.txt (for /v1/messages), and
# appends its arguments to ./curl-args.log.
install_fake_curl() {
  mkdir -p bin
  cat >bin/curl <<'EOF_CURL'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >>"$dir/curl-args.log"
if [[ " $* " == *" -H @- "* ]]; then
  cat >/dev/null # headers given on stdin
fi
url=""
for arg in "$@"; do
  [[ "$arg" == https://* ]] && url="$arg"
done
case "$url" in
  */health/liveliness) printf '"I\x27m alive!"' ;;
  */v1/models) cat "$dir/models.json" ;;
  */v1/messages) cat "$dir/stream.txt" ;;
  *) exit 22 ;;
esac
EOF_CURL
  chmod +x bin/curl
  : >ca.crt
  printf '{"data":[{"id":"claude-sonnet-5"},{"id":"claude-opus-5-5"}]}' >models.json
  printf 'event: message_start\ndata: {}\n\nevent: message_stop\ndata: {}\n' >stream.txt
}

run_smoke_test() {
  PATH="$PWD/bin:$PATH" LITELLM_API_KEY="$TEST_KEY" CA_CERT=ca.crt "$SMOKE_TEST" "$@"
}

test_help_succeeds() {
  "$SMOKE_TEST" --help | grep -q 'LITELLM_API_KEY'
}

test_rejects_wrong_argument_count_with_usage_error() {
  local status=0
  "$SMOKE_TEST" >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_rejects_unknown_option() {
  local status=0
  LITELLM_API_KEY=dummy "$SMOKE_TEST" https://10.1.2.3 --unknown >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_rejects_plain_http_url() {
  : >ca.crt
  expect_fail env LITELLM_API_KEY=dummy CA_CERT=ca.crt "$SMOKE_TEST" http://10.1.2.3 2>err.log
  grep -q 'https://' err.log
}

test_requires_api_key() {
  : >ca.crt
  expect_fail env -u LITELLM_API_KEY CA_CERT=ca.crt "$SMOKE_TEST" https://10.1.2.3 2>err.log
  grep -q 'LITELLM_API_KEY' err.log
}

test_requires_ca_certificate() {
  expect_fail env LITELLM_API_KEY=dummy CA_CERT=missing.crt "$SMOKE_TEST" https://10.1.2.3 2>err.log
  grep -q 'missing.crt' err.log
}

test_succeeds_when_required_model_is_listed() {
  install_fake_curl
  run_smoke_test https://10.1.2.3 >out.log 2>&1
  grep -q 'すべての確認に成功しました' out.log
}

test_fails_when_required_model_is_missing() {
  install_fake_curl
  printf '{"data":[{"id":"claude-opus-5-5"}]}' >models.json
  expect_fail run_smoke_test https://10.1.2.3 >out.log 2>&1
  grep -q 'claude-sonnet-5 がありません' out.log
}

test_fails_with_message_when_model_list_is_empty() {
  install_fake_curl
  printf '{"data":[]}' >models.json
  expect_fail run_smoke_test https://10.1.2.3 >out.log 2>&1
  grep -q 'claude-sonnet-5 がありません' out.log
}

test_inference_succeeds_when_stream_completes() {
  install_fake_curl
  run_smoke_test https://10.1.2.3 --inference >out.log 2>&1
  grep -q 'すべての確認に成功しました' out.log
}

test_inference_fails_on_error_event() {
  install_fake_curl
  printf 'event: message_start\ndata: {}\n\nevent: error\ndata: {}\n' >stream.txt
  expect_fail run_smoke_test https://10.1.2.3 --inference >out.log 2>&1
  grep -q 'エラーが返りました' out.log
}

test_inference_fails_when_stream_is_cut_off() {
  install_fake_curl
  printf 'event: message_start\ndata: {}\n' >stream.txt
  expect_fail run_smoke_test https://10.1.2.3 --inference >out.log 2>&1
  grep -q 'message_stop がありません' out.log
}

test_api_key_is_not_passed_as_argument() {
  install_fake_curl
  run_smoke_test https://10.1.2.3 --inference >/dev/null 2>&1
  [[ -s curl-args.log ]]
  expect_fail grep -q "$TEST_KEY" curl-args.log
}

run_all_tests
