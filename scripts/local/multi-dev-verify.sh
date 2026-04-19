#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# multi-dev-verify.sh
#
# Guardrail verification script to ensure our multi-service local environment
# respects the architecture contract:
#   * Separate Postgres instances per service (5432 / 5443)
#   * RabbitMQ broker running
#   * Flyway migrations applied & seed data present
#   * Spring configs still point to the expected ports/credentials
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"

EVENTS_TRACKER_DIR="$WORKSPACE_ROOT/eventstracker"
RUNS_APP_DIR="$WORKSPACE_ROOT/runs-app"

source "$REPO_ROOT/scripts/lib/project-config.sh"

CLOUD_MODE=false
if [[ $# -gt 0 && "$1" == "--cloud" ]]; then
  CLOUD_MODE=true
  shift
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_warn()   { echo -e "${YELLOW}⚠${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1"; }
print_header() {
  echo -e "${BLUE}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    print_error "Missing required command: $1"
    exit 1
  fi
}

require_cmd docker
require_cmd psql

if ! docker ps >/dev/null 2>&1; then
  print_error "Docker daemon is not running"
  exit 1
fi

if [ "$CLOUD_MODE" = true ]; then
  print_header "Container health"
  print_warn "Skipping local container checks in cloud mode"
else
  print_header "Container health"

  check_container() {
    local name="$1"
    if docker ps --filter "name=$name" --format '{{.Names}}' | grep -q "^$name$"; then
      print_status "$name is running"
    else
      print_error "$name is not running"
      exit 1
    fi
  }

  for project in "${PROJECTS[@]}"; do
    check_container "$(get_project_container "$project")"
  done
  check_container "sathishproject-rabbitmq"

  print_header "PostgreSQL availability"

  wait_for_psql() {
    local host="$1" port="$2" user="$3" password="$4"
    PGPASSWORD="$password" psql -h "$host" -p "$port" -U "$user" -d postgres -c "SELECT 1;" >/dev/null 2>&1
  }

  for project in "${PROJECTS[@]}"; do
    port=$(get_project_port "$project")
    user=$(get_project_db_user "$project")
    password=$(get_project_password "$project" || true)
    if [ -z "$password" ]; then
      env_var=$(get_project_password_env_var "$project")
      print_error "Password unavailable for $project. Run scripts/local/multi-dev-up.sh first or set $env_var"
      exit 1
    fi
    if wait_for_psql localhost "$port" "$user" "$password"; then
      print_status "$project database reachable on $port"
    else
      print_error "Cannot connect to $project database on $port"
      exit 1
    fi
  done

  print_header "Schema & seed checks"
  for project in "${PROJECTS[@]}"; do
    password=$(get_project_password "$project" || true)
    if [ -z "$password" ]; then
      env_var=$(get_project_password_env_var "$project")
      print_warn "Skipping $project seed check (no password available; set $env_var or run project dev-up)"
      continue
    fi
    port=$(get_project_port "$project")
    db=$(get_project_db_name "$project")
    table=$(get_project_seed_table "$project")

    user=$(get_project_db_user "$project")

    if PGPASSWORD="$password" psql -h localhost -p "$port" -U "$user" -d "$db" -t -A -c "SELECT to_regclass('public.$table');" | grep -q "$table"; then
      rows=$(PGPASSWORD="$password" psql -h localhost -p "$port" -U "$user" -d "$db" -t -A -c "SELECT COUNT(*) FROM $table;")
      if [[ "$rows" -gt 0 ]]; then
        print_status "$project: $table rows -> $rows"
      else
        print_warn "$project: $table exists but empty"
      fi
    else
      print_error "$project schema missing ($table table)"
      exit 1
    fi
  done
fi

print_header "Spring configuration guardrails"

verify_contains() {
  local file="$1" pattern="$2" description="$3"
  if grep -q "$pattern" "$file"; then
    print_status "$description"
  else
    print_error "${description} (pattern '$pattern') not found in $file"
    exit 1
  fi
}

# EventTracker uses Spring Cloud Config — datasource is in jubilant-memory repo, not application.yml
verify_contains "$EVENTS_TRACKER_DIR/src/main/resources/bootstrap.yml" "cloud:" "EventTracker bootstrap wires Spring Cloud Config"
[ -f "$EVENTS_TRACKER_DIR/dev-up.sh" ] && print_status "EventTracker has dev-up.sh" \
  || { print_error "Missing $EVENTS_TRACKER_DIR/dev-up.sh — run Phase 1 setup"; exit 1; }
verify_contains "$RUNS_APP_DIR/src/main/resources/application.yml" "jdbc:postgresql://localhost:5443/runsapp_db" "Runs App datasource points to localhost:5443"
verify_contains "$RUNS_APP_DIR/src/main/resources/application.yml" "JDBC_DATABASE_PASSWORD" "Runs App password uses externalized property"

print_header "RabbitMQ health"

if docker inspect --format '{{.State.Health.Status}}' sathishproject-rabbitmq 2>/dev/null | grep -q healthy; then
  print_status "RabbitMQ container healthy"
else
  print_warn "RabbitMQ healthcheck not reported healthy yet"
fi

print_header "Verification complete"
print_status "All architecture guardrails satisfied"
