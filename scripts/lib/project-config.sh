#!/usr/bin/env bash

# Project metadata shared across orchestration/verification scripts.
# Expect PROJECT_ROOT to be defined by the caller before sourcing.

: "${PROJECT_ROOT:?PROJECT_ROOT must be set before sourcing project-config.sh}"

# Load projects from centralized projects.txt file
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECTS_FILE="$(cd "$_SCRIPT_DIR/../.." && pwd)/projects.txt"

if [ ! -f "$_PROJECTS_FILE" ]; then
  echo "ERROR: projects.txt not found at $_PROJECTS_FILE" >&2
  exit 1
fi

# Read projects from file, ignoring comments and empty lines
PROJECTS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip comments and empty lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line// }" ]] && continue
  # Trim whitespace and add to array
  line="${line#"${line%%[![:space:]]*}"}"  # trim leading
  line="${line%"${line##*[![:space:]]}"}"  # trim trailing
  PROJECTS+=("$line")
done < "$_PROJECTS_FILE"

if [ ${#PROJECTS[@]} -eq 0 ]; then
  echo "ERROR: No projects defined in $_PROJECTS_FILE" >&2
  exit 1
fi

# Resolve a project directory: prefer ~/IdeaProjects/<name>, fall back to PROJECT_ROOT/<name>
resolve_project_dir() {
  local name="$1"
  if [ -d "$HOME/IdeaProjects/$name" ]; then
    echo "$HOME/IdeaProjects/$name"
  else
    echo "$PROJECT_ROOT/$name"
  fi
}

# The "golden" local-dev credentials + compose file live in consolidated-postgres itself now
# (env/.env.local, compose/docker-compose-local.yml) — moved out of jubilant-memory/config,
# which is scoped to application config (Spring Cloud Config YAMLs) only from here on.
# get_infra_config_dir() returns the consolidated-postgres repo root (not a single directory
# holding both files, since env/ and compose/ are siblings) — use the two helpers below for
# the actual file paths.
get_infra_config_dir() {
  resolve_project_dir consolidated-postgres
}

get_local_env_file() {
  echo "$(get_infra_config_dir)/env/.env.local"
}

get_local_compose_file() {
  echo "$(get_infra_config_dir)/compose/docker-compose-local.yml"
}

get_config_server_dir() {
  resolve_project_dir sathishproject-config-server
}

get_config_server_env_file() {
  echo "$(get_config_server_dir)/.env"
}

get_config_server_container() {
  echo "sathish-config-server"
}

get_rabbitmq_container() {
  echo "sathishproject-rabbitmq"
}

get_project_db_user() {
  local project="$1"
  local project_dir
  project_dir=$(resolve_project_dir "$project")
  local env_file="$project_dir/.env"
  local key default_user
  key=$(get_project_db_user_env_key "$project") || return 1
  case "$project" in
    verbose-barnacle|dbcleaner) default_user="postgres" ;;  # project compose default
    *)                          default_user="" ;;
  esac
  # Try project .env first
  if [ -f "$env_file" ]; then
    local value
    value=$(grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d'=' -f2-)
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
    # runs-ai-analyzer: backward-compatible fallback to JDBC_DATABASE_USERNAME
    if [ "$project" = "runs-ai-analyzer" ]; then
      local jdbc_value
      jdbc_value=$(grep -E "^JDBC_DATABASE_USERNAME=" "$env_file" | tail -n 1 | cut -d'=' -f2-)
      if [ -n "$jdbc_value" ]; then
        echo "$jdbc_value"
        return 0
      fi
    fi
  fi
  # eventstracker: also try infra .env (golden source)
  if [ "$project" = "eventstracker" ]; then
    local infra_env
    infra_env="$(get_local_env_file)"
    if [ -f "$infra_env" ]; then
      local value
      value=$(grep -E "^${key}=" "$infra_env" | tail -n 1 | cut -d'=' -f2-)
      if [ -n "$value" ]; then
        echo "$value"
        return 0
      fi
    fi
  fi
  # Use default if defined, otherwise fail
  if [ -n "$default_user" ]; then
    echo "$default_user"
    return 0
  fi
  echo "ERROR: could not resolve DB user for $project (checked $env_file)" >&2
  return 1
}

get_project_db_name() {
  local project="$1"
  case "$project" in
    eventstracker)    echo "event-service" ;;   # jubilant-memory POSTGRES_DB default
    runs-app)         echo "runsapp_db" ;;
    runs-ai-analyzer)
      local project_dir env_file value
      project_dir=$(resolve_project_dir "$project")
      env_file="$project_dir/.env"
      if [ -f "$env_file" ]; then
        # Prefer explicit DB URL, then explicit DB name.
        value=$(grep -E "^RUNS_AI_ANALYZER_DB_URL=" "$env_file" | tail -n 1 | cut -d'=' -f2-)
        if [ -n "$value" ]; then
          value="${value##*/}"
          value="${value%%\?*}"
          if [ -n "$value" ]; then
            echo "$value"
            return 0
          fi
        fi
        value=$(grep -E "^RUNS_AI_ANALYZER_DB_NAME=" "$env_file" | tail -n 1 | cut -d'=' -f2-)
        if [ -n "$value" ]; then
          echo "$value"
          return 0
        fi
      fi
      echo "runs_ai_analyzer_db"
      ;;
    verbose-barnacle) echo "my-github-cleaner" ;;   # verbose-barnacle docker-compose default
    dbcleaner)        echo "dbcleaner" ;;
    sathish-projects-logger) echo "sathishlogger" ;;
    mytracker)        echo "postgres" ;;
    *)                return 1 ;;
  esac
}

