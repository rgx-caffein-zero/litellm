#!/usr/bin/env bash
#
# Tests for scripts/migration/dump-db.sh and scripts/migration/restore-db.sh.
# None of these cases touch a real container: a fake docker placed first on PATH
# answers from files in the test directory and logs its arguments to ./docker.log.
# Usage: tests/migration.test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP_DB="$ROOT/scripts/migration/dump-db.sh"
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"

# Creates ./bin/docker. Its answers can be changed with these files:
#   not-running        the DB container is reported as stopped
#   db-bytes           size reported by pg_database_size (default 1000)
#   salt               value of LITELLM_SALT_KEY in the LiteLLM container (unset if missing)
#   inspect-env-fails  reading the LiteLLM container's environment fails
#   pg-dump-fails      pg_dump exits with an error after writing partial output
#   working-dir        compose working_dir label of the project's containers
#   no-containers      the compose project has no containers
#   ps-fails           docker compose ps fails
#   volumes            names of the project's volumes (none if missing)
#   list-fails         pg_restore --list fails (the dump is unreadable)
#   restore-fails      pg_restore fails
install_fake_docker() {
  mkdir -p bin
  cat >bin/docker <<'EOF_DOCKER'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >>"$dir/docker.log"
args=" $* "
case "$args" in
  *" inspect -f {{.State.Running}} "*)
    [[ -e "$dir/not-running" ]] && echo false || echo true ;;
  *"{{range .Config.Env}}"*)
    [[ -e "$dir/inspect-env-fails" ]] && exit 1
    echo PATH=/usr/bin
    if [[ -e "$dir/salt" ]]; then echo "LITELLM_SALT_KEY=$(cat "$dir/salt")"; fi ;;
  *"com.docker.compose.project.working_dir"*)
    cat "$dir/working-dir" ;;
  *" printenv POSTGRES_USER "*) echo llmproxy ;;
  *" printenv POSTGRES_DB "*) echo litellm ;;
  *"SHOW server_version"*) echo 15.19 ;;
  *"pg_database_size"*) cat "$dir/db-bytes" 2>/dev/null || echo 1000 ;;
  *"SELECT count(*)"*) echo 1 ;;
  *" pg_dump "*)
    printf 'PGDMP'
    if [[ -e "$dir/pg-dump-fails" ]]; then exit 1; fi ;;
  *" pg_restore --list "*)
    # dump-db.sh passes the dump on stdin (exec -i); restore-db.sh passes a path.
    if [[ "$args" == *" exec -i "* ]]; then cat >/dev/null; fi
    [[ -e "$dir/list-fails" ]] && exit 1
    printf '1; 0 1 TABLE DATA public t u\n' ;;
  *" pg_restore "*)
    if [[ -e "$dir/restore-fails" ]]; then exit 1; fi ;;
  *" compose ps --all --quiet "*)
    [[ -e "$dir/ps-fails" ]] && exit 1
    if [[ ! -e "$dir/no-containers" ]]; then echo container-1; fi ;;
  *" compose config "*) echo 'name: testproj' ;;
  *" volume ls "*)
    if [[ -e "$dir/volumes" ]]; then cat "$dir/volumes"; fi ;;
  *" compose "*) ;;
  *) exit 1 ;;
esac
EOF_DOCKER
  chmod +x bin/docker
}

run_dump_db() {
  PATH="$PWD/bin:$PATH" "$DUMP_DB" "$@"
}

# Copies restore-db.sh into ./repo so that its repository root is a test directory.
install_restore_repo() {
  mkdir -p repo/scripts/migration repo/litellm
  cp "$ROOT/scripts/migration/restore-db.sh" repo/scripts/migration/
  printf '  - model_name: claude-sonnet-5\n' >repo/litellm/config.yaml
  printf 'LITELLM_SALT_KEY=sk-salt\n' >repo/.env
  printf '%s\n' "$PWD/repo" >working-dir
  printf 'PGDMP' >source.dump
  DUMP_SHA256="$(sha256sum source.dump | cut -d' ' -f1)"
}

# stdin is closed so that a test never waits for input from the terminal.
run_restore_db() {
  PATH="$PWD/bin:$PATH" repo/scripts/migration/restore-db.sh "$@" </dev/null
}

# Prints the line number of the first docker call that matches the pattern.
docker_call_line() {
  grep -n -- "$1" docker.log | head -n 1 | cut -d: -f1
}

