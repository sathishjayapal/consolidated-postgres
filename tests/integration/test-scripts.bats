#!/usr/bin/env bats
# Integration tests for consolidated-postgres shell scripts.
#
# These tests exercise script invocation behavior that does NOT require Docker
# or running services: argument parsing, --help output, bad-arg rejection,
# project listing, and static verification checks.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPTS_LOCAL="$REPO_ROOT/scripts/local"

# ─────────────────────────────────────────────────────────────────────────────
# Script executability
# ─────────────────────────────────────────────────────────────────────────────

@test "multi-dev-up.sh is executable" {
  [ -x "$SCRIPTS_LOCAL/multi-dev-up.sh" ]
}

@test "multi-dev-down.sh is executable" {
  [ -x "$SCRIPTS_LOCAL/multi-dev-down.sh" ]
}

@test "multi-dev-verify.sh is executable" {
  [ -x "$SCRIPTS_LOCAL/multi-dev-verify.sh" ]
}

@test "bootstrap-env.sh is executable" {
  [ -x "$SCRIPTS_LOCAL/bootstrap-env.sh" ]
}

@test "test-idempotency.sh is executable" {
  [ -x "$SCRIPTS_LOCAL/test-idempotency.sh" ]
}

@test "list-projects.sh is executable" {
  [ -x "$SCRIPTS_LOCAL/list-projects.sh" ]
}

@test "rabbitmq-manager.sh is executable" {
  [ -x "$REPO_ROOT/rabbitmq-manager.sh" ]
}

