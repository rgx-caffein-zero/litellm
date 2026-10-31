#!/usr/bin/env bash
#
# Integration tests for the access control in nginx/default.conf and
# nginx/entrypoint/40-admin-allow.sh.
# Starts the nginx image pinned in docker-compose.yml with the real config, in
# front of a stub upstream that answers 200 with the path it received.
# Skipped when docker is not available.
# Usage: tests/nginx.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  printf 'skip: docker is not available\n'
  exit 0
fi

NGINX_IMAGE="$(awk '$1 == "image:" && $2 ~ /^nginx:/ {print $2; exit}' "$ROOT/docker-compose.yml")"
NAME="litellm-nginx-test-$$"
WORK="$TEST_TMP_ROOT/nginx"
mkdir -p "$WORK"

# Runs a fixture setup command, showing its output only when it fails
# (fixture code runs outside run_test, which would otherwise show it).
setup() {
  if ! "$@" >"$WORK/setup.log" 2>&1; then
    printf 'fixture setup failed: %s\n' "$*" >&2
    cat "$WORK/setup.log" >&2
    exit 1
  fi
}

# Starts an nginx container under test on the fixture network and prints its name.
# Extra arguments are passed to docker run (for example, -d or -p).
start_nginx() {
  local name="$1" admin_cidrs="$2"
  shift 2
  docker run --name "$name" --network "$NAME" -e "ADMIN_ALLOW_CIDRS=$admin_cidrs" \
    -v "$ROOT/nginx/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$ROOT/nginx/entrypoint/40-admin-allow.sh:/docker-entrypoint.d/40-admin-allow.sh:ro" \
    -v "$WORK/server.crt:/etc/nginx/certs/server.crt:ro" \
    -v "$WORK/server.key:/etc/nginx/certs/server.key:ro" \
    "$@" "$NGINX_IMAGE" >/dev/null
  add_cleanup "docker rm -f $name >/dev/null 2>&1"
}

# Prints the https base URL of a started nginx container once it answers,
# or shows its logs and exits when it does not become ready.
wait_until_ready() {
  local name="$1" base
  base="https://127.0.0.1:$(docker port "$name" 443/tcp | head -n1 | cut -d: -f2)"
  for _ in $(seq 1 50); do
    if curl -s -o /dev/null --cacert "$WORK/ca/ca.crt" "$base/health/liveliness"; then
      printf '%s\n' "$base"
      return 0
    fi
    sleep 0.2
  done
  printf 'nginx container %s did not become ready:\n' "$name" >&2
  docker logs "$name" >&2 || true
  exit 1
}

# Fixture: certificates for 127.0.0.1 (with the same permissions as in
# production), a stub upstream reachable as "litellm", and three nginx instances:
#   - DENIED_BASE: the admin range never matches the test client
#   - ADMIN_BASE:  the admin range is the address the test client connects from
#     (connections to a published port on 127.0.0.1 arrive from the network gateway)
#   - OPEN_BASE:   ADMIN_ALLOW_CIDRS is empty, so the admin endpoints are not restricted
setup "$ROOT/scripts/certs/create-ca.sh" 127.0.0.1/32 "$WORK/ca"
setup "$ROOT/scripts/certs/issue-server-cert.sh" 127.0.0.1 "$WORK/ca" "$WORK"
cat >"$WORK/stub.conf" <<'EOF'
server {
    listen 4000;
    location / {
        return 200 "upstream:$request_uri";
    }
}
EOF

setup docker network create "$NAME"
add_cleanup "docker network rm $NAME >/dev/null 2>&1"
setup docker run -d --name "$NAME-stub" --network "$NAME" --network-alias litellm \
  -v "$WORK/stub.conf:/etc/nginx/conf.d/default.conf:ro" "$NGINX_IMAGE"
add_cleanup "docker rm -f $NAME-stub >/dev/null 2>&1"

GATEWAY="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "$NAME")"
start_nginx "$NAME-denied" 192.0.2.1/32 -d -p 127.0.0.1::443
start_nginx "$NAME-admin" "$GATEWAY/32" -d -p 127.0.0.1::443
start_nginx "$NAME-open" "" -d -p 127.0.0.1::443
DENIED_BASE="$(wait_until_ready "$NAME-denied")"
ADMIN_BASE="$(wait_until_ready "$NAME-admin")"
OPEN_BASE="$(wait_until_ready "$NAME-open")"

# Sends a request exactly as written (--path-as-is: no client-side path
# normalization, so bypass attempts reach nginx unchanged).
request() {
  local base="$1" method="$2" path="$3"
  shift 3
  curl -s --path-as-is --cacert "$WORK/ca/ca.crt" -X "$method" "$@" "$base$path"
}

expect_status() {
  local expected="$1" base="$2" method="$3" path="$4" actual
  actual="$(request "$base" "$method" "$path" -o /dev/null -w '%{http_code}')"
  if [[ "$actual" != "$expected" ]]; then
    printf '%s %s%s: expected %s, got %s\n' "$method" "$base" "$path" "$expected" "$actual" >&2
    return 1
  fi
}