test_dump_help_succeeds() {
  "$DUMP_DB" --help | grep -q -- '--db-container'
}

test_dump_requires_db_container() {
  local status=0
  "$DUMP_DB" >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_dump_rejects_unknown_option() {
  local status=0
  "$DUMP_DB" --db-container db --unknown >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_dump_rejects_option_without_value() {
  local status=0
  "$DUMP_DB" --db-container >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_dump_writes_owner_only_file_with_lock_timeout() {
  install_fake_docker
  run_dump_db --db-container old-db --output out/source.dump >/dev/null
  [[ "$(cat out/source.dump)" == "PGDMP" ]]
  [[ "$(stat -c %a out/source.dump)" == "600" ]]
  grep -q 'pg_dump -U llmproxy -d litellm --format=custom --lock-wait-timeout=' docker.log
  expect_fail grep -q 'exclude-table-data' docker.log
}

test_dump_names_its_connection_so_it_can_be_cancelled() {
  install_fake_docker
  run_dump_db --db-container old-db --output source.dump >/dev/null
  grep -q 'exec -e PGAPPNAME=litellm-migration-dump-[0-9]* old-db pg_dump ' docker.log
}

test_dump_uses_given_user_and_database() {
  install_fake_docker
  run_dump_db --db-container old-db --db-user admin --db-name proxy --output source.dump >/dev/null
  grep -q 'pg_dump -U admin -d proxy ' docker.log
}

test_dump_excludes_spend_logs_when_requested() {
  install_fake_docker
  run_dump_db --db-container old-db --exclude-spend-logs --output source.dump >/dev/null
  grep -q -- '--exclude-table-data="LiteLLM_SpendLogs"' docker.log
}

test_dump_never_overwrites_existing_file() {
  install_fake_docker
  printf 'keep' >source.dump
  expect_fail run_dump_db --db-container old-db --output source.dump 2>err.log
  [[ "$(cat source.dump)" == "keep" ]]
  expect_fail grep -q 'pg_dump' docker.log
}

test_dump_stops_when_container_is_not_running() {
  install_fake_docker
  : >not-running
  expect_fail run_dump_db --db-container old-db --output source.dump 2>err.log
  grep -q 'old-db' err.log
  expect_fail grep -q 'pg_dump' docker.log
}

test_dump_stops_when_free_space_is_less_than_twice_the_database() {
  install_fake_docker
  local avail_bytes
  avail_bytes="$(($(df -Pk . | awk 'NR == 2 {print $4}') * 1024))"
  # Fits the free space once, but would leave less than the database size free.
  printf '%s' $((avail_bytes * 2 / 3)) >db-bytes
  expect_fail run_dump_db --db-container old-db --output source.dump >/dev/null 2>err.log
  grep -q '空き容量' err.log
  expect_fail grep -q 'pg_dump' docker.log
}

test_dump_removes_partial_file_on_failure() {
  install_fake_docker
  : >pg-dump-fails
  expect_fail run_dump_db --db-container old-db --output source.dump >/dev/null 2>err.log
  [[ ! -e source.dump && ! -e source.dump.partial ]]
}

test_dump_reports_salt_key_without_printing_it() {
  install_fake_docker
  printf 'sk-secret-salt' >salt
  run_dump_db --db-container old-db --litellm-container old-llm --output source.dump >out.log
  grep -q '設定あり' out.log
  expect_fail grep -q 'sk-secret-salt' out.log
}

test_dump_tells_to_use_master_key_when_salt_key_is_unset() {
  install_fake_docker
  run_dump_db --db-container old-db --litellm-container old-llm --output source.dump >out.log
  grep -q '設定なし' out.log
  grep -q 'LITELLM_MASTER_KEY' out.log
}

test_dump_warns_when_salt_key_is_empty() {
  install_fake_docker
  : >salt
  run_dump_db --db-container old-db --litellm-container old-llm --output source.dump >out.log
  grep -q '空の値' out.log
  expect_fail grep -q '設定なし' out.log
}

test_dump_stops_when_salt_key_cannot_be_read() {
  install_fake_docker
  : >inspect-env-fails
  expect_fail run_dump_db --db-container old-db --litellm-container old-llm --output source.dump >out.log 2>err.log
  grep -q 'old-llm' err.log
  expect_fail grep -q '設定なし' out.log
  expect_fail grep -q 'pg_dump' docker.log
}

test_restore_help_succeeds() {
  "$ROOT/scripts/migration/restore-db.sh" --help | grep -q 'LITELLM_SALT_KEY'
}

test_restore_rejects_wrong_arguments() {
  local status=0
  "$ROOT/scripts/migration/restore-db.sh" a.dump --sha256 abc --force >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_restore_requires_sha256() {
  local status=0
  "$ROOT/scripts/migration/restore-db.sh" a.dump --yes >/dev/null 2>&1 || status=$?
  ((status == 2))
}

test_restore_requires_existing_dump_file() {
  install_fake_docker
  install_restore_repo
  expect_fail run_restore_db missing.dump --sha256 "$DUMP_SHA256" --yes 2>err.log
  grep -q 'missing.dump' err.log
}

test_restore_stops_when_sha256_does_not_match() {
  install_fake_docker
  install_restore_repo
  expect_fail run_restore_db source.dump --sha256 0000 --yes 2>err.log
  grep -q 'SHA-256' err.log
  [[ ! -e docker.log ]]
}

test_restore_accepts_uppercase_sha256() {
  install_fake_docker
  install_restore_repo
  run_restore_db source.dump --sha256 "$(printf '%s' "$DUMP_SHA256" | tr 'a-f' 'A-F')" --yes >/dev/null
}

test_restore_requires_salt_key_in_env_file() {
  install_fake_docker
  install_restore_repo
  printf 'LITELLM_SALT_KEY=""\n' >repo/.env
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes 2>err.log
  grep -q 'LITELLM_SALT_KEY' err.log
  [[ ! -e docker.log ]]
}

test_restore_asks_for_confirmation_without_yes() {
  install_fake_docker
  install_restore_repo
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" 2>err.log
  grep -q -- '--yes' err.log
  expect_fail grep -q 'DROP DATABASE' docker.log
}

test_restore_stops_when_project_belongs_to_another_directory() {
  install_fake_docker
  install_restore_repo
  printf '/srv/current-litellm\n' >working-dir
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes 2>err.log
  grep -q '/srv/current-litellm' err.log
  expect_fail grep -q -e 'compose stop' -e 'DROP DATABASE' docker.log
}

test_restore_stops_when_compose_ps_fails() {
  install_fake_docker
  install_restore_repo
  : >ps-fails
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes 2>err.log
  expect_fail grep -q -e 'compose up' -e 'DROP DATABASE' docker.log
}

test_restore_stops_when_only_volumes_of_the_project_exist() {
  install_fake_docker
  install_restore_repo
  : >no-containers
  printf 'testproj_postgres_data\n' >volumes
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes 2>err.log
  grep -q 'testproj_postgres_data' err.log
  expect_fail grep -q -e 'compose up' -e 'DROP DATABASE' docker.log
}

test_restore_runs_on_a_new_project_without_containers_or_volumes() {
  install_fake_docker
  install_restore_repo
  : >no-containers
  run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes >/dev/null
  grep -q 'DROP DATABASE' docker.log
}

test_restore_does_not_touch_database_when_dump_is_unreadable() {
  install_fake_docker
  install_restore_repo
  : >list-fails
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes >/dev/null 2>err.log
  expect_fail grep -q -e 'compose stop' -e 'DROP DATABASE' docker.log
}

test_restore_reports_failure_of_restore() {
  install_fake_docker
  install_restore_repo
  : >restore-fails
  expect_fail run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes >/dev/null 2>err.log
  grep -q 'リストアに失敗しました' err.log
}

test_restore_checks_dump_then_stops_then_recreates_then_restores() {
  install_fake_docker
  install_restore_repo
  run_restore_db source.dump --sha256 "$DUMP_SHA256" --yes >/dev/null
  local list stop drop restore
  list="$(docker_call_line 'pg_restore --list')"
  stop="$(docker_call_line 'compose stop nginx litellm')"
  drop="$(docker_call_line 'DROP DATABASE IF EXISTS litellm WITH (FORCE)')"
  restore="$(docker_call_line 'pg_restore -U litellm -d litellm --no-owner --no-privileges --exit-on-error --single-transaction')"
  [[ -n "$list" && -n "$stop" && -n "$drop" && -n "$restore" ]]
  ((list < stop && stop < drop && drop < restore))
  # LiteLLM must stay stopped until the salt key has been checked.
  expect_fail grep -q 'compose up -d --wait$' docker.log
  expect_fail grep -q 'compose start' docker.log
}

run_all_tests
