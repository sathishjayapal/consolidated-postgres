#!/usr/bin/env bash
set -euo pipefail

#################################################################
# VM Database Orchestration (VirtualBox + Portainer)
#
# Brings up persisted PostgreSQL databases on the VirtualBox VM for
# the projects you pass as parameters, by regenerating the managed
# block in compose/docker-compose-vm.yml and redeploying the
# Portainer stack via its REST API.
#
# Usage:
#   ./vm-db-up.sh [options] <project> [project...]
#
#   Projects: any of the names in projects.txt
#             (eventstracker is ALWAYS included in the VM stack because
#              the eventstracker app container there depends on its DB)
#
# Options:
#   --target vm|local   Which DB host to write into each selected
#                       project's .env JDBC URL (default: vm).
#                       "local" points .env back at localhost for
#                       normal local dev — compose is still updated.
#   --no-env            Don't touch any project .env files
#   --dry-run           Regenerate compose files only; skip Portainer push
#   --prune             Remove VM stack services no longer in the compose
#                       (named volumes are preserved — data is safe)
#   --pull              Force Portainer to re-pull images on redeploy
#                       (pullImage:true). Default is false — new/missing
#                       images are still pulled; existing ones are only
#                       refreshed by Watchtower unless you pass --pull.
#   --help              Show this help
#
# Requires: env/vm.env in the repo root (cp env/vm.env.example env/vm.env), jq, curl,
#           python3. Each selected project's .env must exist locally
#           (run its dev-up.sh once) so DB users/passwords can be pushed
#           to the Portainer stack environment.
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

PROJECT_ROOT="$WORKSPACE_ROOT"
source "$REPO_ROOT/scripts/lib/project-config.sh"

STACK_FILE="$REPO_ROOT/compose/docker-compose-vm.yml"
VM_ENV_FILE="$REPO_ROOT/env/vm.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1" >&2; }
print_info()   { echo -e "${YELLOW}ℹ${NC} $1"; }
die()          { print_error "$1"; exit 1; }

# ── Parse arguments ──────────────────────────────────────────────────────────
TARGET="vm"
UPDATE_ENV=true
DRY_RUN=false
PRUNE=false
PULL=false
SELECTED=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --target)  TARGET="${2:?--target needs vm|local}"; shift 2 ;;
    --no-env)  UPDATE_ENV=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --prune)   PRUNE=true; shift ;;
    --pull)    PULL=true; shift ;;
    --help)    sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       die "Unknown option: $1" ;;
    *)         SELECTED+=("$1"); shift ;;
  esac
done

