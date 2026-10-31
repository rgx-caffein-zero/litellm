#!/usr/bin/env bash
#
# Shared helpers for the harness scripts.
#
# Source this file; do not execute it. Compatible with bash 3.2 (macOS default),
# so it avoids associative arrays, `mapfile`, and `${var,,}`.

if [[ -n "${HARNESS_LIB_LOADED:-}" ]]; then
  return 0
fi
HARNESS_LIB_LOADED=1

# Value that disables a step explicitly in .harness/project.env.
readonly HARNESS_DISABLED="-"

# Steps that resolve to project commands. "secrets" is handled by scan-secrets.sh.
# Used by the scripts that source this file.
# shellcheck disable=SC2034
readonly HARNESS_COMMAND_STEPS="format format_fix lint typecheck test build"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  readonly _HARNESS_RED=$'\033[31m'
  readonly _HARNESS_GREEN=$'\033[32m'
  readonly _HARNESS_YELLOW=$'\033[33m'
  readonly _HARNESS_DIM=$'\033[2m'
  readonly _HARNESS_RESET=$'\033[0m'
else
  readonly _HARNESS_RED=""
  readonly _HARNESS_GREEN=""
  readonly _HARNESS_YELLOW=""
  readonly _HARNESS_DIM=""
  readonly _HARNESS_RESET=""
fi

# --- Logging --------------------------------------------------------------------

harness::info() { printf '%s[harness]%s %s\n' "$_HARNESS_DIM" "$_HARNESS_RESET" "$*" >&2; }
harness::ok() { printf '%s[harness]%s %s\n' "$_HARNESS_GREEN" "$_HARNESS_RESET" "$*" >&2; }
harness::warn() { printf '%s[harness] warning:%s %s\n' "$_HARNESS_YELLOW" "$_HARNESS_RESET" "$*" >&2; }
harness::error() { printf '%s[harness] error:%s %s\n' "$_HARNESS_RED" "$_HARNESS_RESET" "$*" >&2; }

harness::die() {
  harness::error "$*"
  exit 1
}

# --- Environment ------------------------------------------------------------------

harness::has() { command -v "$1" >/dev/null 2>&1; }

# Prints the repository root, or the current directory outside a git repository.
harness::root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# Loads .harness/project.env if present. Values already set in the environment win,
# so a single run can be overridden with e.g. `HARNESS_TEST_CMD=... check.sh test`.
harness::load_config() {
  local config
  config="$(harness::root)/.harness/project.env"
  [[ -f "$config" ]] || return 0

  local saved
  saved="$(env | grep -E '^HARNESS_[A-Z_]+=' || true)"
  # shellcheck source=/dev/null
  source "$config"

  local line
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      export "${line?}"
    fi
  done <<<"$saved"
}

# Prints the name of the config variable for a step: format_fix -> HARNESS_FORMAT_FIX_CMD.
harness::step_var() {
  printf 'HARNESS_%s_CMD' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}

# --- Ecosystem detection ------------------------------------------------------------

# Prints one detected ecosystem per line, based on manifest files in the given directory.
harness::detect_ecosystems() {
  local root="$1"

  [[ -f "$root/package.json" ]] && echo node
  if [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/setup.cfg" ||
    -f "$root/requirements.txt" ]]; then
    echo python
  fi
  [[ -f "$root/go.mod" ]] && echo go
  [[ -f "$root/Cargo.toml" ]] && echo rust
  if [[ -f "$root/gradlew" || -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]]; then
    echo gradle
  elif [[ -f "$root/pom.xml" ]]; then
    echo maven
  fi
  if compgen -G "$root/*.sln" >/dev/null || compgen -G "$root/*.csproj" >/dev/null; then
    echo dotnet
  fi
  [[ -f "$root/Gemfile" ]] && echo ruby
  [[ -f "$root/composer.json" ]] && echo php
  return 0
}

# --- Node.js ------------------------------------------------------------------------

_harness_node_pm() {
  local root="$1"
  if [[ -f "$root/pnpm-lock.yaml" ]]; then
    echo pnpm
  elif [[ -f "$root/yarn.lock" ]]; then
    echo yarn
  elif [[ -f "$root/bun.lockb" || -f "$root/bun.lock" ]]; then
    echo bun
  else
    echo npm
  fi
}

# Prints the command that runs a locally installed package binary.
_harness_node_exec() {
  case "$1" in
    pnpm) echo "pnpm exec" ;;
    yarn) echo "yarn" ;;
    bun) echo "bunx" ;;
    *) echo "npx --no-install" ;;
  esac
}

# Prints the first script name (of the given candidates) defined in package.json.
_harness_node_script() {
  local root="$1" name
  shift
  for name in "$@"; do
    if grep -Eq "\"${name}\"[[:space:]]*:" "$root/package.json"; then
      # npm init writes a placeholder test script that always fails; treat it as absent.
      if [[ "$name" == "test" ]] && grep -q 'no test specified' "$root/package.json"; then
        continue
      fi
      echo "$name"
      return 0
    fi
  done
  return 1
}

