#!/usr/bin/env bash
set -euo pipefail

#################################################################
# ACG AWS Sandbox — PostgreSQL Teardown
#
# Usage: ./acg-aws-stop.sh
#
# What it does:
#   1. Reads connection info from .env.cloud or Terraform state
#   2. pg_dumps all 3 databases to ./backups/acg-aws-TIMESTAMP/
#   3. Kills the SSM port-forwarding tunnel
#   4. terraform destroy
#   5. Resets project .env files to local Docker defaults
#   6. Cleans up .env.cloud, .tunnel.pid, status marker
#
# Run this BEFORE your ACG lab session expires to preserve data.
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DB_DIR="$(cd "$SCRIPT_DIR/../iAC-NikeRuns/aws-modules/shared-db" && pwd)"
TFVARS_FILE="$SHARED_DB_DIR/terraform.tfvars"
ENV_CLOUD="$SCRIPT_DIR/.env.cloud"
TUNNEL_PID_FILE="$SCRIPT_DIR/.tunnel.pid"
LOCAL_PORT=5432

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_section() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

print_section "ACG AWS PostgreSQL — Teardown"
print_warning "This will EXPORT data and DESTROY the infrastructure."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { print_error "Cancelled."; exit 0; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in terraform aws psql jq; do
  command -v "$tool" &>/dev/null || { print_error "$tool not found"; exit 1; }
done

# Guard: ACG creds must be explicitly exported — no fallback to default profile.
if [ -z "${AWS_SESSION_TOKEN:-}" ]; then
  print_error "AWS_SESSION_TOKEN is not set — refusing to run against the default AWS profile."
  echo ""
  echo "  Export your ACG sandbox credentials first:"
  echo "    export AWS_ACCESS_KEY_ID=ASIA..."
  echo "    export AWS_SECRET_ACCESS_KEY=..."
  echo "    export AWS_SESSION_TOKEN=..."
  echo "    export AWS_DEFAULT_REGION=us-east-1"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
CALLER=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || true)
echo ""
echo -e "  ${YELLOW}Account : $ACCOUNT_ID${NC}"
echo -e "  ${YELLOW}Identity: $CALLER${NC}"
echo -e "  ${YELLOW}Region  : ${AWS_DEFAULT_REGION:-us-east-1}${NC}"
echo ""

# ── Load connection info ──────────────────────────────────────────────────────
print_section "Loading Connection Details"

# Declare all DB vars upfront so set -u never fires
DB_USERNAME=""
DB_PASSWORD=""
SECRET_ARN=""
SSM_RELAY_INSTANCE_ID=""
SKIP_BACKUP=false
TUNNEL_PID=""
KILL_TUNNEL=false

if [ -f "$ENV_CLOUD" ]; then
  # shellcheck disable=SC1090
  source <(grep -E '^(DB_USERNAME|DB_PASSWORD|SECRET_ARN|SSM_RELAY_INSTANCE_ID|SSM_TUNNEL_PORT)=' "$ENV_CLOUD") || true
  LOCAL_PORT="${SSM_TUNNEL_PORT:-5432}"
  print_status "Loaded from .env.cloud"
else
  print_info ".env.cloud not found — reading from Terraform state..."
  cd "$SHARED_DB_DIR"
  DB_USERNAME=$(terraform output -raw master_username 2>/dev/null || echo "")
  SECRET_ARN=$(terraform output -raw secret_arn 2>/dev/null || echo "")
  SSM_RELAY_INSTANCE_ID=$(terraform output -raw ssm_relay_instance_id 2>/dev/null || echo "")
  REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-east-1}")

  # Treat "null" string outputs as empty
  for var in DB_USERNAME SECRET_ARN SSM_RELAY_INSTANCE_ID; do
    [ "${!var}" = "null" ] && declare "$var"=""
  done

  if [ -z "$SECRET_ARN" ]; then
    print_warning "Cannot determine connection info — may already be destroyed."
    print_info "Attempting terraform destroy anyway..."
    terraform destroy -var-file="$TFVARS_FILE" -input=false -auto-approve || true
    rm -f "$ENV_CLOUD" "$SCRIPT_DIR/.ACG_AWS_STATUS" "$TUNNEL_PID_FILE"
    exit 0
  fi

  REGION="${AWS_DEFAULT_REGION:-us-east-1}"
  if ! SECRET_JSON=$(aws secretsmanager get-secret-value \
      --secret-id "$SECRET_ARN" --query SecretString --output text --region "$REGION" 2>/tmp/sm_err); then
    print_warning "Could not fetch secret: $(cat /tmp/sm_err || true)"
    print_warning "Skipping backup — proceeding to destroy."
    SKIP_BACKUP=true
  else
    DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
  fi