[[ "$TARGET" == "vm" || "$TARGET" == "local" ]] || die "--target must be vm or local"
[ ${#SELECTED[@]} -gt 0 ] || die "No projects given. Usage: ./vm-db-up.sh [options] <project...>  (see --help)"

for p in "${SELECTED[@]}"; do
  found=false
  for known in "${PROJECTS[@]}"; do [ "$p" = "$known" ] && found=true; done
  $found || die "Unknown project '$p'. Valid projects (projects.txt): ${PROJECTS[*]}"
done

command -v jq >/dev/null      || die "jq not found (brew install jq)"
command -v curl >/dev/null    || die "curl not found"
command -v python3 >/dev/null || die "python3 not found"
[ -f "$STACK_FILE" ]          || die "VM stack compose not found: $STACK_FILE"

# ── VM settings ──────────────────────────────────────────────────────────────
if [ -f "$VM_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  source "$VM_ENV_FILE"
else
  $DRY_RUN || die "env/vm.env not found. Run: cp env/vm.env.example env/vm.env and fill it in"
  print_info "env/vm.env not found — OK for --dry-run, .env updates will use placeholder VM_IP"
  VM_IP="${VM_IP:-VM_IP_NOT_SET}"
fi

# ── Build the generation set: selected projects + eventstracker (always) ─────
GEN_SET=("eventstracker")
for p in "${SELECTED[@]}"; do
  [ "$p" = "eventstracker" ] || GEN_SET+=("$p")
done

echo ""
print_info "Selected projects:  ${SELECTED[*]}"
print_info "VM stack will hold: ${GEN_SET[*]} (eventstracker DB is always present — the eventstracker app in the stack depends on it)"
echo ""

# ── Collect metadata & regenerate the managed compose block ─────────────────
META="[]"
for p in "${GEN_SET[@]}"; do
  db_user=$(get_project_db_user "$p") || die "Cannot resolve DB user for $p — does $(get_project_env_file "$p") exist? (run its dev-up.sh once)"
  db_pass=$(get_project_password "$p") || die "Cannot resolve DB password for $p — check $(get_project_env_file "$p")"
  META=$(jq \
    --arg project "$p" \
    --arg service "$(get_project_db_service "$p")" \
    --arg image "$(get_project_db_image "$p")" \
    --arg port "$(get_project_port "$p")" \
    --arg db_name "$(get_project_db_name "$p")" \
    --arg name_key "$(get_project_db_name_key "$p")" \
    --arg user_key "$(get_project_db_user_key "$p")" \
    --arg pass_key "$(get_project_password_env_var "$p")" \
    --arg volume "$(get_project_vm_volume "$p")" \
    --arg mount "$(get_project_pg_mount "$p")" \
    --arg db_user "$db_user" \
    --arg db_pass "$db_pass" \
    '. + [{project:$project, service:$service, image:$image, port:$port,
           db_name:$db_name, name_key:$name_key, user_key:$user_key,
           pass_key:$pass_key, volume:$volume, mount:$mount,
           db_user:$db_user, db_pass:$db_pass}]' <<<"$META")
done

jq 'map(del(.db_user, .db_pass))' <<<"$META" | \
  python3 "$SCRIPT_DIR/generate_vm_stack.py" --compose "$STACK_FILE"
print_status "VM stack compose regenerated: $STACK_FILE"

# ── Sync each selected project's own docker-compose host port ───────────────
sync_project_compose() {
  local project="$1" compose port
  port=$(get_project_port "$project")
  case "$project" in
    # These four share consolidated-postgres/compose/docker-compose-local.yml, which
    # hardcodes the correct port for each service by construction — there's nothing to
    # drift/sync, and the single-match regex below would be wrong for a multi-service
    # shared file anyway (it'd only ever touch the first "NNNN:5432" it finds).
    eventstracker|runs-app|runs-ai-analyzer|mytracker)
      print_info "$project uses the shared local compose file — port already fixed, skipped"
      return 0
      ;;
    *)                compose="$(resolve_project_dir "$project")/docker-compose.yml" ;;
  esac
  [ -f "$compose" ] || { print_info "No compose for $project at $compose — skipped"; return 0; }
  python3 - "$compose" "$port" <<'PYEOF'
import re, sys
path, port = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
# Normalize any "XXXX:5432" host-port mapping lines to the configured port —
# only within the first postgres service block would be ideal, but per-project
# compose files map exactly one DB to 5432 per service; we replace conservatively:
new = re.sub(r'(["\']?)\d{4,5}:5432(["\']?)', lambda m: f'{m.group(1)}{port}:5432{m.group(2)}', text, count=1)
if new != text:
    open(path, "w", encoding="utf-8").write(new)
    print(f"synced port {port} -> {path}")
else:
    print(f"already in sync: {path}")
PYEOF
}

for p in "${SELECTED[@]}"; do
  sync_project_compose "$p"
done
print_status "Per-project compose files checked/synced"

# ── Update project .env JDBC URLs (mixed host/VM support) ───────────────────
if $UPDATE_ENV; then
  if [ "$TARGET" = "vm" ]; then DB_HOST="$VM_IP"; else DB_HOST="localhost"; fi
  for p in "${SELECTED[@]}"; do
    env_file=$(get_project_env_file "$p")
    [ -f "$env_file" ] || { print_info "No .env for $p — skipped"; continue; }
    url_key=$(get_project_db_url_key "$p")
    port=$(get_project_port "$p")
    db_name=$(get_project_db_name "$p")
    new_url="jdbc:postgresql://${DB_HOST}:${port}/${db_name}"
    cp "$env_file" "$env_file.bak"
    if grep -qE "^${url_key}=" "$env_file"; then
      tmpfile=$(mktemp)
      sed "s|^${url_key}=.*|${url_key}=${new_url}|" "$env_file" > "$tmpfile" && mv "$tmpfile" "$env_file"
    else
      echo "${url_key}=${new_url}" >> "$env_file"
    fi
    print_status "$p .env → ${url_key}=${new_url}  (backup: $(basename "$env_file").bak)"
  done
else
  print_info "Skipping .env updates (--no-env)"
fi

# ── Push to Portainer ────────────────────────────────────────────────────────
if $DRY_RUN; then
  print_info "--dry-run: not pushing to Portainer. Review $STACK_FILE and rerun without --dry-run."
  exit 0
