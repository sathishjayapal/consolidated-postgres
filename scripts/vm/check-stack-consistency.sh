#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Stack consistency checker — catches two recurring failure classes
# BEFORE they reach a running container:
#
#   1. Config/deploy name drift: a config-server YAML (jubilant-memory)
#      references ${SOME_VAR}, but the place that's supposed to set it
#      (the VM's virtualbox-stack/docker-compose.yml service block, or
#      the project's own local .env when not yet deployed on the VM)
#      never defines a literal key with that exact name. This is the
#      bug that broke eventstracker (EVENT_DOMAIN_USER casing,
#      EVENTS_TRACKER_DB_URL vs SPRING_DATASOURCE_URL) and
#      my-github-cleaner (JDBC_DATABASE_URL vs GITHUB_CLEANER_DB_URL)
#      on 2026-07-12 — in every case the app crashed or silently used
#      an unresolved placeholder, and nothing caught it until runtime.
#
#   2. Postgres role drift: POSTGRES_USER/PASSWORD only apply the FIRST
#      time a container initializes an empty volume. If the env var
#      value changes afterward, the running Postgres never finds out —
#      it silently keeps the old role, and every future connection with
#      the "new" credentials fails with "role does not exist" or
#      "password authentication failed", no matter how consistent your
#      env vars look on paper.
#
# Usage:
#   ./check-stack-consistency.sh            # both checks
#   ./check-stack-consistency.sh --config   # only the config/deploy check (no VM access needed)
#   ./check-stack-consistency.sh --roles    # only the Postgres role-drift check (needs vm.env)
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
STACK_FILE="$WORKSPACE_ROOT/virtualbox-stack/docker-compose.yml"

PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
FAIL=0

RUN_CONFIG=true
RUN_ROLES=true
case "${1:-}" in
  --config) RUN_ROLES=false ;;
  --roles)  RUN_CONFIG=false ;;
esac

# macOS ships bash 3.2 (no associative arrays), same constraint project-config.sh
# works around — so these are plain functions with a case, not `declare -A`.

# project -> config-server YAML file(s) that back its datasource/rabbitmq config
# (paths relative to jubilant-memory/). Add a case here whenever a project
# starts reading its DB/broker config from the config server.
config_ymls_for() {
  case "$1" in
    eventstracker)    echo "eventstracker/eventstracker-local.yml eventstracker/eventstracker-prod.yml" ;;
    dbcleaner)        echo "dbcleaner/dbcleaner-docker.yml" ;;
    verbose-barnacle) echo "my-github-cleaner/my-github-cleaner-local.yml" ;;
    *)                echo "" ;;
  esac
}

# project -> service name in virtualbox-stack/docker-compose.yml.
# Empty = not deployed as a VM app container yet — the check then falls back
# to the project's own local .env instead.
compose_service_for() {
  case "$1" in
    eventstracker)    echo "eventstracker" ;;
    dbcleaner)        echo "dbcleaner" ;;
    verbose-barnacle) echo "" ;;
    *)                echo "" ;;
  esac
}

# Projects this checker knows about (only ones with a CONFIG_YMLS entry).
CHECKED_PROJECTS="eventstracker dbcleaner verbose-barnacle"

extract_placeholders() {
  # Only bare ${VAR} (no colon) — these are hard requirements in Spring YAML
  # (no fallback, so a missing value is either a crash or an unresolved
  # literal string). ${VAR:default} already has a fallback and isn't worth
  # flagging — that's what kept PORT/LOG_LEVEL_PATTERN/etc. out of this check.
  grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$@" 2>/dev/null \
    | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/\1/' | sort -u
}

extract_compose_env_keys() {
  # Literal environment: keys set for one service block in $STACK_FILE
  local service="$1"
  awk -v svc="  ${service}:" '
    $0 == svc { found=1; next }
    found && /^  [A-Za-z]/ { exit }
    found && /^    environment:/ { inenv=1; next }
    found && inenv && /^    [A-Za-z]/ { inenv=0 }
    found && inenv && /^      [A-Za-z_][A-Za-z0-9_]*:/ { print }
  ' "$STACK_FILE" | sed -E 's/^[[:space:]]+([A-Za-z_][A-Za-z0-9_]*):.*/\1/' | sort -u
}

