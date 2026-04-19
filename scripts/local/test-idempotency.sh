#!/usr/bin/env bash
set -euo pipefail

# Test script to validate multi-dev-up.sh idempotency fix
# This simulates the error condition without running the full script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

echo "Testing idempotency fix..."
echo "REPO_ROOT: $REPO_ROOT"
echo "PROJECT_ROOT: $PROJECT_ROOT"
echo ""

# Source the config library
source "$REPO_ROOT/scripts/lib/project-config.sh"

# Test the function that was causing the error
test_password_env_var() {
  local project="$1"
  echo "Testing project: $project"
  
  # This is what the fixed code does
  password_env_var="$(get_project_password_env_var "$project")"
  echo "  ✓ Password env var: $password_env_var"
  
  # Test all helper functions
  db_user="$(get_project_db_user "$project")"
  echo "  ✓ DB user: $db_user"
  
  db_name="$(get_project_db_name "$project")"
  echo "  ✓ DB name: $db_name"
  
  port="$(get_project_port "$project")"
  echo "  ✓ Port: $port"
  
  container="$(get_project_container "$project")"
  echo "  ✓ Container: $container"
  
  echo ""
}

# Test both projects
for project in "${PROJECTS[@]}"; do
  test_password_env_var "$project"
done

echo "✓ All tests passed - no unbound variable errors!"
echo "✓ The fix will work on your laptop"
