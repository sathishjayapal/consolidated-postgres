#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Multi-project Development Environment Startup
#
# Usage: ./multi-dev-up.sh [options]
#
#   --reset     Drop and recreate all databases (clean slate)
#   --acg       Point apps at a running ACG sandbox instead of local containers
#   --prod      Point apps at the persistent prod DB instead of local containers
#   --help      Show this help message
#
# What it does:

#   1. Starts each project's PostgreSQL container
#   2. Waits for databases to be ready
#   3. Creates/updates .env files via existing project scripts
#   4. Verifies seeded data (configurable checks)
#
# Projects are defined in: projects.txt
# Add new projects there - they will be automatically included.
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
cd "$REPO_ROOT"

# Configuration
RABBIT_COMPOSE_FILE="$REPO_ROOT/compose/rabbitmq-compose.yml"
RABBIT_CONTAINER_NAME="sathishproject-rabbitmq"

PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

RABBIT_CONTAINER_NAME="$(get_rabbitmq_container)"
CONFIG_SERVER_CONTAINER="$(get_config_server_container)"
CONFIG_SERVER_DIR="$(get_config_server_dir)"
CONFIG_SERVER_ENV="$(get_config_server_env_file)"
INFRA_DIR="$(get_infra_config_dir)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ACG_MODE=false
PROD_MODE=false
RESET_DB=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --reset)
      RESET_DB=true
      shift
      ;;
    --acg)
      ACG_MODE=true
      shift
      ;;
    --prod)
      PROD_MODE=true
      shift
      ;;
    --help)
      head -n 30 "$SCRIPT_DIR/multi-dev-up.sh" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if $ACG_MODE && $PROD_MODE; then
  echo "--acg and --prod are mutually exclusive"
  exit 1
fi
PROFILE_FLAG=""
$ACG_MODE && PROFILE_FLAG="--acg"
$PROD_MODE && PROFILE_FLAG="--prod"

print_status() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

print_info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

print_warn() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_header() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Check Docker
if ! docker ps > /dev/null 2>&1; then
  print_error "Docker is not running. Start Docker Desktop and retry."
  exit 1
fi

print_header "Multi-Project Dev Environment Startup"

# Bootstrap machine-local env files for infra + apps
BOOTSTRAP_SCRIPT="$SCRIPT_DIR/bootstrap-env.sh"
if [ -x "$BOOTSTRAP_SCRIPT" ]; then
  "$BOOTSTRAP_SCRIPT"
else
  print_error "Missing or not executable: $BOOTSTRAP_SCRIPT"
  print_info "Run: chmod 755 $BOOTSTRAP_SCRIPT"
  exit 1
fi

# ── Pre-flight sanity checks ──────────────────────────────────────────────────
preflight_ok=true

# Docker
if ! docker ps > /dev/null 2>&1; then
  print_error "Docker is not running — start Docker Desktop first"
  preflight_ok=false
fi

if [ ! -f "$INFRA_DIR/docker-compose.yml" ]; then
  print_error "Missing $INFRA_DIR/docker-compose.yml — clone jubilant-memory as a sibling of this repo"
  preflight_ok=false
else
  print_status "jubilant-memory/config found"
  if [ ! -f "$INFRA_DIR/.env" ]; then
    print_error "Missing $INFRA_DIR/.env"
    print_info "Create it first: cp $INFRA_DIR/.env.example $INFRA_DIR/.env"
    preflight_ok=false
  else
    for _required in EVENTS_TRACKER_DB_USER EVENTS_TRACKER_DB_PASSWORD RUNS_AI_ANALYZER_DB_USER RUNS_AI_ANALYZER_DB_PASSWORD RABBITMQ_USERNAME RABBITMQ_PASSWORD; do
      if ! grep -qE "^${_required}=" "$INFRA_DIR/.env"; then
        print_error "$_required missing in $INFRA_DIR/.env"
        preflight_ok=false
      fi
    done
  fi
fi

# config-server stack
if [ ! -f "$CONFIG_SERVER_DIR/docker-compose.yml" ]; then
  print_error "Missing $CONFIG_SERVER_DIR/docker-compose.yml"
  preflight_ok=false
else
  print_status "sathishproject-config-server found"