_harness_node_cmd() {
  local root="$1" step="$2" pm exec script
  pm="$(_harness_node_pm "$root")"
  exec="$(_harness_node_exec "$pm")"

  case "$step" in
    format)
      if script="$(_harness_node_script "$root" format:check fmt:check prettier:check)"; then
        echo "$pm run $script"
      elif [[ -f "$root/biome.json" || -f "$root/biome.jsonc" ]]; then
        echo "$exec biome format ."
      elif [[ -x "$root/node_modules/.bin/prettier" ]]; then
        echo "$exec prettier --check ."
      fi
      ;;
    format_fix)
      if script="$(_harness_node_script "$root" format fmt format:fix)"; then
        echo "$pm run $script"
      elif [[ -f "$root/biome.json" || -f "$root/biome.jsonc" ]]; then
        echo "$exec biome format --write ."
      elif [[ -x "$root/node_modules/.bin/prettier" ]]; then
        echo "$exec prettier --write ."
      fi
      ;;
    lint)
      if script="$(_harness_node_script "$root" lint)"; then
        echo "$pm run $script"
      elif [[ -f "$root/biome.json" || -f "$root/biome.jsonc" ]]; then
        echo "$exec biome lint ."
      fi
      ;;
    typecheck)
      if script="$(_harness_node_script "$root" typecheck type-check check-types tsc)"; then
        echo "$pm run $script"
      elif [[ -f "$root/tsconfig.json" ]]; then
        echo "$exec tsc --noEmit"
      fi
      ;;
    test)
      if script="$(_harness_node_script "$root" test)"; then
        echo "$pm run $script"
      fi
      ;;
    build)
      if script="$(_harness_node_script "$root" build)"; then
        echo "$pm run $script"
      fi
      ;;
  esac
}

# --- Python -------------------------------------------------------------------------

# Prints the prefix that runs a tool inside the project's environment.
_harness_python_runner() {
  local root="$1"
  if [[ -f "$root/uv.lock" ]] && harness::has uv; then
    echo "uv run "
  elif [[ -f "$root/poetry.lock" ]] && harness::has poetry; then
    echo "poetry run "
  elif [[ -d "$root/.venv/bin" ]]; then
    echo ".venv/bin/"
  fi
}

# Succeeds if the project appears to use the given Python tool.
_harness_python_uses() {
  local root="$1" tool="$2" file
  [[ -x "$root/.venv/bin/$tool" ]] && return 0
  for file in pyproject.toml setup.cfg tox.ini requirements-dev.txt requirements.txt \
    "$tool.ini" ".$tool.toml" "$tool.toml"; do
    [[ -f "$root/$file" ]] || continue
    case "$file" in
      "$tool.ini" | ".$tool.toml" | "$tool.toml") return 0 ;;
    esac
    grep -Eqi "(^|[^a-z0-9_-])${tool}([^a-z0-9_-]|$)" "$root/$file" && return 0
  done
  return 1
}

_harness_python_cmd() {
  local root="$1" step="$2" run
  run="$(_harness_python_runner "$root")"

  case "$step" in
    format)
      if _harness_python_uses "$root" ruff; then
        echo "${run}ruff format --check ."
      elif _harness_python_uses "$root" black; then
        echo "${run}black --check ."
      fi
      ;;
    format_fix)
      if _harness_python_uses "$root" ruff; then
        echo "${run}ruff format . && ${run}ruff check --fix ."
      elif _harness_python_uses "$root" black; then
        echo "${run}black ."
      fi
      ;;
    lint)
      if _harness_python_uses "$root" ruff; then
        echo "${run}ruff check ."
      elif _harness_python_uses "$root" flake8; then
        echo "${run}flake8"
      fi
      ;;
    typecheck)
      if _harness_python_uses "$root" mypy; then
        echo "${run}mypy ."
      elif _harness_python_uses "$root" pyright; then
        echo "${run}pyright"
      fi
      ;;
    test)
      if _harness_python_uses "$root" pytest; then
        echo "${run}pytest"
      elif [[ -d "$root/tests" ]]; then
        echo "${run}python -m unittest discover -s tests"
      fi
      ;;
  esac
}

# --- Go / Rust / JVM / .NET / Ruby / PHP ------------------------------------------------

_harness_go_cmd() {
  local step="$2"
  # The format command's substitution must run later, inside check.sh, not here.
  # shellcheck disable=SC2016
  case "$step" in
    format) echo 'test -z "$(gofmt -l .)" || { gofmt -l .; exit 1; }' ;;
    format_fix) echo "gofmt -w ." ;;
    lint)
      if harness::has golangci-lint; then
        echo "golangci-lint run"
      else
        echo "go vet ./..."
      fi
      ;;
    test) echo "go test ./..." ;;
    build) echo "go build ./..." ;;
  esac
}

