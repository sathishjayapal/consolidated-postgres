#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Multi-project Development Environment Startup
#
# Usage: ./multi-dev-up.sh [options]
#
#   --reset     Drop and recreate all databases (clean slate)
#   --help      Show this help message
#
# What it does:
#   1. Starts each project's PostgreSQL container
#   2. Waits for databases to be ready
#   3. Creates/updates .env files via existing project scripts
#   4. Verifies seeded data (configurable checks)
#
# Projects covered:
#   - eventstracker (port 6433, jubilant-memory central stack)
#   - runs-app (port 5443)
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
cd "$REPO_ROOT"

# Configuration
RABBIT_COMPOSE_FILE="$REPO_ROOT/rabbitmq-compose.yml"
RABBIT_CONTAINER_NAME="sathishproject-rabbitmq"

PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CLOUD_MODE=false
RESET_DB=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --reset)
      RESET_DB=true
      shift
      ;;
    --cloud)
      CLOUD_MODE=true
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

# jubilant-memory infra stack (prefer ~/IdeaProjects, fall back to WORKSPACE_ROOT)
if [ -d "$HOME/IdeaProjects/jubilant-memory" ]; then
  _INFRA_DIR="$HOME/IdeaProjects/jubilant-memory/config"
else
  _INFRA_DIR="$WORKSPACE_ROOT/jubilant-memory/config"
fi
if [ ! -f "$_INFRA_DIR/docker-compose.yml" ]; then
  print_error "Missing $_INFRA_DIR/docker-compose.yml — clone jubilant-memory as a sibling of this repo"
  preflight_ok=false
else
  print_status "jubilant-memory/config found"
  if [ ! -f "$_INFRA_DIR/.env" ]; then
    print_error "Missing $_INFRA_DIR/.env"
    print_info "Create it first: cp $_INFRA_DIR/.env.example $_INFRA_DIR/.env"
    preflight_ok=false
  else
    for _required in EVENTS_TRACKER_DB_USER EVENTS_TRACKER_DB_PASSWORD RABBITMQ_USERNAME RABBITMQ_PASSWORD; do
      if ! grep -qE "^${_required}=" "$_INFRA_DIR/.env"; then
        print_error "$_required missing in $_INFRA_DIR/.env"
        preflight_ok=false
      fi
    done
  fi
fi

# Per-project dev-up.sh scripts
for _p in "${PROJECTS[@]}"; do
  if [ -d "$HOME/IdeaProjects/$_p" ]; then
    _dir="$HOME/IdeaProjects/$_p"
  else
    _dir="$WORKSPACE_ROOT/$_p"
  fi
  if [ ! -f "$_dir/dev-up.sh" ]; then
    print_error "Missing $_dir/dev-up.sh"
    preflight_ok=false
  else
    print_status "$_p/dev-up.sh found"
  fi
done

[ "$preflight_ok" = true ] || { print_error "Fix the issues above then re-run"; exit 1; }
print_status "Pre-flight checks passed"
echo ""
# ─────────────────────────────────────────────────────────────────────────────

start_rabbitmq() {
  if [ ! -f "$RABBIT_COMPOSE_FILE" ]; then
    print_info "RabbitMQ compose file not found ($RABBIT_COMPOSE_FILE); skipping broker startup"
    return
  fi

  if docker ps --filter "name=$RABBIT_CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$RABBIT_CONTAINER_NAME$"; then
    print_status "RabbitMQ already running"
    return
  fi

  if docker ps -a --filter "name=$RABBIT_CONTAINER_NAME" --format '{{.Names}}' | grep -q "^$RABBIT_CONTAINER_NAME$"; then
    print_info "Starting existing RabbitMQ container..."
    docker start "$RABBIT_CONTAINER_NAME" >/dev/null 2>&1 || true
  else
    print_info "Starting RabbitMQ..."
    docker compose -f "$RABBIT_COMPOSE_FILE" up -d
  fi

  print_info "Starting RabbitMQ..."
  docker compose -f "$RABBIT_COMPOSE_FILE" up -d >/dev/null 2>&1 || true

  print_info "Waiting up to 30s for RabbitMQ health..."
  attempts=0
  until [ $attempts -ge 30 ]; do
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$RABBIT_CONTAINER_NAME" 2>/dev/null || echo "unknown")
    case "$status" in
      healthy|running)
        print_status "RabbitMQ is healthy"
        return
        ;;
      starting|initializing)
        sleep 1
        ;;
      "unknown"|"")
        sleep 1
        ;;
      *)
        print_error "RabbitMQ health status: $status"
        break
        ;;
    esac
    attempts=$((attempts + 1))
  done
  print_error "RabbitMQ did not become healthy within 30s"
}

if [ "$CLOUD_MODE" = false ]; then
  start_rabbitmq
else
  print_info "Cloud mode detected -- skipping local RabbitMQ startup"
fi

for project in "${PROJECTS[@]}"; do
  # Try machine-specific IdeaProjects first, then fall back to WORKSPACE_ROOT
  if [ -d "$HOME/IdeaProjects/$project" ]; then
    project_dir="$HOME/IdeaProjects/$project"
  else
    project_dir="$WORKSPACE_ROOT/$project"
  fi

  script="$project_dir/dev-up.sh"

  if [ ! -f "$script" ]; then
    print_error "Missing $script (checked $project_dir)"
    exit 1
  fi

  project_upper=$(echo "$project" | tr '[:lower:]' '[:upper:]')
  print_header "$project_upper"

  if [ "$RESET_DB" = true ] && [ "$CLOUD_MODE" = false ]; then
    print_info "Resetting $project (--reset flag)..."
    (cd "$project_dir" && ./dev-up.sh --reset)
  elif [ "$RESET_DB" = true ]; then
    print_info "--reset ignored for $project in cloud mode"
  fi

  print_info "Starting $project..."
  if [ "$CLOUD_MODE" = true ]; then
    (cd "$project_dir" && ./dev-up.sh --cloud)
    print_warn "$project cloud mode: skipping local DB verification"
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

if [ "$CLOUD_MODE" = false ]; then
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

cat <<EON
Next steps:
  1. Start EventTracker:     (cd "$WORKSPACE_ROOT/eventstracker" && ./eventtracker.sh start)
  2. Start Runs App:         (cd "$WORKSPACE_ROOT/runs-app" && mvn spring-boot:run)

Useful commands:
  scripts/local/multi-dev-up.sh --reset     # reset all containers
  scripts/local/multi-dev-down.sh           # stop containers (preserve data)
  scripts/local/multi-dev-down.sh --volumes # stop and delete data
  scripts/local/multi-dev-verify.sh         # verify connectivity & seed data
EON
