#!/usr/bin/env bats
# Behavioral tests for scripts/local/bootstrap-env.sh
#
# Runs bootstrap-env.sh as a subprocess in a fully sandboxed temp directory.
# Verifies:
#   - File creation from templates
#   - Correct key propagation from infra .env to project .envs
#   - Placeholder overwrite logic
#   - Idempotency (running twice gives the same result)
#   - Secret generation quality

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
BOOTSTRAP_SCRIPT="$REPO_ROOT/scripts/local/bootstrap-env.sh"

# Minimal env/.env.local.example for consolidated-postgres (DB/RabbitMQ golden source)
_INFRA_EXAMPLE_CONTENT='EVENTS_TRACKER_DB_NAME=
EVENTS_TRACKER_DB_USER=
EVENTS_TRACKER_DB_PASSWORD=
RUNS_APP_DB_NAME=
RUNS_APP_DB_USER=
RUNS_APP_DB_PASSWORD=
RUNS_AI_ANALYZER_DB_NAME=
RUNS_AI_ANALYZER_DB_USER=
RUNS_AI_ANALYZER_DB_PASSWORD=
MYTRACKER_DB_NAME=
MYTRACKER_DB_USER=
MYTRACKER_DB_PASSWORD=
RABBITMQ_USERNAME=
RABBITMQ_PASSWORD=
EVENT_DOMAIN_USER=
EVENT_DOMAIN_USER_PASSWORD=
'

# Minimal jubilant-memory/config/.env.example (config-server golden source)
_CONFIG_SERVER_EXAMPLE_CONTENT='GIT_URI=
encrypt_key=
username=
pass=
APP_PORT=
'

# Minimal .env.template for eventstracker
_ET_TEMPLATE_CONTENT='EVENTS_TRACKER_DB_URL=
EVENTS_TRACKER_DB_USER=
EVENTS_TRACKER_DB_PASSWORD=
RABBITMQ_HOST=
RABBITMQ_PORT=
RABBITMQ_USERNAME=
RABBITMQ_PASSWORD=
EVENT_DOMAIN_USER=
EVENT_DOMAIN_USER_PASSWORD=
SPRING_CLOUD_CONFIG_USERNAME=
SPRING_CLOUD_CONFIG_PASSWORD=
'

setup() {
  _ORIG_HOME="$HOME"
  TEST_WORKSPACE="$(mktemp -d)"

  # Redirect HOME so bootstrap-env.sh resolves project dirs into our temp tree
  export HOME="$TEST_WORKSPACE"

  # Build directory scaffold
  _CP_ENV_DIR="$TEST_WORKSPACE/IdeaProjects/consolidated-postgres/env"
  _INFRA_DIR="$TEST_WORKSPACE/IdeaProjects/jubilant-memory/config"
  _ET_DIR="$TEST_WORKSPACE/IdeaProjects/eventstracker"
  _CS_DIR="$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server"

  mkdir -p "$_CP_ENV_DIR"
  mkdir -p "$_INFRA_DIR"
  mkdir -p "$_ET_DIR"
  mkdir -p "$_CS_DIR"

  # Write templates
  printf '%s' "$_INFRA_EXAMPLE_CONTENT"         > "$_CP_ENV_DIR/.env.local.example"
  printf '%s' "$_CONFIG_SERVER_EXAMPLE_CONTENT" > "$_INFRA_DIR/.env.example"
  printf '%s' "$_ET_TEMPLATE_CONTENT"           > "$_ET_DIR/.env.template"
}

teardown() {
  export HOME="$_ORIG_HOME"
  rm -rf "$TEST_WORKSPACE"
}

# Helper: run bootstrap-env.sh as a subprocess with sandboxed HOME
run_bootstrap() {
  HOME="$TEST_WORKSPACE" bash "$BOOTSTRAP_SCRIPT" "$@"
}

# Helper: read a key=value from a file
get_val() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2- || true
}

INFRA_ENV_PATH() { echo "$TEST_WORKSPACE/IdeaProjects/consolidated-postgres/env/.env.local"; }
CONFIG_SERVER_SRC_PATH() { echo "$TEST_WORKSPACE/IdeaProjects/jubilant-memory/config/.env"; }

# ─────────────────────────────────────────────────────────────────────────────
# File creation
# ─────────────────────────────────────────────────────────────────────────────

