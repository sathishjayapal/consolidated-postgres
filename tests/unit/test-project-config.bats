#!/usr/bin/env bats
# Unit tests for scripts/lib/project-config.sh
#
# These tests are pure in-process – no Docker, no network.
# Each test runs with a sandboxed HOME and PROJECT_ROOT so resolve_project_dir
# is fully controlled and does not touch real project directories.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB_SCRIPT="$REPO_ROOT/scripts/lib/project-config.sh"

setup() {
  _ORIG_HOME="$HOME"

  TEST_WORKSPACE="$(mktemp -d)"

  # redirect HOME so resolve_project_dir picks up our fake dirs
  export HOME="$TEST_WORKSPACE"

  # PROJECT_ROOT used as fallback when ~/IdeaProjects/<name> is absent
  export PROJECT_ROOT="$TEST_WORKSPACE/fallback"

  # Fake IdeaProjects tree (what resolve_project_dir prefers)
  mkdir -p "$TEST_WORKSPACE/IdeaProjects/eventstracker"
  mkdir -p "$TEST_WORKSPACE/IdeaProjects/runs-app"
  mkdir -p "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer"
  mkdir -p "$TEST_WORKSPACE/IdeaProjects/jubilant-memory/config"
  mkdir -p "$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server"

  # Fallback tree
  mkdir -p "$PROJECT_ROOT/eventstracker"
  mkdir -p "$PROJECT_ROOT/runs-app"
  mkdir -p "$PROJECT_ROOT/runs-ai-analyzer"

  # Source the library (PROJECT_ROOT now exported)
  # shellcheck source=scripts/lib/project-config.sh
  source "$LIB_SCRIPT"
}

teardown() {
  export HOME="$_ORIG_HOME"
  rm -rf "$TEST_WORKSPACE"
}

# ─────────────────────────────────────────────────────────────────────────────
# PROJECTS array
# ─────────────────────────────────────────────────────────────────────────────

@test "PROJECTS array has exactly 3 entries" {
  [ "${#PROJECTS[@]}" -eq 3 ]
}

@test "PROJECTS array contains eventstracker" {
  [[ " ${PROJECTS[*]} " == *" eventstracker "* ]]
}

@test "PROJECTS array contains runs-app" {
  [[ " ${PROJECTS[*]} " == *" runs-app "* ]]
}

