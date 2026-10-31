#!/usr/bin/env bash
#
# Shared helpers for tests/*.test.sh. Source this file, define test_* functions,
# then call run_all_tests at the end of the test file.

TEST_TMP_ROOT="$(mktemp -d)"
test_cleanup_commands=()

# Registers a command to run when the test file exits (for example, removing
# containers started for the whole file). Commands run in reverse order.
add_cleanup() {
  test_cleanup_commands+=("$1")
}

run_cleanup() {
  local i
  for ((i = ${#test_cleanup_commands[@]} - 1; i >= 0; i--)); do
    eval "${test_cleanup_commands[i]}" || true
  done
  rm -rf "$TEST_TMP_ROOT"
}
trap run_cleanup EXIT

tests_passed=0
tests_failed=0

# Fails when the given command succeeds. Use this instead of "! cmd", which
# never stops a function under "set -e".
expect_fail() {
  if "$@"; then
    printf 'expected failure but succeeded: %s\n' "$*" >&2
    return 1
  fi
}

# Runs a test function in its own directory and records the result.
# The subshell is not run inside a condition (if / || / &&), because bash
# ignores "set -e" there and only the last command would decide the result.
run_test() {
  local name="$1" dir status
  dir="$(mktemp -d "$TEST_TMP_ROOT/case.XXXX")"
  set +e
  (
    set -e
    cd "$dir"
    "$name"
  ) >"$dir/output.log" 2>&1
  status=$?
  set -e
  if ((status == 0)); then
    tests_passed=$((tests_passed + 1))
    printf 'ok   %s\n' "$name"
  else
    tests_failed=$((tests_failed + 1))
    printf 'FAIL %s\n' "$name" >&2
    sed 's/^/     | /' "$dir/output.log" >&2
  fi
}

# Runs every function whose name starts with test_ and exits non-zero if any failed.
run_all_tests() {
  local test_name
  for test_name in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$test_name"
  done
  printf '\n%d passed, %d failed\n' "$tests_passed" "$tests_failed"
  ((tests_failed == 0))
}