@test "bootstrap creates infra .env when it does not exist" {
  run_bootstrap
  [ -f "$(INFRA_ENV_PATH)" ]
}

@test "bootstrap creates config-server .env when it does not exist" {
  run_bootstrap
  [ -f "$(CONFIG_SERVER_SRC_PATH)" ]
}

@test "bootstrap creates eventstracker .env when it does not exist" {
  run_bootstrap
  [ -f "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" ]
}

@test "bootstrap creates config-server app .env when it does not exist" {
  run_bootstrap
  [ -f "$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server/.env" ]
}

@test "bootstrap restricts infra .env to owner-read-write (chmod 600)" {
  run_bootstrap
  local perms
  perms=$(stat -f "%Lp" "$(INFRA_ENV_PATH)" 2>/dev/null \
       || stat --format="%a" "$(INFRA_ENV_PATH)")
  [ "$perms" = "600" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Default value generation
# ─────────────────────────────────────────────────────────────────────────────

@test "bootstrap sets EVENTS_TRACKER_DB_NAME to event-service" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_NAME")"
  [ "$val" = "event-service" ]
}

@test "bootstrap sets RUNS_APP_DB_NAME to runsapp_db" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "RUNS_APP_DB_NAME")"
  [ "$val" = "runsapp_db" ]
}

@test "bootstrap sets RUNS_AI_ANALYZER_DB_NAME to runs_ai_analyzer_db" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "RUNS_AI_ANALYZER_DB_NAME")"
  [ "$val" = "runs_ai_analyzer_db" ]
}

@test "bootstrap sets EVENTS_TRACKER_DB_USER to eventsvc_local" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_USER")"
  [ "$val" = "eventsvc_local" ]
}

@test "bootstrap sets RUNS_APP_DB_USER to runsapp_local" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "RUNS_APP_DB_USER")"
  [ "$val" = "runsapp_local" ]
}

@test "bootstrap sets MYTRACKER_DB_USER to mytracker_local" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "MYTRACKER_DB_USER")"
  [ "$val" = "mytracker_local" ]
}

@test "bootstrap sets RABBITMQ_USERNAME to rabbit_local" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "RABBITMQ_USERNAME")"
  [ "$val" = "rabbit_local" ]
}

@test "bootstrap sets APP_PORT to 8888 in config-server .env" {
  run_bootstrap
  val="$(get_val "$(CONFIG_SERVER_SRC_PATH)" "APP_PORT")"
  [ "$val" = "8888" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Secret generation
# ─────────────────────────────────────────────────────────────────────────────

@test "bootstrap generates a non-empty EVENTS_TRACKER_DB_PASSWORD" {
  run_bootstrap
  val="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_PASSWORD")"
  [ -n "$val" ]
}

@test "generated passwords are at least 20 characters long" {
  run_bootstrap
  for key in EVENTS_TRACKER_DB_PASSWORD RUNS_APP_DB_PASSWORD RUNS_AI_ANALYZER_DB_PASSWORD MYTRACKER_DB_PASSWORD RABBITMQ_PASSWORD; do
    val="$(get_val "$(INFRA_ENV_PATH)" "$key")"
    [ "${#val}" -ge 20 ]
  done
}

@test "generated passwords are unique" {
  run_bootstrap
  p1="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_PASSWORD")"
  p2="$(get_val "$(INFRA_ENV_PATH)" "RUNS_APP_DB_PASSWORD")"
  p3="$(get_val "$(INFRA_ENV_PATH)" "RUNS_AI_ANALYZER_DB_PASSWORD")"
  [ "$p1" != "$p2" ]
  [ "$p1" != "$p3" ]
  [ "$p2" != "$p3" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Placeholder replacement
# ─────────────────────────────────────────────────────────────────────────────

@test "bootstrap replaces change_me_ placeholder passwords" {
  _infra_env="$(INFRA_ENV_PATH)"
  cp "$TEST_WORKSPACE/IdeaProjects/consolidated-postgres/env/.env.local.example" "$_infra_env"
  # Write placeholder values
  printf 'EVENTS_TRACKER_DB_USER=\nEVENTS_TRACKER_DB_PASSWORD=change_me_placeholder\n' >> "$_infra_env"
  run_bootstrap
  val="$(get_val "$_infra_env" "EVENTS_TRACKER_DB_PASSWORD")"
  [ "$val" != "change_me_placeholder" ]
  [ -n "$val" ]
}

@test "bootstrap does NOT overwrite existing non-placeholder password" {
  _infra_env="$(INFRA_ENV_PATH)"
  cp "$TEST_WORKSPACE/IdeaProjects/consolidated-postgres/env/.env.local.example" "$_infra_env"
  # Pre-set a real password
  printf 'EVENTS_TRACKER_DB_PASSWORD=my_real_secret\n' >> "$_infra_env"
  run_bootstrap
  val="$(get_val "$_infra_env" "EVENTS_TRACKER_DB_PASSWORD")"
  [ "$val" = "my_real_secret" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Credential propagation to project .env files
# ─────────────────────────────────────────────────────────────────────────────

@test "eventstracker .env has EVENTS_TRACKER_DB_URL pointing to localhost:6433" {
  run_bootstrap
  val="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_URL")"
  [[ "$val" == *"localhost:6433"* ]]
}

@test "eventstracker .env EVENTS_TRACKER_DB_USER matches infra .env" {
  run_bootstrap
  infra_user="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_USER")"
  et_user="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_USER")"
  [ "$infra_user" = "$et_user" ]
}

@test "eventstracker .env EVENTS_TRACKER_DB_PASSWORD matches infra .env" {
  run_bootstrap
  infra_pass="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_PASSWORD")"
  et_pass="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_PASSWORD")"
  [ "$infra_pass" = "$et_pass" ]
}