if $RUN_CONFIG; then
  echo "=== Config <-> deployment name consistency ==="
  for project in $CHECKED_PROJECTS; do
    ymls=()
    for f in $(config_ymls_for "$project"); do
      full="$WORKSPACE_ROOT/jubilant-memory/$f"
      [ -f "$full" ] && ymls+=("$full")
    done
    if [ ${#ymls[@]} -eq 0 ]; then
      echo -e "${YELLOW}skip${NC} $project — no config-server YAML found"
      continue
    fi

    referenced=$(extract_placeholders "${ymls[@]}")
    service="$(compose_service_for "$project")"

    if [ -n "$service" ]; then
      defined=$(extract_compose_env_keys "$service")
      source_desc="virtualbox-stack/docker-compose.yml service '$service'"
    else
      env_file="$WORKSPACE_ROOT/$project/.env"
      if [ ! -f "$env_file" ]; then
        echo -e "${YELLOW}skip${NC} $project — not deployed on the VM and no local .env at $env_file"
        continue
      fi
      defined=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" | sed 's/=$//' | sort -u)
      source_desc="$project/.env"
    fi

    missing=()
    while IFS= read -r var; do
      [ -z "$var" ] && continue
      grep -qx "$var" <<<"$defined" || missing+=("$var")
    done <<<"$referenced"

    if [ ${#missing[@]} -gt 0 ]; then
      echo -e "${RED}FAIL${NC} $project: referenced via \${...} in config but never set in $source_desc:"
      printf '       %s\n' "${missing[@]}"
      FAIL=1
    else
      echo -e "${GREEN}OK${NC}   $project  (checked against $source_desc)"
    fi
  done
  echo ""
fi

if $RUN_ROLES; then
  echo "=== Postgres role drift (VM) ==="
  VM_ENV_FILE="$REPO_ROOT/vm.env"
  if [ ! -f "$VM_ENV_FILE" ]; then
    echo -e "${YELLOW}skip${NC} vm.env not found — cannot reach Portainer to check live roles"
  else
    # shellcheck disable=SC1090
    source "$VM_ENV_FILE"
    : "${PORTAINER_URL:?set in vm.env}"; : "${PORTAINER_API_KEY:?set in vm.env}"; : "${PORTAINER_ENDPOINT_ID:?set in vm.env}"
    : "${PORTAINER_STACK_NAME:?set in vm.env}"
    auth=(-H "X-API-Key: ${PORTAINER_API_KEY}")

    stacks_json=$(curl -fsS "${auth[@]}" "${PORTAINER_URL}/api/stacks") \
      || { echo -e "${RED}FAIL${NC} cannot reach Portainer API"; exit 1; }
    stack_id=$(jq -r --arg n "$PORTAINER_STACK_NAME" '.[] | select(.Name==$n) | .Id' <<<"$stacks_json")
    # Expected usernames come from the LIVE Portainer stack env — that's what the
    # VM containers were actually deployed with — not each project's local .env
    # (which uses a different naming convention for some projects and is only
    # relevant to that project's own local docker-compose, a separate DB entirely).
    stack_env=$(curl -fsS "${auth[@]}" "${PORTAINER_URL}/api/stacks/${stack_id}" | jq -c '.Env')

    containers_json=$(curl -sS --max-time 8 "${auth[@]}" \
      "${PORTAINER_URL}/api/endpoints/${PORTAINER_ENDPOINT_ID}/docker/containers/json?all=true") \
      || { echo -e "${RED}FAIL${NC} cannot reach Portainer docker API"; FAIL=1; containers_json="[]"; }

    for project in "${PROJECTS[@]}"; do
      db_service=$(get_project_db_service "$project") || continue
      user_key=$(get_project_db_user_key "$project") || continue
      expected_user=$(jq -r --arg k "$user_key" '.[] | select(.name==$k) | .value' <<<"$stack_env")
      if [ -z "$expected_user" ]; then
        echo -e "${YELLOW}skip${NC} $project — $user_key not set in the Portainer stack env"
        continue
      fi

      cid=$(jq -r --arg s "-${db_service}-" '.[] | select(.Names[0] | test($s)) | .Id' <<<"$containers_json" | head -1)
      if [ -z "$cid" ] || [ "$cid" = "null" ]; then
        echo -e "${YELLOW}skip${NC} $project — DB service '$db_service' not running on the VM"
        continue
      fi

      # Connect AS the expected role via the container's local trust socket
      # (no password needed — this is root-equivalent docker exec access, same
      # trust boundary as the Portainer/Docker socket itself) against template1,
      # which always exists regardless of which database(s) were created. We
      # don't assume a "postgres" superuser exists — the official image only
      # creates one when POSTGRES_USER is left at its default, so guessing that
      # name is itself a source of false failures.
      exec_id=$(curl -sS --max-time 8 "${auth[@]}" -H "Content-Type: application/json" \
        -X POST "${PORTAINER_URL}/api/endpoints/${PORTAINER_ENDPOINT_ID}/docker/containers/${cid}/exec" \
        -d "$(jq -n --arg u "$expected_user" '{AttachStdout:true,AttachStderr:true,Cmd:["psql","-U",$u,"-d","template1","-tAc","select 1"]}')" \
        | jq -r '.Id')
      output=$(curl -sS --max-time 8 "${auth[@]}" -H "Content-Type: application/json" \
        -X POST "${PORTAINER_URL}/api/endpoints/${PORTAINER_ENDPOINT_ID}/docker/exec/${exec_id}/start" \
        -d '{"Detach":false,"Tty":false}' | grep -aoE '[[:print:]]+')

      if grep -q "role \"$expected_user\" does not exist" <<<"$output"; then
        echo -e "${RED}FAIL${NC} $project: expected role '$expected_user' (from Portainer stack env '$user_key') does NOT exist in the live $db_service —"
        echo "       the volume was likely initialized under different credentials. Fix with CREATE ROLE / ALTER DATABASE OWNER,"
        echo "       or wipe the volume (data loss) to let it re-init from current env vars."
        FAIL=1
      elif grep -q '^1$' <<<"$output"; then
        echo -e "${GREEN}OK${NC}   $project  (role '$expected_user' exists and can connect in $db_service)"
      else
        echo -e "${YELLOW}?${NC}    $project — unexpected psql output, check manually: $output"
      fi
    done
  fi
  echo ""
fi

if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All checks passed.${NC}"
else
  echo -e "${RED}One or more checks failed — see above.${NC}"
fi
exit "$FAIL"