@test "PROJECTS array contains runs-ai-analyzer" {
  [[ " ${PROJECTS[*]} " == *" runs-ai-analyzer "* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# resolve_project_dir
# ─────────────────────────────────────────────────────────────────────────────

@test "resolve_project_dir: prefers ~/IdeaProjects path when it exists" {
  result="$(resolve_project_dir "eventstracker")"
  [ "$result" = "$TEST_WORKSPACE/IdeaProjects/eventstracker" ]
}

@test "resolve_project_dir: falls back to PROJECT_ROOT when ~/IdeaProjects path absent" {
  rm -rf "$TEST_WORKSPACE/IdeaProjects/eventstracker"
  result="$(resolve_project_dir "eventstracker")"
  [ "$result" = "$PROJECT_ROOT/eventstracker" ]
}

@test "resolve_project_dir: PROJECT_ROOT fallback works for runs-app" {
  rm -rf "$TEST_WORKSPACE/IdeaProjects/runs-app"
  result="$(resolve_project_dir "runs-app")"
  [ "$result" = "$PROJECT_ROOT/runs-app" ]
}

@test "resolve_project_dir: returns correct path when both locations exist" {
  result="$(resolve_project_dir "runs-ai-analyzer")"
  [ "$result" = "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Infra / shared paths
# ─────────────────────────────────────────────────────────────────────────────

@test "get_infra_config_dir returns jubilant-memory/config path" {
  expected="$TEST_WORKSPACE/IdeaProjects/jubilant-memory/config"
  [ "$(get_infra_config_dir)" = "$expected" ]
}

@test "get_config_server_dir returns sathishproject-config-server path" {
  expected="$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server"
  [ "$(get_config_server_dir)" = "$expected" ]
}

@test "get_config_server_env_file returns .env inside config server dir" {
  expected="$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server/.env"
  [ "$(get_config_server_env_file)" = "$expected" ]
}

@test "get_config_server_container returns sathish-config-server" {
  [ "$(get_config_server_container)" = "sathish-config-server" ]
}

@test "get_rabbitmq_container returns sathishproject-rabbitmq" {
  [ "$(get_rabbitmq_container)" = "sathishproject-rabbitmq" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_port
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_port: eventstracker is 6433" {
  [ "$(get_project_port "eventstracker")" = "6433" ]
}

@test "get_project_port: runs-app is 5443" {
  [ "$(get_project_port "runs-app")" = "5443" ]
}

@test "get_project_port: runs-ai-analyzer is 5444" {
  [ "$(get_project_port "runs-ai-analyzer")" = "5444" ]
}

@test "get_project_port: unknown project returns exit code 1" {
  local rc=0
  get_project_port "no-such-project" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_container
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_container: eventstracker is event-service-db" {
  [ "$(get_project_container "eventstracker")" = "event-service-db" ]
}

@test "get_project_container: runs-app is runs-app-postgres" {
  [ "$(get_project_container "runs-app")" = "runs-app-postgres" ]
}

@test "get_project_container: runs-ai-analyzer is runs-ai-analyzer-db" {
  [ "$(get_project_container "runs-ai-analyzer")" = "runs-ai-analyzer-db" ]
}

@test "get_project_container: unknown project returns exit code 1" {
  local rc=0
  get_project_container "no-such-project" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_db_name
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_db_name: eventstracker is event-service" {
  [ "$(get_project_db_name "eventstracker")" = "event-service" ]
}

@test "get_project_db_name: runs-app is runsapp_db" {
  [ "$(get_project_db_name "runs-app")" = "runsapp_db" ]
}

@test "get_project_db_name: runs-ai-analyzer defaults to runs_ai_analyzer_db when no env file" {
  [ "$(get_project_db_name "runs-ai-analyzer")" = "runs_ai_analyzer_db" ]
}

@test "get_project_db_name: runs-ai-analyzer reads RUNS_AI_ANALYZER_DB_NAME from env file" {
  echo "RUNS_AI_ANALYZER_DB_NAME=custom_vector_db" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_name "runs-ai-analyzer")" = "custom_vector_db" ]
}

@test "get_project_db_name: runs-ai-analyzer extracts name from RUNS_AI_ANALYZER_DB_URL" {
  echo "RUNS_AI_ANALYZER_DB_URL=jdbc:postgresql://localhost:5444/vector_db" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_name "runs-ai-analyzer")" = "vector_db" ]
}

@test "get_project_db_name: runs-ai-analyzer strips query params from DB URL" {
  echo "RUNS_AI_ANALYZER_DB_URL=jdbc:postgresql://localhost:5444/vector_db?ssl=false&timeout=30" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_name "runs-ai-analyzer")" = "vector_db" ]
}

@test "get_project_db_name: RUNS_AI_ANALYZER_DB_URL takes precedence over RUNS_AI_ANALYZER_DB_NAME" {
  printf 'RUNS_AI_ANALYZER_DB_URL=jdbc:postgresql://localhost:5444/url_db\nRUNS_AI_ANALYZER_DB_NAME=name_db\n' \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_name "runs-ai-analyzer")" = "url_db" ]
}

@test "get_project_db_name: unknown project returns exit code 1" {
  local rc=0
  get_project_db_name "no-such-project" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_password_env_var
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_password_env_var: eventstracker" {
  [ "$(get_project_password_env_var "eventstracker")" = "EVENTS_TRACKER_DB_PASSWORD" ]
}

@test "get_project_password_env_var: runs-app" {
  [ "$(get_project_password_env_var "runs-app")" = "RUNS_APP_DB_PASSWORD" ]
}

@test "get_project_password_env_var: runs-ai-analyzer" {
  [ "$(get_project_password_env_var "runs-ai-analyzer")" = "RUNS_AI_ANALYZER_DB_PASSWORD" ]
}

@test "get_project_password_env_var: unknown project returns exit code 1" {
  local rc=0
  get_project_password_env_var "no-such-project" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_env_password_key
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_env_password_key: eventstracker" {
  [ "$(get_project_env_password_key "eventstracker")" = "EVENTS_TRACKER_DB_PASSWORD" ]
}

@test "get_project_env_password_key: runs-app uses JDBC key" {
  [ "$(get_project_env_password_key "runs-app")" = "JDBC_DATABASE_PASSWORD" ]
}

@test "get_project_env_password_key: runs-ai-analyzer" {
  [ "$(get_project_env_password_key "runs-ai-analyzer")" = "RUNS_AI_ANALYZER_DB_PASSWORD" ]
}

@test "get_project_env_password_key: unknown project returns exit code 1" {
  local rc=0
  get_project_env_password_key "no-such-project" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_seed_table
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_seed_table: eventstracker is domain" {
  [ "$(get_project_seed_table "eventstracker")" = "domain" ]
}

@test "get_project_seed_table: runs-app is run_app_user" {
  [ "$(get_project_seed_table "runs-app")" = "run_app_user" ]
}

@test "get_project_seed_table: runs-ai-analyzer is rag_cache" {
  [ "$(get_project_seed_table "runs-ai-analyzer")" = "rag_cache" ]
}

@test "get_project_seed_table: unknown project returns exit code 1" {
  local rc=0
  get_project_seed_table "no-such-project" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_env_file
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_env_file: eventstracker resolves to project dir .env" {
  expected="$TEST_WORKSPACE/IdeaProjects/eventstracker/.env"
  [ "$(get_project_env_file "eventstracker")" = "$expected" ]
}

@test "get_project_env_file: runs-app resolves to project dir .env" {
  expected="$TEST_WORKSPACE/IdeaProjects/runs-app/.env"
  [ "$(get_project_env_file "runs-app")" = "$expected" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_db_user
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_db_user: runs-app reads JDBC_DATABASE_USERNAME" {
  echo "JDBC_DATABASE_USERNAME=myrunuser" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-app/.env"
  [ "$(get_project_db_user "runs-app")" = "myrunuser" ]
}

@test "get_project_db_user: eventstracker reads EVENTS_TRACKER_DB_USER from project .env" {
  echo "EVENTS_TRACKER_DB_USER=evtuser" \
    > "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env"
  [ "$(get_project_db_user "eventstracker")" = "evtuser" ]
}

@test "get_project_db_user: eventstracker falls back to infra .env when project .env missing the key" {
  # project .env exists but doesn't have the key
  echo "SOME_OTHER_KEY=value" > "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env"
  echo "EVENTS_TRACKER_DB_USER=infra_user" \
    > "$TEST_WORKSPACE/IdeaProjects/jubilant-memory/config/.env"
  [ "$(get_project_db_user "eventstracker")" = "infra_user" ]
}

@test "get_project_db_user: eventstracker uses infra .env when no project .env at all" {
  echo "EVENTS_TRACKER_DB_USER=infra_only_user" \
    > "$TEST_WORKSPACE/IdeaProjects/jubilant-memory/config/.env"
  [ "$(get_project_db_user "eventstracker")" = "infra_only_user" ]
}

@test "get_project_db_user: runs-ai-analyzer reads RUNS_AI_ANALYZER_DB_USER" {
  echo "RUNS_AI_ANALYZER_DB_USER=runsai_u" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_user "runs-ai-analyzer")" = "runsai_u" ]
}

@test "get_project_db_user: runs-ai-analyzer falls back to JDBC_DATABASE_USERNAME" {
  echo "JDBC_DATABASE_USERNAME=jdbc_fallback_user" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_user "runs-ai-analyzer")" = "jdbc_fallback_user" ]
}

@test "get_project_db_user: RUNS_AI_ANALYZER_DB_USER takes precedence over JDBC_DATABASE_USERNAME" {
  printf 'RUNS_AI_ANALYZER_DB_USER=explicit_user\nJDBC_DATABASE_USERNAME=jdbc_user\n' \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_db_user "runs-ai-analyzer")" = "explicit_user" ]
}