fi

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
print_status "DB user: $DB_USERNAME  |  tunnel port: $LOCAL_PORT"

# ── Manage SSM tunnel ─────────────────────────────────────────────────────────
print_section "Managing SSM Tunnel"

if [ -f "$TUNNEL_PID_FILE" ]; then
  TUNNEL_PID=$(cat "$TUNNEL_PID_FILE")
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    print_info "Tunnel (PID $TUNNEL_PID) running — keeping for backup"
    KILL_TUNNEL=true
  else
    rm -f "$TUNNEL_PID_FILE"; TUNNEL_PID=""
  fi
fi

# Re-open tunnel if needed and instance ID is known
if [ -z "$TUNNEL_PID" ] && [ -n "${SSM_RELAY_INSTANCE_ID:-}" ]; then
  print_info "Opening fresh tunnel for backup..."
  aws ssm start-session \
    --target "$SSM_RELAY_INSTANCE_ID" \
    --document-name "AWS-StartPortForwardingSession" \
    --parameters "{\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
    --region "$REGION" > /tmp/ssm-stop.log 2>&1 &
  TUNNEL_PID=$!; echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"; KILL_TUNNEL=true; sleep 10
fi

# ── Backup ────────────────────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="$SCRIPT_DIR/backups/acg-aws-$TIMESTAMP"
BACKUP_FAILURES=0

dump_db() {
  local db_name="$1"
  local label="$2"
  local backup_file="$BACKUP_DIR/${label}.sql"
  print_info "Dumping $db_name → ${label}.sql ..."
  # Intentionally not using set -e here — failed dump must not abort script.
  if PGPASSWORD="$DB_PASSWORD" pg_dump \
      -h localhost -p "$LOCAL_PORT" -U "$DB_USERNAME" -d "$db_name" \
      --no-privileges --no-owner \
      -f "$backup_file" 2>/tmp/pgdump_err; then
    local size
    size=$(du -sh "$backup_file" | awk '{print $1}')
    print_status "$label: $size"
  else
    print_warning "pg_dump failed for $db_name (will still destroy):"
    head -5 /tmp/pgdump_err || true
    touch "$backup_file"
    BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
  fi
}

if [ "$SKIP_BACKUP" == "true" ]; then
  print_warning "Skipping backup (no DB credentials available)."
else
  print_section "Exporting Databases (Step 1/3)"
  mkdir -p "$BACKUP_DIR"

  # Suspend -e so a failed dump continues to the next DB — destroy always runs.
  set +e
  dump_db "runsapp_db"          "runsapp"
  dump_db "event-service"       "eventstracker"
  dump_db "runs_ai_analyzer_db" "runsai"
  set -e

  if [ "$BACKUP_FAILURES" -gt 0 ]; then
    print_warning "$BACKUP_FAILURES dump(s) failed — proceeding to destroy anyway."
  else
    cat > "$BACKUP_DIR/RESTORE.md" << EOF
# ACG AWS Database Backup — $TIMESTAMP

## Databases
- runsapp.sql       → runsapp_db          (runs-app)
- eventstracker.sql → event-service       (eventstracker)
- runsai.sql        → runs_ai_analyzer_db (runs-ai-analyzer, pgvector)

