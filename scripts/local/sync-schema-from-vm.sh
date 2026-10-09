#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Schema-only sync: VM Postgres -> local "sathish-stack" Postgres
#
# Pulls just the table/schema structure (no rows) from a project's
# database on the remote VM (env/vm.env -> VM_IP) and applies it to
# that same project's database in the LOCAL "sathish-stack" Docker
# Compose project (sathish-stack-<service>-1, running directly on this
# Mac's Docker Desktop — a separate, intentionally-persistent copy of
# the stack, not each project's own ephemeral dev-up.sh container).
#
# This is READ-ONLY against the VM: it only ever runs pg_dump there,
# never writes back. The local database is dropped and recreated
# before the dump is applied, so each run gives a clean, exact match.
#
# Usage:
#   ./sync-schema-from-vm.sh <project> [project...] [--dry-run]
#
#   Projects: runs-app, runs-ai-analyzer, eventstracker, mytracker
#             (any project with a get_project_db_service mapping)
#
# Options:
#   --dry-run   Print what would run; don't touch the VM or local container.
#   --help      Show this help
#
# Requires: the project's sathish-stack-<service>-1 container already
#           running locally, pg_dump/psql client tools, env/vm.env filled in.
#
# Credentials are read directly from the running local container's own
# POSTGRES_USER/POSTGRES_DB/POSTGRES_PASSWORD env (ground truth — avoids
# relying on any project .env, which may legitimately be pointed elsewhere,
# e.g. runs-ai-analyzer's .env is often live-pointed at the VM itself).
# This assumes local and VM credentials match (they're supposed to, by
# design of vm-db-up.sh) — if pg_dump auth fails, that's credential drift;
# check scripts/vm/check-stack-consistency.sh --roles.
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

VM_ENV_FILE="$REPO_ROOT/env/vm.env"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1" >&2; }
print_info()   { echo -e "${YELLOW}ℹ${NC} $1"; }
die()          { print_error "$1"; exit 1; }

ALLOWED=(runs-app runs-ai-analyzer eventstracker mytracker)

DRY_RUN=false
SELECTED=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --help|-h) sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*) die "Unknown option: $arg" ;;
    *)
      if [[ " ${ALLOWED[*]} " != *" $arg "* ]]; then
        die "Unknown project '$arg' — must be one of: ${ALLOWED[*]}"
      fi
      SELECTED+=("$arg")
      ;;
  esac
done
[ ${#SELECTED[@]} -gt 0 ] || die "No projects given. Usage: ./sync-schema-from-vm.sh <project...> [--dry-run]"

command -v pg_dump >/dev/null 2>&1 || die "pg_dump not found — brew install postgresql"
command -v psql >/dev/null 2>&1 || die "psql not found — brew install postgresql"

[ -f "$VM_ENV_FILE" ] || die "Missing $VM_ENV_FILE — cp env/vm.env.example env/vm.env and fill in VM_IP"
VM_IP="$(grep -E '^VM_IP=' "$VM_ENV_FILE" | tail -n 1 | cut -d'=' -f2-)"
[ -n "$VM_IP" ] || die "VM_IP not set in $VM_ENV_FILE"

for PROJECT in "${SELECTED[@]}"; do
  echo ""
  print_info "== $PROJECT =="

  PORT="$(get_project_port "$PROJECT")" || die "$PROJECT has no VM port mapping"
  DB_SERVICE="$(get_project_db_service "$PROJECT")" || die "$PROJECT has no VM stack service mapping"
  LOCAL_CONTAINER="sathish-stack-${DB_SERVICE}-1"

  if ! docker ps --filter "name=^${LOCAL_CONTAINER}$" --format '{{.Names}}' | grep -q "^${LOCAL_CONTAINER}$"; then
    die "$LOCAL_CONTAINER is not running on this Mac — check 'docker ps' for the sathish-stack containers"
  fi

  get_local_env() {
    docker inspect "$LOCAL_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "^$1=" | tail -n 1 | cut -d'=' -f2-
  }
  DB_USER="$(get_local_env POSTGRES_USER)"
  DB_NAME="$(get_local_env POSTGRES_DB)"
  DB_PASSWORD="$(get_local_env POSTGRES_PASSWORD)"
  [ -n "$DB_USER" ] && [ -n "$DB_NAME" ] && [ -n "$DB_PASSWORD" ] \
    || die "Could not read POSTGRES_USER/DB/PASSWORD from $LOCAL_CONTAINER"

  DUMP_FILE="$(mktemp -t "${PROJECT}-schema").sql"
  trap 'rm -f "$DUMP_FILE"' RETURN

  print_info "Dumping schema only from VM ($VM_IP:$PORT/$DB_NAME) — read-only, no data"
  if $DRY_RUN; then
    echo "  PGPASSWORD=*** pg_dump -h $VM_IP -p $PORT -U $DB_USER -d $DB_NAME --schema-only --no-owner --no-privileges -f $DUMP_FILE"
  else
    PGPASSWORD="$DB_PASSWORD" pg_dump -h "$VM_IP" -p "$PORT" -U "$DB_USER" -d "$DB_NAME" \
      --schema-only --no-owner --no-privileges -f "$DUMP_FILE" \
      || die "pg_dump against VM failed for $PROJECT — check VM is reachable and credentials match (see scripts/vm/check-stack-consistency.sh --roles)"
    print_status "Schema dumped ($(wc -l < "$DUMP_FILE" | tr -d ' ') lines)"
  fi

  print_info "Recreating local DB '$DB_NAME' in $LOCAL_CONTAINER and applying schema"
  if $DRY_RUN; then
    echo "  docker exec $LOCAL_CONTAINER dropdb -U $DB_USER --if-exists $DB_NAME"
    echo "  docker exec $LOCAL_CONTAINER createdb -U $DB_USER -O $DB_USER $DB_NAME"
    echo "  docker exec -i $LOCAL_CONTAINER psql -U $DB_USER -d $DB_NAME < $DUMP_FILE"
    print_status "(dry run — nothing executed)"
    continue
  fi

  docker exec "$LOCAL_CONTAINER" psql -U "$DB_USER" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$LOCAL_CONTAINER" dropdb -U "$DB_USER" --if-exists "$DB_NAME" \
    || die "Failed to drop local DB $DB_NAME"
  docker exec "$LOCAL_CONTAINER" createdb -U "$DB_USER" -O "$DB_USER" "$DB_NAME" \
    || die "Failed to recreate local DB $DB_NAME"
  docker exec -i "$LOCAL_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$DUMP_FILE" \
    || die "Failed to apply schema dump to $LOCAL_CONTAINER"

  print_status "$PROJECT local DB now matches VM schema (no data copied)"
done

echo ""
print_status "Done. Start the app normally (mvn spring-boot:run) — Flyway will see the synced schema/history and should not try to re-run migrations."