get_project_port() {
  case "$1" in
    eventstracker)    echo "6433" ;;   # jubilant-memory docker-compose host port
    runs-app)         echo "5443" ;;
    runs-ai-analyzer) echo "5444" ;;
    verbose-barnacle) echo "5439" ;;
    dbcleaner)        echo "5433" ;;
    sathish-projects-logger) echo "8432" ;;
    mytracker)        echo "5440" ;;
    *)                return 1 ;;
  esac
}

get_project_container() {
  case "$1" in
    eventstracker)    echo "event-service-db" ;;   # jubilant-memory container_name
    runs-app)         echo "runs-app-postgres" ;;
    runs-ai-analyzer) echo "runs-ai-analyzer-db" ;;
    verbose-barnacle) echo "verbose-barnacle-postgres-1" ;;  # compose default naming
    dbcleaner)        echo "dbcleaner-postgres-1" ;;
    sathish-projects-logger) echo "sathishlogger-postgres" ;;  # project compose container_name
    mytracker)        echo "mytracker-db" ;;
    *)                return 1 ;;
  esac
}

get_project_password_env_var() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_PASSWORD" ;;
    runs-app)         echo "RUNS_APP_DB_PASSWORD" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_PASSWORD" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_PASSWORD" ;;
    dbcleaner)        echo "DBCLEANER_DB_PASSWORD" ;;
    sathish-projects-logger) echo "SATHISHLOGGER_DB_PASSWORD" ;;
    mytracker)        echo "MYTRACKER_DB_PASSWORD" ;;
    *)                return 1 ;;
  esac
}

get_project_env_password_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_PASSWORD" ;;
    runs-app)         echo "JDBC_DATABASE_PASSWORD" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_PASSWORD" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_PASSWORD" ;;
    dbcleaner)        echo "JDBC_DATABASE_PASSWORD" ;;
    sathish-projects-logger) echo "DATABASE_PASSWORD" ;;
    mytracker)        echo "MYTRACKER_DB_PASSWORD" ;;
    *)                return 1 ;;
  esac
}

# The DB username key as it actually appears in the project's OWN .env file
# (app-runtime convention — what that project's Spring config reads). This is
# a different domain from get_project_db_user_key()/get_project_password_env_var(),
# which are the key names pushed into the VM Portainer stack env; the two only
# happen to match for some projects. Any writer that populates a PROJECT's own
# .env (dev-up.sh --acg/--prod, local mode) must use this + get_project_db_url_key()
# + get_project_env_password_key() — the three domain-A keys — not the VM ones.
get_project_db_user_env_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_USER" ;;
    runs-app)         echo "JDBC_DATABASE_USERNAME" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_USER" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_USER" ;;
    dbcleaner)        echo "JDBC_DATABASE_USERNAME" ;;
    sathish-projects-logger) echo "DATABASE_USERNAME" ;;
    mytracker)        echo "MYTRACKER_DB_USER" ;;
    *)                return 1 ;;
  esac
}

# Fallback password when no .env / env var override exists — matches the
# hardcoded value in the project's own docker-compose.yml.
get_project_default_password() {
  case "$1" in
    verbose-barnacle|dbcleaner) echo "P4ssword!" ;;
    *)                          return 1 ;;
  esac
}

get_project_seed_table() {
  case "$1" in
    eventstracker)    echo "domain" ;;
    runs-app)         echo "run_app_user" ;;
    runs-ai-analyzer) echo "rag_cache" ;;
    *)                return 1 ;;
  esac
}

get_project_env_file() {
  local project="$1"
  local project_dir
  project_dir=$(resolve_project_dir "$project")
  echo "$project_dir/.env"
}

# ─────────────────────────────────────────────────────────────────────────────
# VM (VirtualBox / Portainer) stack metadata — used by scripts/vm/vm-db-up.sh
# ─────────────────────────────────────────────────────────────────────────────

# Postgres image on the VM — mirrors each project's own docker-compose.
get_project_db_image() {
  case "$1" in
    eventstracker)    echo "postgres:17.5" ;;
    runs-app)         echo "postgres:18.1" ;;
    runs-ai-analyzer) echo "pgvector/pgvector:pg17" ;;
    verbose-barnacle) echo "postgres:17.5" ;;
    dbcleaner)        echo "postgres:18.3" ;;
    sathish-projects-logger) echo "postgres:15-alpine" ;;  # matches project's own local compose
    mytracker)        echo "postgres:17" ;;
    *)                return 1 ;;
  esac
}