## Restore steps
1. \`./acg-aws-start.sh\`   — provisions EC2 + opens SSM tunnel
2. Restore data:
\`\`\`bash
PGPASSWORD=\$DB_PASSWORD psql -h localhost -p 5432 -U \$DB_USERNAME -d runsapp_db          < runsapp.sql
PGPASSWORD=\$DB_PASSWORD psql -h localhost -p 5432 -U \$DB_USERNAME -d "event-service"     < eventstracker.sql
PGPASSWORD=\$DB_PASSWORD psql -h localhost -p 5432 -U \$DB_USERNAME -d runs_ai_analyzer_db < runsai.sql
\`\`\`
Note: run each Spring Boot app once first so Flyway migrations create the schema.
EOF
    print_status "Backups written to: $BACKUP_DIR"
  fi
fi

# ── Kill tunnel now that backup is done ───────────────────────────────────────
if [ "$KILL_TUNNEL" == "true" ] && [ -n "${TUNNEL_PID:-}" ]; then
  print_info "Closing tunnel (PID $TUNNEL_PID)..."
  kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$TUNNEL_PID_FILE"
fi
print_status "Tunnel closed"

# ── Terraform destroy ─────────────────────────────────────────────────────────
# Always runs — even if backups failed above.
print_section "Destroying Infrastructure (Step 2/3)"

cd "$SHARED_DB_DIR"
DESTROY_EXIT=0
terraform destroy -var-file="$TFVARS_FILE" -input=false -auto-approve || DESTROY_EXIT=$?
if [ "$DESTROY_EXIT" -eq 0 ]; then
  print_status "EC2, VPC, and secrets destroyed — charges stopped."
else
  print_error "terraform destroy exited with code $DESTROY_EXIT — check output above."
  print_warning "Some resources may still exist. Re-run stop script or destroy manually."
fi

# ── Reset project .env files ──────────────────────────────────────────────────
print_section "Resetting Project .env Files (Step 3/3)"

reset_env_key() {
  local project="$1"
  local env_file
  if [ -d "$HOME/IdeaProjects/$project" ]; then
    env_file="$HOME/IdeaProjects/$project/.env"
  else
    env_file="$(cd "$SCRIPT_DIR/.." && pwd)/$project/.env"
  fi
  [ -f "$env_file" ] || return
  shift
  while [ "$#" -gt 0 ]; do
    local kv="$1"; shift
    local key="${kv%%=*}"; local val="${kv#*=}"
    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
      sed -i.bak "s|^${key}=.*|${key}=${val}|" "$env_file"
      rm -f "${env_file}.bak"
    fi
  done
  print_status "$project .env reset to local Docker defaults"
}

reset_env_key "eventstracker" \
  "EVENTS_TRACKER_DB_URL=jdbc:postgresql://localhost:6433/event-service"

reset_env_key "runs-app" \
  "JDBC_DATABASE_URL=jdbc:postgresql://localhost:5443/runsapp_db"

reset_env_key "runs-ai-analyzer" \
  "RUNS_AI_ANALYZER_DB_URL=jdbc:postgresql://localhost:5444/runs_ai_analyzer_db"

rm -f "$ENV_CLOUD" "$SCRIPT_DIR/.ACG_AWS_STATUS" "$TUNNEL_PID_FILE"
print_status "Cleanup complete (.env.cloud, status marker, tunnel PID removed)"

# ── Summary ───────────────────────────────────────────────────────────────────
print_section "Teardown Complete"

if [ "$SKIP_BACKUP" != "true" ] && [ -d "$BACKUP_DIR" ]; then
  echo "  Backups: $BACKUP_DIR"
  ls -lh "$BACKUP_DIR"/*.sql 2>/dev/null | awk '{printf "    %s (%s)\n", $NF, $5}' || true
  if [ "$BACKUP_FAILURES" -gt 0 ]; then
    echo ""
    print_warning "$BACKUP_FAILURES backup(s) were empty due to dump failure."
  fi
else
  echo "  Backups: skipped"
fi
echo ""
echo "  Project .env files reset to local Docker defaults."
if [ "$DESTROY_EXIT" -ne 0 ]; then
  echo ""
  print_error "terraform destroy did not complete cleanly (exit $DESTROY_EXIT)."
  echo "  Check AWS console for lingering resources and re-run if needed."
fi
echo ""
echo "Next ACG session:"
echo "  1. Export new ACG AWS credentials"
echo "  2. ./acg-aws-start.sh"
if [ "$SKIP_BACKUP" != "true" ] && [ -d "$BACKUP_DIR" ]; then
  echo "  3. Restore data from: $BACKUP_DIR"
fi
