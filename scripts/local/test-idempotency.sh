#!/usr/bin/env bash
set -euo pipefail

# Idempotency and cross-machine readiness checks for local orchestration scripts.
# Default mode validates path resolution + required files.
# Use --full to run up/verify/down cycles.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"

FULL_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)
      FULL_MODE=true
      shift
      ;;
    --help)
      cat <<'EOF'
Usage: ./test-idempotency.sh [--full]

  default  Validate cross-machine directory resolution and required script presence.
  --full   Run multi-dev-up twice, verify, then multi-dev-down and verify expected shutdown.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "Testing orchestration idempotency and machine portability..."
echo "REPO_ROOT:      $REPO_ROOT"
echo "WORKSPACE_ROOT: $WORKSPACE_ROOT"
echo

# Source the config library
source "$REPO_ROOT/scripts/lib/project-config.sh"

check_path_resolution() {
  local name="$1"
  local resolved="$2"
  local source_location="workspace"

  if [[ "$resolved" == "$HOME/IdeaProjects/"* ]]; then
    source_location="home"
  fi

  if [ -d "$resolved" ]; then
    echo "  ✓ $name -> $resolved ($source_location)"
  else
    echo "  ✗ $name missing at $resolved"
    return 1
  fi
}

echo "[1/3] Checking shared directory resolution"
check_path_resolution "consolidated-postgres (local infra)" "$(get_infra_config_dir)"
check_path_resolution "sathishproject-config-server" "$(get_config_server_dir)"

for project in "${PROJECTS[@]}"; do
  check_path_resolution "$project" "$(resolve_project_dir "$project")"
  echo "    - db_user: $(get_project_db_user "$project")"
  echo "    - db_name: $(get_project_db_name "$project")"
  echo "    - port:    $(get_project_port "$project")"
  echo "    - cont:    $(get_project_container "$project")"
done

echo
echo "[2/3] Checking required scripts"
for script in "$REPO_ROOT/scripts/local/bootstrap-env.sh" "$REPO_ROOT/scripts/local/multi-dev-up.sh" "$REPO_ROOT/scripts/local/multi-dev-down.sh" "$REPO_ROOT/scripts/local/multi-dev-verify.sh"; do
  if [ -x "$script" ]; then
    echo "  ✓ executable: $script"
  else
    echo "  ✗ not executable: $script"
    exit 1
  fi
done

echo
echo "[3/3] Idempotency checks"
if [ "$FULL_MODE" = true ]; then
  echo "  -> Running multi-dev-up (pass 1)"
  "$REPO_ROOT/scripts/local/multi-dev-up.sh"

  echo "  -> Running multi-dev-up (pass 2, idempotency)"
  "$REPO_ROOT/scripts/local/multi-dev-up.sh"

  echo "  -> Running verify"
  "$REPO_ROOT/scripts/local/multi-dev-verify.sh"

  echo "  -> Bringing everything down"
  "$REPO_ROOT/scripts/local/multi-dev-down.sh"

  echo "  -> Verifying shutdown state"
  if "$REPO_ROOT/scripts/local/multi-dev-verify.sh" >/dev/null 2>&1; then
    echo "  ✗ verify unexpectedly passed after shutdown"
    exit 1
  fi
  echo "  ✓ verify fails after shutdown as expected"
else
  echo "  ✓ Skipped full cycle (run with --full for runtime idempotency test)"
fi

echo
echo "✓ Idempotency harness checks passed"
