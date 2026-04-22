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
while IFS= read -r line; do
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

get_infra_config_dir() {
  echo "$(resolve_project_dir jubilant-memory)/config"
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
  case "$project" in
    eventstracker)     key="EVENTS_TRACKER_DB_USER"; default_user="" ;;
    runs-app)          key="JDBC_DATABASE_USERNAME"; default_user="" ;;
    runs-ai-analyzer)  key="JDBC_DATABASE_USERNAME"; default_user="" ;;
    *)                 return 1 ;;
  esac
  # Try project .env first
  if [ -f "$env_file" ]; then
    local value
    value=$(grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d'=' -f2-)
    if [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi
  # eventstracker: also try infra .env (golden source)
  if [ "$project" = "eventstracker" ]; then
    local infra_env
    infra_env="$(resolve_project_dir jubilant-memory)/config/.env"
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
  case "$1" in
    eventstracker)    echo "event-service" ;;   # jubilant-memory POSTGRES_DB default
    runs-app)         echo "runsapp_db" ;;
    runs-ai-analyzer) echo "runs-ai-analyzer" ;;
    *)                return 1 ;;
  esac
}

get_project_port() {
  case "$1" in
    eventstracker)    echo "6433" ;;   # jubilant-memory docker-compose host port
    runs-app)         echo "5443" ;;
    runs-ai-analyzer) echo "5444" ;;
    *)                return 1 ;;
  esac
}

get_project_container() {
  case "$1" in
    eventstracker)    echo "event-service-db" ;;   # jubilant-memory container_name
    runs-app)         echo "runs-app-postgres" ;;
    runs-ai-analyzer) echo "runs-ai-analyzer-db" ;;
    *)                return 1 ;;
  esac
}

get_project_password_env_var() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_PASSWORD" ;;
    runs-app)         echo "RUNS_APP_DB_PASSWORD" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_PASSWORD" ;;
    *)                return 1 ;;
  esac
}

get_project_env_password_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_PASSWORD" ;;
    runs-app)         echo "JDBC_DATABASE_PASSWORD" ;;
    runs-ai-analyzer) echo "JDBC_DATABASE_PASSWORD" ;;
    *)                return 1 ;;
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

  return 1
}