@test "eventstracker .env RABBITMQ_USERNAME matches infra .env" {
  run_bootstrap
  infra_ru="$(get_val "$(INFRA_ENV_PATH)" "RABBITMQ_USERNAME")"
  et_ru="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "RABBITMQ_USERNAME")"
  [ "$infra_ru" = "$et_ru" ]
}

@test "eventstracker .env RABBITMQ_HOST is localhost" {
  run_bootstrap
  val="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "RABBITMQ_HOST")"
  [ "$val" = "localhost" ]
}

@test "eventstracker .env RABBITMQ_PORT is 5672" {
  run_bootstrap
  val="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "RABBITMQ_PORT")"
  [ "$val" = "5672" ]
}

@test "config-server app .env has GIT_URI set" {
  run_bootstrap
  val="$(get_val "$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server/.env" "GIT_URI")"
  [ -n "$val" ]
}

@test "config-server app .env has APP_PORT 8888" {
  run_bootstrap
  val="$(get_val "$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server/.env" "APP_PORT")"
  [ "$val" = "8888" ]
}

@test "config-server app .env username matches jubilant-memory/config/.env" {
  run_bootstrap
  infra_u="$(get_val "$(CONFIG_SERVER_SRC_PATH)" "username")"
  cs_u="$(get_val "$TEST_WORKSPACE/IdeaProjects/sathishproject-config-server/.env" "username")"
  [ "$infra_u" = "$cs_u" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency
# ─────────────────────────────────────────────────────────────────────────────

@test "running bootstrap twice gives the same passwords (idempotent)" {
  run_bootstrap
  pass1="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_PASSWORD")"

  run_bootstrap
  pass2="$(get_val "$(INFRA_ENV_PATH)" "EVENTS_TRACKER_DB_PASSWORD")"

  [ "$pass1" = "$pass2" ]
}

@test "running bootstrap twice gives the same eventstracker credentials" {
  run_bootstrap
  user1="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_USER")"
  pass1="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_PASSWORD")"

  run_bootstrap
  user2="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_USER")"
  pass2="$(get_val "$TEST_WORKSPACE/IdeaProjects/eventstracker/.env" "EVENTS_TRACKER_DB_PASSWORD")"

  [ "$user1" = "$user2" ]
  [ "$pass1" = "$pass2" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Error path: missing template
# ─────────────────────────────────────────────────────────────────────────────

@test "bootstrap exits non-zero when infra env.local.example is missing" {
  rm "$TEST_WORKSPACE/IdeaProjects/consolidated-postgres/env/.env.local.example"
  local rc=0
  HOME="$TEST_WORKSPACE" bash "$BOOTSTRAP_SCRIPT" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ]
}