@test "get_project_db_user: unknown project returns exit code 1" {
  local rc=0
  get_project_db_user "no-such-project" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# get_project_password
# ─────────────────────────────────────────────────────────────────────────────

@test "get_project_password: reads from RUNS_APP_DB_PASSWORD env var" {
  export RUNS_APP_DB_PASSWORD="env_override_pass"
  result="$(get_project_password "runs-app")"
  unset RUNS_APP_DB_PASSWORD
  [ "$result" = "env_override_pass" ]
}

@test "get_project_password: reads from .env file when env var absent" {
  echo "JDBC_DATABASE_PASSWORD=file_pass_123" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-app/.env"
  [ "$(get_project_password "runs-app")" = "file_pass_123" ]
}

@test "get_project_password: env var override takes precedence over .env file" {
  echo "JDBC_DATABASE_PASSWORD=file_pass" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-app/.env"
  export RUNS_APP_DB_PASSWORD="env_wins"
  result="$(get_project_password "runs-app")"
  unset RUNS_APP_DB_PASSWORD
  [ "$result" = "env_wins" ]
}

@test "get_project_password: reads EVENTS_TRACKER_DB_PASSWORD from eventstracker .env" {
  echo "EVENTS_TRACKER_DB_PASSWORD=secret456" \
    > "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env"
  [ "$(get_project_password "eventstracker")" = "secret456" ]
}

@test "get_project_password: reads RUNS_AI_ANALYZER_DB_PASSWORD from runs-ai-analyzer .env" {
  echo "RUNS_AI_ANALYZER_DB_PASSWORD=aipass789" \
    > "$TEST_WORKSPACE/IdeaProjects/runs-ai-analyzer/.env"
  [ "$(get_project_password "runs-ai-analyzer")" = "aipass789" ]
}

@test "get_project_password: returns exit code 1 when no env var and no .env file" {
  local rc=0
  get_project_password "eventstracker" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

@test "get_project_password: returns exit code 1 when .env file exists but key is absent" {
  echo "SOME_OTHER_KEY=irrelevant" > "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env"
  local rc=0
  get_project_password "eventstracker" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Consistency: each project has a full metadata set
# ─────────────────────────────────────────────────────────────────────────────

@test "all three projects have non-empty port" {
  for p in eventstracker runs-app runs-ai-analyzer; do
    result="$(get_project_port "$p")"
    [ -n "$result" ]
  done
}

@test "all three projects have non-empty container name" {
  for p in eventstracker runs-app runs-ai-analyzer; do
    result="$(get_project_container "$p")"
    [ -n "$result" ]
  done
}

@test "all three projects have non-empty db name" {
  for p in eventstracker runs-app; do
    result="$(get_project_db_name "$p")"
    [ -n "$result" ]
  done
}

@test "all three projects have non-empty seed table" {
  for p in eventstracker runs-app runs-ai-analyzer; do
    result="$(get_project_seed_table "$p")"
    [ -n "$result" ]
  done
}

@test "all three projects have non-empty password env var" {
  for p in eventstracker runs-app runs-ai-analyzer; do
    result="$(get_project_password_env_var "$p")"
    [ -n "$result" ]
  done
}

@test "project ports are unique" {
  et_port="$(get_project_port "eventstracker")"
  ra_port="$(get_project_port "runs-app")"
  ai_port="$(get_project_port "runs-ai-analyzer")"
  [ "$et_port" != "$ra_port" ]
  [ "$et_port" != "$ai_port" ]
  [ "$ra_port" != "$ai_port" ]
}

@test "project containers are unique" {
  et_c="$(get_project_container "eventstracker")"
  ra_c="$(get_project_container "runs-app")"
  ai_c="$(get_project_container "runs-ai-analyzer")"
  [ "$et_c" != "$ra_c" ]
  [ "$et_c" != "$ai_c" ]
  [ "$ra_c" != "$ai_c" ]
}