fi

if [ ! -f "$CONFIG_SERVER_ENV" ]; then
  print_error "Missing $CONFIG_SERVER_ENV"
  print_info "Run: $SCRIPT_DIR/bootstrap-env.sh"
  preflight_ok=false
fi

# Per-project dev-up.sh scripts (projects without one are VM/ACG-only — skipped here)
for _p in "${PROJECTS[@]}"; do
  _dir="$(resolve_project_dir "$_p")"
  if [ ! -f "$_dir/dev-up.sh" ]; then
    print_info "$_p has no dev-up.sh — skipped by local orchestration (managed via scripts/vm or ACG)"
  else
    print_status "$_p/dev-up.sh found"
  fi
done

[ "$preflight_ok" = true ] || { print_error "Fix the issues above then re-run"; exit 1; }
print_status "Pre-flight checks passed"
echo ""
# ─────────────────────────────────────────────────────────────────────────────

start_rabbitmq() {
  local rabbit_user rabbit_pass
  rabbit_user=$(grep -E '^RABBITMQ_USERNAME=' "$INFRA_DIR/.env" | tail -n 1 | cut -d'=' -f2- || true)
  rabbit_pass=$(grep -E '^RABBITMQ_PASSWORD=' "$INFRA_DIR/.env" | tail -n 1 | cut -d'=' -f2- || true)

  if [ -z "$rabbit_user" ] || [ -z "$rabbit_pass" ]; then
    print_error "RABBITMQ_USERNAME/RABBITMQ_PASSWORD missing in $INFRA_DIR/.env"
    exit 1
  fi

  if [ ! -f "$RABBIT_COMPOSE_FILE" ]; then
    print_info "RabbitMQ compose file not found ($RABBIT_COMPOSE_FILE); skipping broker startup"
    return
  fi

  if docker ps --filter "name=$RABBIT_CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$RABBIT_CONTAINER_NAME$"; then
    print_status "RabbitMQ already running"
  elif docker ps -a --filter "name=$RABBIT_CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$RABBIT_CONTAINER_NAME$"; then
    print_info "Starting existing RabbitMQ container..."
    docker start "$RABBIT_CONTAINER_NAME" >/dev/null 2>&1 || true
  else
    print_info "Starting RabbitMQ..."
    docker compose --env-file "$INFRA_DIR/.env" -f "$RABBIT_COMPOSE_FILE" up -d
  fi

  print_info "Starting RabbitMQ..."
  docker compose --env-file "$INFRA_DIR/.env" -f "$RABBIT_COMPOSE_FILE" up -d >/dev/null 2>&1 || true

  print_info "Waiting up to 60s for RabbitMQ health..."
  attempts=0
  until [ $attempts -ge 60 ]; do
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$RABBIT_CONTAINER_NAME" 2>/dev/null || echo "unknown")
    case "$status" in
      healthy|running)
        print_status "RabbitMQ is healthy"
        break
        ;;
      starting|initializing|"unknown"|"")
        sleep 1
        attempts=$((attempts + 1))
        ;;
      *)
        print_error "RabbitMQ health status: $status"
        exit 1
        ;;
    esac
  done
  if [ $attempts -ge 60 ]; then
    print_error "RabbitMQ did not become healthy within 60s"
    exit 1
  fi

  print_info "Syncing RabbitMQ credentials for user '$rabbit_user'..."
  if docker exec "$RABBIT_CONTAINER_NAME" rabbitmqctl list_users | awk '{print $1}' | grep -qx "$rabbit_user"; then
    docker exec "$RABBIT_CONTAINER_NAME" rabbitmqctl change_password "$rabbit_user" "$rabbit_pass" >/dev/null
  else
    docker exec "$RABBIT_CONTAINER_NAME" rabbitmqctl add_user "$rabbit_user" "$rabbit_pass" >/dev/null
  fi
  docker exec "$RABBIT_CONTAINER_NAME" rabbitmqctl set_permissions -p / "$rabbit_user" ".*" ".*" ".*" >/dev/null

  if docker exec "$RABBIT_CONTAINER_NAME" rabbitmqctl authenticate_user "$rabbit_user" "$rabbit_pass" >/dev/null 2>&1; then
    print_status "RabbitMQ credentials synced and verified for '$rabbit_user'"
  else
    print_error "RabbitMQ credentials verification failed for '$rabbit_user'"
    exit 1
  fi
}

