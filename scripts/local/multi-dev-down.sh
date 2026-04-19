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
cd "$SCRIPT_DIR"

PROJECT_ROOT="$SCRIPT_DIR/.."

PROJECTS=(
  "eventstracker:eventstracker-postgres"
  "runs-app:runs-app-postgres"
)

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
print_error() { echo -e "${RED}✗${NC} $1"; }

for entry in "${PROJECTS[@]}"; do
  IFS=':' read -r project container <<< "$entry"
  project_dir="$PROJECT_ROOT/$project"

  if [ ! -d "$project_dir" ]; then
    print_error "Missing project directory $project_dir"
    exit 1
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
    exit 1
  fi

done

print_status "All projects stopped"
