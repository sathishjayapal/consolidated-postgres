#!/usr/bin/env bash
set -euo pipefail

# List all managed projects and their configuration
# Usage: ./list-projects.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"

source "$REPO_ROOT/scripts/lib/project-config.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Managed Projects Configuration${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Source:${NC} $REPO_ROOT/projects.txt"
echo -e "${YELLOW}Total Projects:${NC} ${#PROJECTS[@]}"
echo ""

for project in "${PROJECTS[@]}"; do
  echo -e "${GREEN}Project: $project${NC}"
  echo "  Port:           $(get_project_port "$project")"
  echo "  Container:      $(get_project_container "$project")"
  echo "  Database:       $(get_project_db_name "$project")"
  echo "  Seed Table:     $(get_project_seed_table "$project")"
  echo "  Password Var:   $(get_project_password_env_var "$project")"
  echo "  Password Key:   $(get_project_env_password_key "$project")"
  
  # Check if dev-up.sh exists
  project_dir="$(resolve_project_dir "$project")"
  if [ -f "$project_dir/dev-up.sh" ]; then
    echo -e "  dev-up.sh:      ${GREEN}✓ exists${NC}"
  else
    echo -e "  dev-up.sh:      ${YELLOW}✗ missing${NC}"
  fi
  
  # Check if .env exists
  if [ -f "$project_dir/.env" ]; then
    echo -e "  .env:           ${GREEN}✓ exists${NC}"
  else
    echo -e "  .env:           ${YELLOW}✗ not created yet${NC}"
  fi
  
  echo ""
done

echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}To add a new project:${NC}"
echo "  1. Edit: $REPO_ROOT/projects.txt"
echo "  2. Add metadata to: scripts/lib/project-config.sh"
echo "  3. Create: <project>/dev-up.sh"
echo ""
echo -e "${GREEN}Documentation:${NC}"
echo "  - QUICK_START.md - Quick reference"
echo "  - PROJECTS.md    - Full guide"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