start_config_server() {
  local config_user config_pass config_port
  config_user=$(grep -E '^username=' "$CONFIG_SERVER_ENV" | tail -n 1 | cut -d'=' -f2- || true)
  config_pass=$(grep -E '^pass=' "$CONFIG_SERVER_ENV" | tail -n 1 | cut -d'=' -f2- || true)
  config_port=$(grep -E '^APP_PORT=' "$CONFIG_SERVER_ENV" | tail -n 1 | cut -d'=' -f2- || true)

  if [ -z "$config_user" ] || [ -z "$config_pass" ]; then
    print_error "username/pass missing in $CONFIG_SERVER_ENV"
    exit 1
  fi
  [ -n "$config_port" ] || config_port="8888"

  print_header "CONFIG-SERVER"
  print_info "Force-recreating config-server to apply current .env"
  (cd "$CONFIG_SERVER_DIR" && docker compose --env-file "$CONFIG_SERVER_ENV" up -d --force-recreate config-server)

  print_info "Waiting up to 60s for config-server readiness..."
  local attempts=0
  until [ $attempts -ge 60 ]; do
    if curl -sf -u "$config_user:$config_pass" "http://localhost:${config_port}/eventstracker/local" >/dev/null 2>&1; then
      print_status "Config server is ready on port $config_port"
      return
    fi
    attempts=$((attempts + 1))
    sleep 1
  done

  print_error "Config server did not become ready within 60s"
  docker logs --tail 60 "$CONFIG_SERVER_CONTAINER" 2>/dev/null || true
  exit 1
}

if [ -z "$PROFILE_FLAG" ]; then
  start_config_server
  start_rabbitmq
else
  print_info "$PROFILE_FLAG mode detected -- skipping local config-server and RabbitMQ startup"
fi

for project in "${PROJECTS[@]}"; do
  # Try machine-specific IdeaProjects first, then fall back to WORKSPACE_ROOT
  project_dir="$(resolve_project_dir "$project")"

  script="$project_dir/dev-up.sh"

  if [ ! -f "$script" ]; then
    print_info "Skipping $project — no dev-up.sh (managed via scripts/vm or ACG)"
    continue
  fi

  project_upper=$(echo "$project" | tr '[:lower:]' '[:upper:]')
  print_header "$project_upper"

  if [ "$RESET_DB" = true ] && [ -z "$PROFILE_FLAG" ]; then
    print_info "Resetting $project (--reset flag)..."
    (cd "$project_dir" && ./dev-up.sh --reset)
  elif [ "$RESET_DB" = true ]; then
    print_info "--reset ignored for $project in $PROFILE_FLAG mode"
  fi

  print_info "Starting $project..."
  if [ -n "$PROFILE_FLAG" ]; then
    (cd "$project_dir" && ./dev-up.sh "$PROFILE_FLAG")
    print_warn "$project $PROFILE_FLAG mode: skipping local DB verification"
    continue
  else
    (cd "$project_dir" && ./dev-up.sh)
  fi

  port=$(get_project_port "$project")
  db=$(get_project_db_name "$project")
  user=$(get_project_db_user "$project")
  container=$(get_project_container "$project")

  print_info "Waiting for port $port to be open..."
  retries=30
  while ! nc -z localhost "$port" >/dev/null 2>&1; do
    sleep 1
    retries=$((retries - 1))
    if [ $retries -le 0 ]; then
      print_error "$project database still not available on port $port"
      exit 1
    fi
  done
  print_status "$project database listening on port $port"

  password="$(get_project_password "$project" || true)"
  if [ -z "$password" ]; then
    password_env_var="$(get_project_password_env_var "$project")"
    print_error "Unable to determine password for $project. Ensure $project/.env exists or set $password_env_var"
    exit 1
  fi

  print_info "Verifying connection for $project (user=$user, db=$db, container=$container)..."
  _psql_err=$(docker exec "$container" psql -U "$user" -d "$db" -c "SELECT 1;" 2>&1) || {
    print_error "Failed to connect to $db in container $container"
    print_error "psql output: $_psql_err"
    exit 1
  }
  print_status "$project database connection verified"

  print_info "Checking Flyway history for $project..."
  if docker exec "$container" psql -U "$user" -d "$db" -c "SELECT version, success FROM flyway_schema_history ORDER BY installed_on DESC LIMIT 1;" >/dev/null 2>&1; then
    print_status "Flyway migrations detected"
  else
    print_info "flyway_schema_history not found yet (will be created on app startup)"
  fi

