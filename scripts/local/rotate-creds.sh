#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Rotates local golden credentials in env/.env.local — generalized replacement
# for jubilant-memory/config/rotate-local-creds.sh, which only ever rotated
# eventstracker + RabbitMQ. This one covers every project the local compose
# file manages: eventstracker, runs-app, runs-ai-analyzer, mytracker, rabbitmq.
#
# Usage: ./rotate-creds.sh [project...] [--apply-runtime]
#   project           One or more of: eventstracker runs-app runs-ai-analyzer
#                     mytracker rabbitmq. Omit to rotate all of them.
#   --apply-runtime   Also update the running local container's role/user
#                     password in place (ALTER ROLE / rabbitmqctl change_password).
#                     Without this flag, only env/.env.local is updated — the
#                     running container keeps its old password until you
#                     restart via dev-up.sh (which syncs the role on every run).
#
# IMPORTANT: this only rotates the LOCAL profile. VM/ACG/prod are separate
# credential domains and are never touched automatically — this script prints
# exactly what to run to re-sync each one after rotating.
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

ENV_FILE="$(get_local_env_file)"
EXAMPLE_FILE="$(dirname "$ENV_FILE")/.env.local.example"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1"; }
print_info()   { echo -e "${YELLOW}ℹ${NC} $1"; }

ROTATABLE=(eventstracker runs-app runs-ai-analyzer mytracker rabbitmq)

APPLY_RUNTIME=false
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --apply-runtime) APPLY_RUNTIME=true ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      if [[ " ${ROTATABLE[*]} " != *" $arg "* ]]; then
        print_error "Unknown project '$arg' — must be one of: ${ROTATABLE[*]}"
        exit 1
      fi
      TARGETS+=("$arg")
      ;;
  esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${ROTATABLE[@]}")

if [ ! -f "$ENV_FILE" ]; then
  if [ ! -f "$EXAMPLE_FILE" ]; then
    print_error "Missing $ENV_FILE and $EXAMPLE_FILE"
    exit 1
  fi
  cp "$EXAMPLE_FILE" "$ENV_FILE"
fi

backup="$ENV_FILE.backup.$(date +%Y%m%d-%H%M%S)"
cp "$ENV_FILE" "$backup"

get_val() { grep -E "^${1}=" "$ENV_FILE" | tail -n 1 | cut -d'=' -f2-; }

set_kv() {
  local key="$1" value="$2" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { found = 0 }
    $0 ~ ("^" k "=") { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '=+/\n' | cut -c1-32
  else
    python3 - << 'PY'
import secrets, string
alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(32)))
PY
  fi
}

rotated_projects=()

for target in "${TARGETS[@]}"; do
  if [ "$target" = "rabbitmq" ]; then
    new_pass="$(gen_secret)"
    set_kv "RABBITMQ_PASSWORD" "$new_pass"
    print_status "Rotated RABBITMQ_PASSWORD"

    if $APPLY_RUNTIME; then
      rabbit_user="$(get_val RABBITMQ_USERNAME)"
      rabbit_container="$(get_rabbitmq_container)"
      if docker ps --format '{{.Names}}' | grep -qx "$rabbit_container"; then
        if docker exec "$rabbit_container" rabbitmqctl list_users 2>/dev/null | awk '{print $1}' | grep -qx "$rabbit_user"; then
          docker exec "$rabbit_container" rabbitmqctl change_password "$rabbit_user" "$new_pass" >/dev/null 2>&1 \
            && print_status "Applied to running $rabbit_container" \
            || print_error "Failed to apply to running $rabbit_container"
        else
          print_info "$rabbit_container running but user '$rabbit_user' not found — skipped runtime apply"
        fi
      else
        print_info "$rabbit_container not running — skipped runtime apply"
      fi
    fi
    rotated_projects+=("rabbitmq")
    continue
  fi

  user_key="$(get_project_db_user_key "$target")"
  pass_key="$(get_project_password_env_var "$target")"
  db_user="$(get_val "$user_key")"
  if [ -z "$db_user" ]; then
    print_error "$user_key not set in $ENV_FILE — skipping $target"
    continue
  fi

  new_pass="$(gen_secret)"
  set_kv "$pass_key" "$new_pass"
  print_status "Rotated $pass_key ($target, user '$db_user')"

  if $APPLY_RUNTIME; then
    container="$(get_project_container "$target")"
    if docker ps --format '{{.Names}}' | grep -qx "$container"; then
      if docker exec "$container" psql -U "$db_user" -d postgres -c \
          "ALTER ROLE \"$db_user\" WITH PASSWORD '$new_pass';" >/dev/null 2>&1; then
        print_status "Applied to running $container"
      else
        print_error "Failed to apply to running $container (role may differ — check with dev-up.sh)"
      fi
    else
      print_info "$container not running — skipped runtime apply"
    fi
  fi
  rotated_projects+=("$target")
done

chmod 600 "$ENV_FILE"

echo ""
echo "Rotated: ${rotated_projects[*]}"
echo "Backup:  $backup"
if ! $APPLY_RUNTIME; then
  echo "Tip: rerun with --apply-runtime to update running local container(s) in-place"
  echo "     (or just re-run each project's ./dev-up.sh — it syncs the role every time)"
fi

echo ""
echo "If any of these are deployed to VM/ACG/prod, they are now stale there. Re-sync:"
for p in "${rotated_projects[@]}"; do
  if [ "$p" = "rabbitmq" ]; then
    echo "  rabbitmq: update RABBITMQ_DEFAULT_USER/PASS in env/.env.vm manually, then re-deploy any project via vm-db-up.sh"
  else
    echo "  $p: consolidated-postgres/scripts/vm/vm-db-up.sh $p"
  fi
done