_harness_rust_cmd() {
  local step="$2"
  case "$step" in
    format) echo "cargo fmt --all -- --check" ;;
    format_fix) echo "cargo fmt --all" ;;
    lint) echo "cargo clippy --all-targets -- -D warnings" ;;
    typecheck) echo "cargo check --all-targets" ;;
    test) echo "cargo test" ;;
    build) echo "cargo build" ;;
  esac
}

_harness_gradle_cmd() {
  local root="$1" step="$2" gradle="gradle"
  [[ -x "$root/gradlew" ]] && gradle="./gradlew"
  local uses_spotless=1
  grep -qs spotless "$root/build.gradle" "$root/build.gradle.kts" && uses_spotless=0

  case "$step" in
    format) [[ $uses_spotless -eq 0 ]] && echo "$gradle spotlessCheck" ;;
    format_fix) [[ $uses_spotless -eq 0 ]] && echo "$gradle spotlessApply" ;;
    lint) echo "$gradle check -x test" ;;
    test) echo "$gradle test" ;;
    build) echo "$gradle assemble" ;;
  esac
  return 0
}

_harness_maven_cmd() {
  local root="$1" step="$2" mvn="mvn"
  [[ -x "$root/mvnw" ]] && mvn="./mvnw"
  local uses_spotless=1
  grep -qs spotless "$root/pom.xml" && uses_spotless=0

  case "$step" in
    format) [[ $uses_spotless -eq 0 ]] && echo "$mvn -B spotless:check" ;;
    format_fix) [[ $uses_spotless -eq 0 ]] && echo "$mvn -B spotless:apply" ;;
    test) echo "$mvn -B test" ;;
    build) echo "$mvn -B -DskipTests package" ;;
  esac
  return 0
}

_harness_dotnet_cmd() {
  local step="$2"
  case "$step" in
    format) echo "dotnet format --verify-no-changes" ;;
    format_fix) echo "dotnet format" ;;
    test) echo "dotnet test" ;;
    build) echo "dotnet build --warnaserror" ;;
  esac
}

_harness_ruby_cmd() {
  local root="$1" step="$2"
  case "$step" in
    lint) grep -qs rubocop "$root/Gemfile" && echo "bundle exec rubocop" ;;
    format_fix) grep -qs rubocop "$root/Gemfile" && echo "bundle exec rubocop -a" ;;
    typecheck) grep -qs sorbet "$root/Gemfile" && echo "bundle exec srb tc" ;;
    test)
      if [[ -d "$root/spec" ]]; then
        echo "bundle exec rspec"
      elif [[ -d "$root/test" ]]; then
        echo "bundle exec rake test"
      fi
      ;;
  esac
  return 0
}

_harness_php_cmd() {
  local root="$1" step="$2" bin="$1/vendor/bin"
  case "$step" in
    format) [[ -x "$bin/php-cs-fixer" ]] && echo "vendor/bin/php-cs-fixer fix --dry-run --diff" ;;
    format_fix) [[ -x "$bin/php-cs-fixer" ]] && echo "vendor/bin/php-cs-fixer fix" ;;
    lint) [[ -x "$bin/phpcs" ]] && echo "vendor/bin/phpcs" ;;
    typecheck) [[ -x "$bin/phpstan" ]] && echo "vendor/bin/phpstan analyse" ;;
    test) [[ -x "$bin/phpunit" ]] && echo "vendor/bin/phpunit" ;;
  esac
  return 0
}

# Prints the default command for an ecosystem and step, or nothing if there is none.
harness::default_cmd() {
  local root="$1" ecosystem="$2" step="$3"
  case "$ecosystem" in
    node) _harness_node_cmd "$root" "$step" ;;
    python) _harness_python_cmd "$root" "$step" ;;
    go) _harness_go_cmd "$root" "$step" ;;
    rust) _harness_rust_cmd "$root" "$step" ;;
    gradle) _harness_gradle_cmd "$root" "$step" ;;
    maven) _harness_maven_cmd "$root" "$step" ;;
    dotnet) _harness_dotnet_cmd "$root" "$step" ;;
    ruby) _harness_ruby_cmd "$root" "$step" ;;
    php) _harness_php_cmd "$root" "$step" ;;
  esac
  return 0
}

# Prints the commands to run for a step, one per line.
# A value in .harness/project.env wins over detection; "-" disables the step.
harness::resolve_cmds() {
  local step="$1" root var override ecosystem
  root="$(harness::root)"
  var="$(harness::step_var "$step")"
  override="${!var:-}"

  if [[ "$override" == "$HARNESS_DISABLED" ]]; then
    return 0
  fi
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi

  while IFS= read -r ecosystem; do
    [[ -n "$ecosystem" ]] || continue
    harness::default_cmd "$root" "$ecosystem" "$step"
  done < <(harness::detect_ecosystems "$root")
}

# Succeeds if the step is listed in HARNESS_REQUIRED_STEPS.
harness::is_required() {
  case " ${HARNESS_REQUIRED_STEPS:-} " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}