# Starts nginx in the background and prints "running" when it is still up after
# a few seconds (that is, it started successfully), or "exited <status>".
# The container joins the fixture network, so the upstream name resolves and
# only the ADMIN_ALLOW_CIDRS value can make startup fail. Its logs are saved to
# ./startup.log and the container is removed here: test functions run in a
# subshell, so cleanup registered with add_cleanup would not reach the parent.
startup_result() {
  local name="$1" admin_cidrs="$2" result
  start_nginx "$name" "$admin_cidrs" -d
  sleep 3
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name")" == "true" ]]; then
    result="running"
  else
    result="exited $(docker inspect -f '{{.State.ExitCode}}' "$name")"
  fi
  docker logs "$name" >startup.log 2>&1 || true
  docker rm -f "$name" >/dev/null
  printf '%s\n' "$result"
}

test_public_endpoints_reach_upstream() {
  expect_status 200 "$DENIED_BASE" GET /health/liveliness
  expect_status 200 "$DENIED_BASE" GET /v1/models
  expect_status 200 "$DENIED_BASE" GET /models
  expect_status 200 "$DENIED_BASE" POST /v1/messages
  expect_status 200 "$DENIED_BASE" POST '/v1/messages?beta=true'
  expect_status 200 "$DENIED_BASE" POST /v1/messages/count_tokens
  expect_status 200 "$DENIED_BASE" POST /v1/chat/completions
  expect_status 200 "$DENIED_BASE" POST /chat/completions
  [[ "$(request "$DENIED_BASE" POST /v1/messages)" == "upstream:/v1/messages" ]]
}

test_admin_endpoints_are_denied_outside_admin_range() {
  expect_status 403 "$DENIED_BASE" GET /ui/
  expect_status 403 "$DENIED_BASE" POST /key/generate
  expect_status 403 "$DENIED_BASE" POST /team/new
  expect_status 403 "$DENIED_BASE" POST /model/new
  expect_status 403 "$DENIED_BASE" GET /health
  expect_status 403 "$DENIED_BASE" POST /bedrock/model/claude-sonnet-5/invoke
  expect_status 403 "$DENIED_BASE" GET /v1/messagesX
}

test_admin_endpoints_reach_upstream_from_admin_range() {
  expect_status 200 "$ADMIN_BASE" GET /ui/
  expect_status 200 "$ADMIN_BASE" POST /key/generate
  [[ "$(request "$ADMIN_BASE" POST /team/new)" == "upstream:/team/new" ]]
}

test_admin_endpoints_are_open_when_admin_range_is_unset() {
  expect_status 200 "$OPEN_BASE" GET /ui/
  [[ "$(request "$OPEN_BASE" POST /team/new)" == "upstream:/team/new" ]]
  expect_status 400 "$OPEN_BASE" GET '/ui/../v1/models'
}

test_unnormalized_paths_cannot_bypass_admin_restriction() {
  expect_status 400 "$DENIED_BASE" POST '/bedrock/model/x/invoke%2F..%2F..%2F..%2F..%2Fv1/messages'
  expect_status 400 "$DENIED_BASE" GET '/ui/../v1/models'
  expect_status 400 "$DENIED_BASE" GET '/ui/%2e%2e/v1/models'
  expect_status 400 "$DENIED_BASE" GET '//v1/models'
  expect_status 400 "$DENIED_BASE" GET '/v1/./models'
  expect_status 400 "$DENIED_BASE" GET '/v1/%6dodels'
}

test_disabled_features_are_not_found_even_from_admin_range() {
  expect_status 404 "$ADMIN_BASE" POST /moyai/connect/start
  expect_status 404 "$ADMIN_BASE" POST /moyai/connect/exchange
  expect_status 404 "$ADMIN_BASE" POST /v1/moyai/connect/exchange
  expect_status 404 "$ADMIN_BASE" GET /lens
  expect_status 404 "$ADMIN_BASE" GET /lens/service
  expect_status 404 "$ADMIN_BASE" GET /auto_router/availability
  expect_status 404 "$ADMIN_BASE" GET /public/autorouter_presets
  expect_status 404 "$ADMIN_BASE" GET /public/complexity_router/fuse_presets
  expect_status 404 "$ADMIN_BASE" GET /ui/moyai/
  expect_status 404 "$ADMIN_BASE" GET /ui/lens/
  expect_status 404 "$OPEN_BASE" POST /moyai/connect/exchange
  expect_status 404 "$DENIED_BASE" POST /moyai/connect/exchange
}

test_disabled_features_match_on_normalized_path() {
  expect_status 404 "$ADMIN_BASE" POST '/%6doyai/connect/exchange'
  expect_status 404 "$ADMIN_BASE" POST '/ui/../moyai/connect/exchange'
  expect_status 404 "$ADMIN_BASE" POST '//lens/service'
}

test_paths_sharing_a_prefix_with_disabled_features_reach_upstream() {
  expect_status 200 "$ADMIN_BASE" GET /lensX
  expect_status 200 "$ADMIN_BASE" GET /public/model_hub
  expect_status 200 "$ADMIN_BASE" GET /ui/models-and-endpoints/
}

test_valid_admin_range_starts_nginx() {
  # Control for test_invalid_admin_range_prevents_startup: the same setup with a
  # valid value must start, so that a failure there is caused by the value.
  [[ "$(startup_result "$NAME-valid" 10.0.0.0/8)" == "running" ]]
}

test_invalid_admin_range_prevents_startup() {
  [[ "$(startup_result "$NAME-invalid" '10.0.0.0/8;allow all')" == "exited 1" ]]
  grep -q 'ADMIN_ALLOW_CIDRS に不正な値があります' startup.log
}

run_all_tests