fi

: "${PORTAINER_URL:?set in env/vm.env}"
: "${PORTAINER_API_KEY:?set in env/vm.env}"
: "${PORTAINER_ENDPOINT_ID:?set in env/vm.env}"
: "${PORTAINER_STACK_NAME:?set in env/vm.env}"

auth=(-H "X-API-Key: ${PORTAINER_API_KEY}")

# curl wrapper that captures the HTTP status and body so Portainer's real error
# message is shown instead of a bare "curl: (22)".
# Usage: portainer_call <method> <url> [json-body]; sets REPLY_CODE / REPLY_BODY
portainer_call() {
  local method="$1" url="$2" body="${3:-}" resp
  if [ -n "$body" ]; then
    resp=$(curl -sS "${auth[@]}" -X "$method" -H "Content-Type: application/json" \
      --data "$body" -w $'\n%{http_code}' "$url") || die "Cannot reach $url"
  else
    resp=$(curl -sS "${auth[@]}" -X "$method" -w $'\n%{http_code}' "$url") || die "Cannot reach $url"
  fi
  REPLY_CODE="${resp##*$'\n'}"
  REPLY_BODY="${resp%$'\n'*}"
}

# Validate the endpoint ID early — a wrong one makes several APIs return 404
portainer_call GET "$PORTAINER_URL/api/endpoints"
[ "$REPLY_CODE" = "200" ] || die "Cannot list Portainer endpoints (HTTP $REPLY_CODE): $REPLY_BODY"
if ! jq -e --argjson id "$PORTAINER_ENDPOINT_ID" '.[] | select(.Id==$id)' <<<"$REPLY_BODY" >/dev/null; then
  die "Endpoint ID $PORTAINER_ENDPOINT_ID not found in Portainer. Available endpoints: $(jq -r 'map("\(.Id)=\(.Name)") | join(", ")' <<<"$REPLY_BODY"). Fix PORTAINER_ENDPOINT_ID in env/vm.env"
fi

print_info "Looking up stack '$PORTAINER_STACK_NAME' at $PORTAINER_URL ..."
stacks_json=$(curl -fsS "${auth[@]}" "$PORTAINER_URL/api/stacks") \
  || die "Cannot reach Portainer API at $PORTAINER_URL — is the VM up and the API key valid?"
stack_id=$(jq -r --arg n "$PORTAINER_STACK_NAME" '.[] | select(.Name==$n) | .Id' <<<"$stacks_json")

# Convert a KEY=VALUE .env file to a Portainer env JSON array
env_file_to_json() {
  local f="$1"
  [ -f "$f" ] || { echo '[]'; return; }
  jq -Rn '[inputs
    | select(test("^\\s*#") | not)
    | select(test("^[A-Za-z_][A-Za-z0-9_]*="))
    | capture("^(?<name>[^=]+)=(?<value>.*)$")
    | {name: .name, value: .value}]' < "$f"
}

# Merge two env arrays — entries in $2 win over $1
merge_env() {
  jq -n --argjson a "$1" --argjson b "$2" \
    '($b | map(.name)) as $names
     | ($a | map(select(.name as $n | $names | index($n) | not))) + $b'
}

# Validate that the base stack env file contains the shared keys the compose
# file cannot start without. DB credentials are added separately from project .env.
validate_base_stack_env() {
  local env_json="$1"
  local missing=() key
  local required=(
    GIT_URI ENCRYPT_KEY
    CONFIG_SERVER_USERNAME CONFIG_SERVER_PASSWORD
    RABBITMQ_DEFAULT_USER RABBITMQ_DEFAULT_PASS
    DOCKERHUB_TOKEN
    EVENT_DOMAIN_USER EVENT_DOMAIN_USER_PASSWORD
  )
  for key in "${required[@]}"; do
    if ! jq -e --arg k "$key" 'map(.name) | index($k) != null' <<<"$env_json" >/dev/null; then
      missing+=("$key")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    print_error "Missing required base env vars in $STACK_ENV_FILE: ${missing[*]}"
    print_info  "Copy env/.env.vm.example to env/.env.vm and fill in real values."
    exit 1
  fi
}