done

print_header "Seed Data Verification"

if [ -z "$PROFILE_FLAG" ]; then
  # EventTracker seed check
  if password=$(get_project_password "eventstracker"); then
    _et_port=$(get_project_port "eventstracker")
    _et_db=$(get_project_db_name "eventstracker")
    _et_user=$(get_project_db_user "eventstracker")
    print_info "Checking EventTracker seed data..."
    _et_container=$(get_project_container "eventstracker")
    if docker exec "$_et_container" psql -U "$_et_user" -d "$_et_db" -t -A -c "SELECT to_regclass('public.domain')" | grep -q domain; then
      count=$(docker exec "$_et_container" psql -U "$_et_user" -d "$_et_db" -t -A -c "SELECT COUNT(*) FROM domain;")
      print_status "EventTracker domain count: $count"
    else
      print_info "EventTracker schema not applied yet (start app to run Flyway)"
    fi
  else
    print_warn "Skipping EventTracker seed check (no password available)"
  fi

  # Runs App seed check
  if password=$(get_project_password "runs-app"); then
    _ra_port=$(get_project_port "runs-app")
    _ra_db=$(get_project_db_name "runs-app")
    _ra_user=$(get_project_db_user "runs-app")
    print_info "Checking Runs App seed data..."
    _ra_container=$(get_project_container "runs-app")
    if docker exec "$_ra_container" psql -U "$_ra_user" -d "$_ra_db" -t -A -c "SELECT to_regclass('public.run_app_user')" | grep -q run_app_user; then
      runs_count=$(docker exec "$_ra_container" psql -U "$_ra_user" -d "$_ra_db" -t -A -c "SELECT COUNT(*) FROM run_app_user;")
      print_status "Runs App run_app_user count: $runs_count"
    else
      print_info "Runs App schema not applied yet (start app to run Flyway)"
    fi
  else
    print_warn "Skipping Runs App seed check (no password available)"
  fi
else
  print_warn "Cloud mode: skipping local seed data assertions"
fi

print_header "Startup Complete"

EVENTSTRACKER_DIR="$(resolve_project_dir eventstracker)"
RUNS_APP_DIR="$(resolve_project_dir runs-app)"
RUNS_AI_ANALYZER_DIR="$(resolve_project_dir runs-ai-analyzer)"

cat <<EON
Next steps - START IN THIS ORDER (CRITICAL for event-driven integration):
  
  1. Start EventTracker FIRST (provisions RabbitMQ queues):
     (cd "$EVENTSTRACKER_DIR" && ./mvnw spring-boot:run)
     Wait for: "Declared queue: q.sathishprojects.garmin.ops.events"
  
  2. Start Runs App (validates queues exist):
     (cd "$RUNS_APP_DIR" && ./mvnw spring-boot:run)
     Wait for: "Validated Garmin OPS queue exists"
  
  3. Start Runs AI Analyzer (consumes from queues):
     (cd "$RUNS_AI_ANALYZER_DIR" && ./mvnw spring-boot:run)
     Wait for: "RabbitMQ listener factory configured"

⚠️  IMPORTANT: EventTracker MUST start first to provision RabbitMQ queues!
    If you start services out of order, runs-app will fail with "queue not found"

Useful commands:
  scripts/local/multi-dev-up.sh --reset     # reset all containers
  scripts/local/multi-dev-down.sh           # stop containers (preserve data)
  scripts/local/multi-dev-down.sh --volumes # stop and delete data
  scripts/local/multi-dev-verify.sh         # verify connectivity & seed data
  
Troubleshooting:
  cd "$RUNS_AI_ANALYZER_DIR" && ./diagnose_integration.sh
EON
