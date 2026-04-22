#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Multi-project Development Environment Shutdown
#
# Usage: ./multi-dev-down.sh [options]
#
# Options:
#   --volumes   Also remove volumes (DELETES data)
#   --help      Show this help message
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

RABBIT_COMPOSE_FILE="$REPO_ROOT/rabbitmq-compose.yml"
CONFIG_SERVER_DIR="$(get_config_server_dir)"
CONFIG_SERVER_CONTAINER="$(get_config_server_container)"
RABBIT_CONTAINER="$(get_rabbitmq_container)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REMOVE_VOLUMES=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --volumes)
      REMOVE_VOLUMES=true
      shift
      ;;
    --help)
      head -n 20 "$0" | tail -n +2
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_info() { echo -e "${YELLOW}ℹ${NC} $1"; }
print_warn() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

force_remove_container_if_exists() {
  local container="$1"
  if docker ps -a --filter "name=^${container}$" --format '{{.Names}}' | grep -q "^${container}$"; then
    if [ "$REMOVE_VOLUMES" = true ]; then
      docker rm -f -v "$container" >/dev/null 2>&1 || {
        print_error "Failed to remove container $container"
        return 1
      }
      print_status "Container removed with volumes: $container"
    else
      docker rm -f "$container" >/dev/null 2>&1 || {
        print_error "Failed to remove container $container"
        return 1
      }
      print_status "Container removed: $container"
    fi
  fi
  return 0
}

stop_project_stack() {
  local project="$1"
  local project_dir
  local container
  project_dir="$(resolve_project_dir "$project")"
  container="$(get_project_container "$project")"

  if [ ! -d "$project_dir" ]; then
    print_error "Missing project directory $project_dir"
    return 1
  fi

  print_info "Stopping $project..."
  args=(down)
  if [ "$REMOVE_VOLUMES" = true ]; then
    args+=(--volumes)
  fi

  if (cd "$project_dir" && docker compose "${args[@]}"); then
    if [ "$REMOVE_VOLUMES" = true ]; then
      print_status "$project stopped and volumes removed"
    else
      print_status "$project stopped"
    fi
  else
    print_error "Failed to stop $project"
    return 1
  fi

  # Ensure project DB container is stopped even when it was started from another compose file.
  force_remove_container_if_exists "$container" || return 1

  return 0
}

stop_config_server() {
  if [ ! -f "$CONFIG_SERVER_DIR/docker-compose.yml" ]; then
    print_info "Config server compose file not found ($CONFIG_SERVER_DIR/docker-compose.yml); skipping"
    return
  fi

  print_info "Stopping config server stack..."
  if (cd "$CONFIG_SERVER_DIR" && docker compose down); then
    print_status "Config server stack stopped"
  else
    print_error "Failed to stop config server stack"
    exit 1
  fi
}

stop_rabbitmq() {
  if [ ! -f "$RABBIT_COMPOSE_FILE" ]; then
    print_info "RabbitMQ compose file not found ($RABBIT_COMPOSE_FILE); skipping"
    return
  fi
  print_info "Stopping RabbitMQ..."
  if docker compose -f "$RABBIT_COMPOSE_FILE" down >/dev/null 2>&1; then
    print_status "RabbitMQ stopped"
  else
    print_error "Failed to stop RabbitMQ"
    exit 1
  fi
}

stop_config_server
stop_rabbitmq

for project in "${PROJECTS[@]}"; do
  stop_project_stack "$project"
done

print_info "Container status summary:"
# Build container list dynamically from PROJECTS array
containers=("$CONFIG_SERVER_CONTAINER" "$RABBIT_CONTAINER")
for project in "${PROJECTS[@]}"; do
  containers+=("$(get_project_container "$project")")
done

for container in "${containers[@]}"; do
  if docker ps --filter "name=$container" --format '{{.Names}}' | grep -q "^$container$"; then
    print_warn "still running: $container"
  else
    print_status "not running: $container"
  fi
done

print_status "All projects stopped"