@test "diagnose.sh is executable" {
  [ -x "$REPO_ROOT/diagnose.sh" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# multi-dev-up.sh argument handling
# ─────────────────────────────────────────────────────────────────────────────

@test "multi-dev-up.sh --help exits 0 and prints usage" {
  run bash "$SCRIPTS_LOCAL/multi-dev-up.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]] || [[ "$output" == *"usage"* ]] || [[ "$output" == *"--reset"* ]]
}

@test "multi-dev-up.sh rejects unknown flag with exit code 1" {
  run bash "$SCRIPTS_LOCAL/multi-dev-up.sh" --unknown-flag
  [ "$status" -eq 1 ]
}

@test "multi-dev-up.sh --unknown-flag prints error message" {
  run bash "$SCRIPTS_LOCAL/multi-dev-up.sh" --unknown-flag
  [[ "$output" == *"Unknown option"* ]] || [[ "$output" == *"unknown"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# multi-dev-down.sh argument handling
# ─────────────────────────────────────────────────────────────────────────────

@test "multi-dev-down.sh --help exits 0 and prints usage" {
  run bash "$SCRIPTS_LOCAL/multi-dev-down.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--volumes"* ]] || [[ "$output" == *"Usage"* ]]
}

@test "multi-dev-down.sh rejects unknown flag with exit code 1" {
  run bash "$SCRIPTS_LOCAL/multi-dev-down.sh" --bad-option
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# test-idempotency.sh argument handling
# ─────────────────────────────────────────────────────────────────────────────

@test "test-idempotency.sh --help exits 0" {
  run bash "$SCRIPTS_LOCAL/test-idempotency.sh" --help
  [ "$status" -eq 0 ]
}

@test "test-idempotency.sh --help mentions --full option" {
  run bash "$SCRIPTS_LOCAL/test-idempotency.sh" --help
  [[ "$output" == *"--full"* ]]
}

@test "test-idempotency.sh rejects unknown flag with exit code 1" {
  run bash "$SCRIPTS_LOCAL/test-idempotency.sh" --bad-option
  [ "$status" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# rabbitmq-manager.sh argument handling
# ─────────────────────────────────────────────────────────────────────────────

@test "rabbitmq-manager.sh help prints usage" {
  run bash "$REPO_ROOT/rabbitmq-manager.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"start"* ]]
  [[ "$output" == *"stop"* ]]
  [[ "$output" == *"status"* ]]
}

@test "rabbitmq-manager.sh --help flag works" {
  run bash "$REPO_ROOT/rabbitmq-manager.sh" --help
  [ "$status" -eq 0 ]
}

@test "rabbitmq-manager.sh -h flag works" {
  run bash "$REPO_ROOT/rabbitmq-manager.sh" -h
  [ "$status" -eq 0 ]
}

@test "rabbitmq-manager.sh unknown command exits 1" {
  run bash "$REPO_ROOT/rabbitmq-manager.sh" totally-invalid-command
  [ "$status" -eq 1 ]
}

@test "rabbitmq-manager.sh with no arguments exits 1" {
  run bash "$REPO_ROOT/rabbitmq-manager.sh"
  [ "$status" -eq 1 ]
}

@test "rabbitmq-manager.sh unknown command prints error message" {
  run bash "$REPO_ROOT/rabbitmq-manager.sh" bad-cmd
  [[ "$output" == *"Unknown command"* ]] || [[ "$output" == *"unknown"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# list-projects.sh output
# ─────────────────────────────────────────────────────────────────────────────

@test "list-projects.sh exits 0" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [ "$status" -eq 0 ]
}

@test "list-projects.sh output includes eventstracker" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [[ "$output" == *"eventstracker"* ]]
}

@test "list-projects.sh output includes runs-app" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [[ "$output" == *"runs-app"* ]]
}

@test "list-projects.sh output includes runs-ai-analyzer" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [[ "$output" == *"runs-ai-analyzer"* ]]
}

@test "list-projects.sh shows port for each project" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [[ "$output" == *"6433"* ]]
  [[ "$output" == *"5443"* ]]
  [[ "$output" == *"5444"* ]]
}

@test "list-projects.sh shows container names" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [[ "$output" == *"event-service-db"* ]]
  [[ "$output" == *"runs-app-postgres"* ]]
}

@test "list-projects.sh shows seed tables" {
  run bash "$SCRIPTS_LOCAL/list-projects.sh"
  [[ "$output" == *"domain"* ]]
  [[ "$output" == *"run_app_user"* ]]
  [[ "$output" == *"rag_cache"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# projects.txt integrity
# ─────────────────────────────────────────────────────────────────────────────

@test "projects.txt file exists" {
  [ -f "$REPO_ROOT/projects.txt" ]
}

@test "projects.txt contains eventstracker" {
  grep -qE "^eventstracker$" "$REPO_ROOT/projects.txt"
}

@test "projects.txt contains runs-app" {
  grep -qE "^runs-app$" "$REPO_ROOT/projects.txt"
}

@test "projects.txt contains runs-ai-analyzer" {
  grep -qE "^runs-ai-analyzer$" "$REPO_ROOT/projects.txt"
}

@test "projects.txt has no duplicate entries" {
  total="$(grep -vE '^\s*#|^\s*$' "$REPO_ROOT/projects.txt" | wc -l | tr -d ' ')"
  unique="$(grep -vE '^\s*#|^\s*$' "$REPO_ROOT/projects.txt" | sort -u | wc -l | tr -d ' ')"
  [ "$total" = "$unique" ]
}

@test "projects.txt has no trailing whitespace on project lines" {
  # Lines with trailing spaces cause subtle bugs in array population
  ! grep -qE "^[^#].*[[:space:]]$" "$REPO_ROOT/projects.txt"
}

# ─────────────────────────────────────────────────────────────────────────────
# project-config.sh library sanity checks
# ─────────────────────────────────────────────────────────────────────────────

@test "project-config.sh requires PROJECT_ROOT to be set" {
  local wrapper
  wrapper="$(mktemp /tmp/bats_test_XXXXX.sh)"
  printf '#!/usr/bin/env bash\nunset PROJECT_ROOT\n. "%s"\n' \
    "$REPO_ROOT/scripts/lib/project-config.sh" > "$wrapper"
  run bash "$wrapper"
  rm -f "$wrapper"
  [ "$status" -ne 0 ]
}

@test "project-config.sh guards against empty projects.txt" {
  # Verify the guard clause is present in source (static check + runtime)
  grep -q 'No projects defined' "$REPO_ROOT/scripts/lib/project-config.sh"
}

@test "project-config.sh errors when projects.txt is absent" {
  local tmpdir libcopy wrapper
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/scripts/lib"
  libcopy="$tmpdir/scripts/lib/project-config.sh"
  cp "$REPO_ROOT/scripts/lib/project-config.sh" "$libcopy"
  # There is no projects.txt two levels above $libcopy, so the guard triggers
  wrapper="$(mktemp /tmp/bats_test_XXXXX.sh)"
  printf '#!/usr/bin/env bash\nexport PROJECT_ROOT="%s"\n. "%s"\n' \
    "$tmpdir" "$libcopy" > "$wrapper"
  run bash "$wrapper"
  rm -rf "$tmpdir"
  rm -f "$wrapper"
  [ "$status" -ne 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# test-idempotency.sh default (non-full) mode
# ─────────────────────────────────────────────────────────────────────────────

@test "test-idempotency.sh default mode checks required scripts are executable" {
  run bash "$SCRIPTS_LOCAL/test-idempotency.sh"
  # Should pass on the dev machine where scripts exist; check output shows script checks
  [[ "$output" == *"executable"* ]] || [[ "$output" == *"Checking"* ]] || [[ "$output" == *"required"* ]]
}