# Base stack env (GIT_URI, CONFIG_SERVER_*, RABBITMQ_*, ...) from env/.env.vm
STACK_ENV_FILE="$REPO_ROOT/env/.env.vm"
base_env=$(env_file_to_json "$STACK_ENV_FILE")
validate_base_stack_env "$base_env"
if [ "$(jq 'length' <<<"$base_env")" -gt 0 ]; then
  print_info "Pushing $(jq 'length' <<<"$base_env") base env var(s) from env/.env.vm"
else
  print_info "No env/.env.vm found — only DB env vars will be pushed (config-server/rabbitmq need GIT_URI etc. to become healthy!)"
fi

# Env entries this script owns (values read from each project's local .env)
our_env=$(jq 'map(
    {name: .name_key,  value: .db_name},
    {name: .user_key,  value: .db_user},
    {name: .pass_key,  value: .db_pass}
  )' <<<"$META")

content=$(jq -Rs . < "$STACK_FILE")

if [ -n "$stack_id" ]; then
  # Merge: keep existing stack env (GIT_URI, RABBITMQ_*, ...) — ours win on conflict
  existing_env=$(curl -fsS "${auth[@]}" "$PORTAINER_URL/api/stacks/$stack_id" | jq '.Env // []')
  # precedence: env/.env.vm < existing stack env (Portainer UI edits) < DB vars
  merged_env=$(merge_env "$base_env" "$existing_env")
  merged_env=$(merge_env "$merged_env" "$our_env")
  body=$(jq -n \
    --argjson content "$content" \
    --argjson env "$merged_env" \
    --argjson prune "$PRUNE" \
    --argjson pull "$PULL" \
    '{stackFileContent: $content, env: $env, prune: $prune, pullImage: $pull}')
  print_info "Updating stack #$stack_id (prune=$PRUNE, pull=$PULL) ..."
  portainer_call PUT "$PORTAINER_URL/api/stacks/$stack_id?endpointId=$PORTAINER_ENDPOINT_ID" "$body"
  [[ "$REPLY_CODE" == 2* ]] \
    || die "Stack update failed (HTTP $REPLY_CODE): $REPLY_BODY"
  print_status "Stack '$PORTAINER_STACK_NAME' redeployed"
else
  print_info "Stack not found — creating '$PORTAINER_STACK_NAME' ..."
  create_env=$(merge_env "$base_env" "$our_env")
  body=$(jq -n \
    --arg name "$PORTAINER_STACK_NAME" \
    --argjson content "$content" \
    --argjson env "$create_env" \
    '{name: $name, stackFileContent: $content, env: $env}')
  # Portainer >= 2.19
  portainer_call POST "$PORTAINER_URL/api/stacks/create/standalone/string?endpointId=$PORTAINER_ENDPOINT_ID" "$body"
  if [ "$REPLY_CODE" = "404" ]; then
    # Portainer < 2.19 uses the legacy create route
    print_info "Modern create endpoint returned 404 — retrying with legacy API (Portainer < 2.19) ..."
    portainer_call POST "$PORTAINER_URL/api/stacks?type=2&method=string&endpointId=$PORTAINER_ENDPOINT_ID" "$body"
  fi
  [[ "$REPLY_CODE" == 2* ]] \
    || die "Stack creation failed (HTTP $REPLY_CODE): $REPLY_BODY
NOTE: the base stack needs GIT_URI/RABBITMQ_*/CONFIG_SERVER_* env vars — after creation, add them in Portainer → Stacks → $PORTAINER_STACK_NAME → Environment variables (see docs/PORTAINER-SETUP.md)."
  print_status "Stack '$PORTAINER_STACK_NAME' created (remember to add GIT_URI, RABBITMQ_*, CONFIG_SERVER_* env vars in Portainer)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Databases on VM ($VM_IP) — data persisted in named volumes"
echo "═══════════════════════════════════════════════════════════"
printf "  %-18s %-10s %-22s %s\n" "PROJECT" "PORT" "DATABASE" "VOLUME"
jq -r '.[] | [.project, .port, .db_name, .volume] | @tsv' <<<"$META" | \
  while IFS=$'\t' read -r proj port db vol; do
    printf "  %-18s %-10s %-22s %s\n" "$proj" "$port" "$db" "$vol"
  done
echo ""
echo "  Connect from your Mac:  psql -h $VM_IP -p <PORT> -U <user> -d <DATABASE>"
echo "  Portainer:              $PORTAINER_URL"
if $UPDATE_ENV; then
  echo "  Project .env files now point at: $([ "$TARGET" = "vm" ] && echo "$VM_IP (VM)" || echo "localhost")"
fi
echo ""
