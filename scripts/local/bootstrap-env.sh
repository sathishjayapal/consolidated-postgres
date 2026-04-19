#!/usr/bin/env bash
set -euo pipefail

# Creates/updates machine-local env files for local multi-project development.
# Safe for public repos: writes secrets only to ignored .env files.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

# Resolve a project directory: prefer ~/IdeaProjects/<name>, fall back to WORKSPACE_ROOT/<name>
resolve_project_dir() {
  local name="$1"
  if [ -d "$HOME/IdeaProjects/$name" ]; then
    echo "$HOME/IdeaProjects/$name"
  else
    echo "$WORKSPACE_ROOT/$name"
  fi
}

INFRA_DIR="$(resolve_project_dir jubilant-memory)/config"
INFRA_ENV="$INFRA_DIR/.env"
INFRA_EXAMPLE="$INFRA_DIR/.env.example"

EVENTSTRACKER_DIR="$(resolve_project_dir eventstracker)"
EVENTSTRACKER_ENV="$EVENTSTRACKER_DIR/.env"

CONFIG_SERVER_DIR="$(resolve_project_dir sathishproject-config-server)"
CONFIG_SERVER_ENV="$CONFIG_SERVER_DIR/.env"

print_info() { echo "[bootstrap-env] $1"; }
print_error() { echo "[bootstrap-env] ERROR: $1"; }

rand_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 36 | tr -d '=+/\n' | cut -c1-32
  else
    python3 - <<'PY'
import secrets, string
chars = string.ascii_letters + string.digits
print(''.join(secrets.choice(chars) for _ in range(32)))
PY
  fi
}

ensure_env_file() {
  local target="$1"
  local example="$2"
  if [ ! -f "$target" ]; then
    if [ ! -f "$example" ]; then
      print_error "Missing template: $example"
      exit 1
    fi
    cp "$example" "$target"
    print_info "Created $target from template"
  fi
}

get_val() {
  local file="$1" key="$2"
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2- || true
}

set_kv() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { found = 0 }
    $0 ~ ("^" k "=") { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

set_if_blank_or_placeholder() {
  local file="$1" key="$2" default="$3"
  local cur
  cur="$(get_val "$file" "$key")"
  if [ -z "$cur" ] || [[ "$cur" == change_me_* ]]; then
    set_kv "$file" "$key" "$default"
  fi
}

# 1) Infra env (single golden source)
ensure_env_file "$INFRA_ENV" "$INFRA_EXAMPLE"

set_if_blank_or_placeholder "$INFRA_ENV" "EVENTS_TRACKER_DB_NAME" "event-service"
set_if_blank_or_placeholder "$INFRA_ENV" "EVENTS_TRACKER_DB_USER" "eventsvc_local"
set_if_blank_or_placeholder "$INFRA_ENV" "EVENTS_TRACKER_DB_PASSWORD" "$(rand_secret)"

set_if_blank_or_placeholder "$INFRA_ENV" "RABBITMQ_USERNAME" "rabbit_local"
set_if_blank_or_placeholder "$INFRA_ENV" "RABBITMQ_PASSWORD" "$(rand_secret)"

set_if_blank_or_placeholder "$INFRA_ENV" "RUNS_APP_DB_NAME" "runs-app"
set_if_blank_or_placeholder "$INFRA_ENV" "MYTRACKER_DB_NAME" "postgres"
set_if_blank_or_placeholder "$INFRA_ENV" "SHEDLOCK_DB_NAME" "postgres"

# Config server credentials and backing config repo
set_if_blank_or_placeholder "$INFRA_ENV" "GIT_URI" "https://github.com/sathishjayapal/jubilant-memory"
set_if_blank_or_placeholder "$INFRA_ENV" "encrypt_key" "$(rand_secret)"
set_if_blank_or_placeholder "$INFRA_ENV" "username" "cfg_local"
set_if_blank_or_placeholder "$INFRA_ENV" "pass" "$(rand_secret)"
set_if_blank_or_placeholder "$INFRA_ENV" "APP_PORT" "8888"

# EventTracker app-level secrets consumed from config repo placeholders
set_if_blank_or_placeholder "$INFRA_ENV" "EVENT_DOMAIN_USER" "eventdomain_local"
set_if_blank_or_placeholder "$INFRA_ENV" "EVENT_DOMAIN_USER_PASSWORD" "$(rand_secret)"

chmod 600 "$INFRA_ENV"

# Load infra env values for propagation
# shellcheck source=/dev/null
set -a
source "$INFRA_ENV"
set +a

# 2) EventTracker app env
if [ -d "$EVENTSTRACKER_DIR" ]; then
  ensure_env_file "$EVENTSTRACKER_ENV" "$EVENTSTRACKER_DIR/.env.template"
  set_kv "$EVENTSTRACKER_ENV" "EVENTS_TRACKER_DB_URL" "jdbc:postgresql://localhost:6433/${EVENTS_TRACKER_DB_NAME}"
  set_kv "$EVENTSTRACKER_ENV" "EVENTS_TRACKER_DB_USER" "$EVENTS_TRACKER_DB_USER"
  set_kv "$EVENTSTRACKER_ENV" "EVENTS_TRACKER_DB_PASSWORD" "$EVENTS_TRACKER_DB_PASSWORD"
  set_kv "$EVENTSTRACKER_ENV" "RABBITMQ_HOST" "localhost"
  set_kv "$EVENTSTRACKER_ENV" "RABBITMQ_PORT" "5672"
  set_kv "$EVENTSTRACKER_ENV" "RABBITMQ_USERNAME" "$RABBITMQ_USERNAME"
  set_kv "$EVENTSTRACKER_ENV" "RABBITMQ_PASSWORD" "$RABBITMQ_PASSWORD"
  set_kv "$EVENTSTRACKER_ENV" "EVENT_DOMAIN_USER" "$EVENT_DOMAIN_USER"
  set_kv "$EVENTSTRACKER_ENV" "EVENT_DOMAIN_USER_PASSWORD" "$EVENT_DOMAIN_USER_PASSWORD"
  set_kv "$EVENTSTRACKER_ENV" "SPRING_CLOUD_CONFIG_USERNAME" "$username"
  set_kv "$EVENTSTRACKER_ENV" "SPRING_CLOUD_CONFIG_PASSWORD" "$pass"
  chmod 600 "$EVENTSTRACKER_ENV"
  print_info "Synchronized $EVENTSTRACKER_ENV"
fi

# 3) Config server env (replace mode: only keys required by docker-compose)
if [ -d "$CONFIG_SERVER_DIR" ]; then
  if [ -f "$CONFIG_SERVER_ENV" ]; then
    _backup="$CONFIG_SERVER_ENV.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_SERVER_ENV" "$_backup"
    chmod 600 "$_backup" || true
    print_info "Backed up existing config-server env to $_backup"
  fi

  cat > "$CONFIG_SERVER_ENV" <<EOF
GIT_URI=$GIT_URI
encrypt_key=$encrypt_key
username=$username
pass=$pass
APP_PORT=$APP_PORT
EOF
  chmod 600 "$CONFIG_SERVER_ENV"
  print_info "Synchronized $CONFIG_SERVER_ENV"
fi

print_info "Environment bootstrap complete"
print_info "Golden source: $INFRA_ENV"

