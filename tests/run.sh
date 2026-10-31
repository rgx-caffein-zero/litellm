#!/usr/bin/env bash
#
# Runs every tests/*.test.sh file. This is the quality gate's test step
# (HARNESS_TEST_CMD in .harness/project.env), so new test files are picked up
# without changing the harness configuration.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

failed_files=()
for test_file in "$TESTS_DIR"/*.test.sh; do
  printf '== %s\n' "${test_file#"$TESTS_DIR"/}"
  if ! bash "$test_file"; then
    failed_files+=("${test_file#"$TESTS_DIR"/}")
  fi
  printf '\n'
done

if ((${#failed_files[@]} > 0)); then
  printf 'Failed: %s\n' "${failed_files[*]}" >&2
  exit 1
fi
printf 'All test files passed.\n'