# Data directory to mount the named volume at (postgres:18+ moved it up a level).
get_project_pg_mount() {
  case "$1" in
    runs-app|dbcleaner) echo "/var/lib/postgresql" ;;        # postgres 18+
    eventstracker|runs-ai-analyzer|verbose-barnacle|sathish-projects-logger|mytracker) echo "/var/lib/postgresql/data" ;;
    *)                return 1 ;;
  esac
}

# Compose service name inside the VM stack.
get_project_db_service() {
  case "$1" in
    eventstracker)    echo "eventstracker-db" ;;
    runs-app)         echo "runs-app-db" ;;
    runs-ai-analyzer) echo "runs-ai-analyzer-db" ;;
    verbose-barnacle) echo "github-cleaner-db" ;;
    dbcleaner)        echo "dbcleaner-db" ;;
    sathish-projects-logger) echo "sathishlogger-db" ;;
    mytracker)        echo "mytracker-db" ;;
    *)                return 1 ;;
  esac
}

# Service name inside compose/docker-compose-local.yml (LOCAL profile only — differs
# from get_project_db_service, which is the VM stack's service naming). Empty return
# (via `return 1`) means the project isn't on the shared local compose file and still
# has its own standalone docker-compose.yml (verbose-barnacle, dbcleaner, sathish-projects-logger).
get_project_local_service() {
  case "$1" in
    eventstracker)    echo "postgres" ;;
    runs-app)         echo "runs-app-db" ;;
    runs-ai-analyzer) echo "runs-ai-analyzer-db" ;;
    mytracker)        echo "mytracker-db" ;;
    *)                return 1 ;;
  esac
}

# Compose --profile name gating that service in docker-compose-local.yml (empty/unset
# for eventstracker — it's always-on, no profile gate).
get_project_local_profile() {
  case "$1" in
    runs-app)         echo "runs-app" ;;
    runs-ai-analyzer) echo "runs-ai-analyzer" ;;
    mytracker)        echo "mytracker" ;;
    *)                return 1 ;;
  esac
}

# Named Docker volume on the VM (persistence).
get_project_vm_volume() {
  case "$1" in
    eventstracker)    echo "pg_data_eventstracker" ;;
    runs-app)         echo "pg_data_runs_app" ;;
    runs-ai-analyzer) echo "pg_data_runs_ai_analyzer" ;;
    verbose-barnacle) echo "pg_data_github_cleaner" ;;
    dbcleaner)        echo "pg_data_dbcleaner" ;;
    sathish-projects-logger) echo "pg_data_sathishlogger" ;;
    mytracker)        echo "pg_data_mytracker" ;;
    *)                return 1 ;;
  esac
}

# Portainer stack env-var names for DB name / user (password key already exists
# via get_project_password_env_var).
get_project_db_name_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_NAME" ;;
    runs-app)         echo "RUNS_APP_DB_NAME" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_NAME" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_NAME" ;;
    dbcleaner)        echo "DBCLEANER_DB_NAME" ;;
    sathish-projects-logger) echo "SATHISHLOGGER_DB_NAME" ;;
    mytracker)        echo "MYTRACKER_DB_NAME" ;;
    *)                return 1 ;;
  esac
}

get_project_db_user_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_USER" ;;
    runs-app)         echo "RUNS_APP_DB_USER" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_USER" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_USER" ;;
    dbcleaner)        echo "DBCLEANER_DB_USER" ;;
    sathish-projects-logger) echo "SATHISHLOGGER_DB_USER" ;;
    mytracker)        echo "MYTRACKER_DB_USER" ;;
    *)                return 1 ;;
  esac
}

# Key in each project's local .env that holds the JDBC URL.
get_project_db_url_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_URL" ;;
    runs-app)         echo "JDBC_DATABASE_URL" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_URL" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_URL" ;;
    dbcleaner)        echo "JDBC_DATABASE_URL" ;;
    sathish-projects-logger) echo "DATABASE_URL" ;;
    mytracker)        echo "MYTRACKER_DB_URL" ;;
    *)                return 1 ;;
  esac
}

get_project_password() {
  local project="$1"
  local env_var
  env_var=$(get_project_password_env_var "$project")
  local override="${!env_var:-}"
  if [ -n "$override" ]; then
    echo "$override"
    return 0
  fi

  local env_file
  env_file=$(get_project_env_file "$project")
  local key
  key=$(get_project_env_password_key "$project")

  if [ -f "$env_file" ]; then
    local value
    value=$(grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d'=' -f2-)
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi

  # Projects without a .env fall back to their compose-file default
  get_project_default_password "$project" && return 0

  return 1
}
