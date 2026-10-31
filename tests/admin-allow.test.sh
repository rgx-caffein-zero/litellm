#!/usr/bin/env bash
#
# Tests for nginx/entrypoint/40-admin-allow.sh, which turns ADMIN_ALLOW_CIDRS into
# nginx "allow" lines. Runs the script with sh, as the nginx image does.
# Usage: tests/admin-allow.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN_ALLOW="$ROOT/nginx/entrypoint/40-admin-allow.sh"
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

run_admin_allow() {
  ADMIN_ALLOW_CONF="$PWD/admin-allow.conf" sh "$ADMIN_ALLOW"
}

test_writes_one_allow_line_per_range() {
  ADMIN_ALLOW_CIDRS="10.1.5.0/24 10.1.2.3/32" run_admin_allow
  [[ "$(cat admin-allow.conf)" == $'allow 10.1.5.0/24;\nallow 10.1.2.3/32;' ]]
}

test_allows_all_when_unset() {
  env -u ADMIN_ALLOW_CIDRS ADMIN_ALLOW_CONF="$PWD/admin-allow.conf" sh "$ADMIN_ALLOW" 2>warning.log
  [[ "$(cat admin-allow.conf)" == "allow all;" ]]
  grep -q '接続元を制限しません' warning.log
}

test_allows_all_when_empty() {
  ADMIN_ALLOW_CIDRS="" run_admin_allow 2>/dev/null
  [[ "$(cat admin-allow.conf)" == "allow all;" ]]
}

test_allows_all_when_only_whitespace() {
  ADMIN_ALLOW_CIDRS="   " run_admin_allow 2>/dev/null
  [[ "$(cat admin-allow.conf)" == "allow all;" && ! -e admin-allow.conf.tmp ]]
}

test_rejects_allow_all_range() {
  ADMIN_ALLOW_CIDRS="0.0.0.0/0" expect_fail run_admin_allow
  ADMIN_ALLOW_CIDRS="10.1.5.0/24 0.0.0.0/0" expect_fail run_admin_allow
  [[ ! -e admin-allow.conf ]]
}

test_does_not_expand_wildcards() {
  touch 10.0.0.1
  ADMIN_ALLOW_CIDRS="10.0.0.*" expect_fail run_admin_allow
  [[ ! -e admin-allow.conf ]]
}

test_rejects_injected_directive() {
  ADMIN_ALLOW_CIDRS="10.0.0.0/8;allow all" expect_fail run_admin_allow
  ADMIN_ALLOW_CIDRS="10.0.0.0/8 all" expect_fail run_admin_allow
  ADMIN_ALLOW_CIDRS="10.0.0.0/8 \$remote_addr" expect_fail run_admin_allow
  [[ ! -e admin-allow.conf && ! -e admin-allow.conf.tmp ]]
}

test_failure_keeps_previous_file() {
  ADMIN_ALLOW_CIDRS="10.1.5.0/24" run_admin_allow
  ADMIN_ALLOW_CIDRS="10.1.5.0/24 bad;" expect_fail run_admin_allow
  [[ "$(cat admin-allow.conf)" == "allow 10.1.5.0/24;" ]]
}

run_all_tests
