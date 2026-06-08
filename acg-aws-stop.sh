#!/usr/bin/env bash
set -euo pipefail

#################################################################
# ACG AWS Sandbox — Aurora PostgreSQL Teardown
#
# Usage: ./acg-aws-stop.sh
#
# What it does:
#   1. Reads connection info from .env.cloud or Terraform state
#   2. Kills the SSM port-forwarding tunnel
#   3. pg_dumps all 3 databases to ./backups/acg-aws-TIMESTAMP/
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

print_section "ACG AWS Aurora — Teardown"
print_warning "This will EXPORT data and DESTROY the Aurora cluster."
echo ""
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { print_error "Cancelled."; exit 0; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in terraform aws psql jq; do
  command -v "$tool" &>/dev/null || { print_error "$tool not found"; exit 1; }
done

# ── Load connection info ──────────────────────────────────────────────────────
print_section "Loading Connection Details"

if [ -f "$ENV_CLOUD" ]; then
  # shellcheck disable=SC1090
  source <(grep -E '^(DB_HOST|DB_PORT|DB_USERNAME|DB_PASSWORD|SECRET_ARN|SSM_RELAY_INSTANCE_ID|SSM_TUNNEL_LOCAL_PORT)=' "$ENV_CLOUD")
  LOCAL_PORT="${SSM_TUNNEL_LOCAL_PORT:-5432}"
  print_status "Loaded from .env.cloud"
else
  print_info ".env.cloud not found — reading from Terraform state..."
  cd "$SHARED_DB_DIR"
  DB_HOST=$(terraform output -raw cluster_endpoint 2>/dev/null || echo "")
  DB_PORT=$(terraform output -raw cluster_port 2>/dev/null || echo "5432")
  DB_USERNAME=$(terraform output -raw master_username 2>/dev/null || echo "")
  SECRET_ARN=$(terraform output -raw secret_arn 2>/dev/null || echo "")
  SSM_RELAY_INSTANCE_ID=$(terraform output -raw ssm_relay_instance_id 2>/dev/null || echo "")
  REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-east-1}")

  if [ -z "$DB_HOST" ] || [ -z "$SECRET_ARN" ]; then
    print_error "Cannot determine connection info. Aurora may already be destroyed."
    print_info "Attempting terraform destroy anyway..."
    terraform destroy -var-file="$TFVARS_FILE" -input=false -auto-approve || true
    rm -f "$ENV_CLOUD" "$SCRIPT_DIR/.ACG_AWS_STATUS" "$TUNNEL_PID_FILE"
    exit 0
  fi

  SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ARN" --query SecretString --output text --region "$REGION")
  DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.password')
fi

REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-east-1}")
print_status "Aurora: $DB_HOST:$DB_PORT  |  User: $DB_USERNAME"

# ── Kill SSM tunnel ───────────────────────────────────────────────────────────
print_section "Closing SSM Tunnel"

if [ -f "$TUNNEL_PID_FILE" ]; then
  TUNNEL_PID=$(cat "$TUNNEL_PID_FILE")
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    # Need tunnel alive long enough to do backups — keep it, kill after backup
    print_info "Tunnel (PID $TUNNEL_PID) is running — keeping it open for backup..."
    KILL_TUNNEL_AFTER_BACKUP=true
  else
    print_warning "Tunnel process $TUNNEL_PID is not running"
    KILL_TUNNEL_AFTER_BACKUP=false
    rm -f "$TUNNEL_PID_FILE"
  fi
else
  print_warning ".tunnel.pid not found"
  KILL_TUNNEL_AFTER_BACKUP=false

  # Try to open a fresh tunnel for backup purposes if we have the instance ID
  if [ -n "${SSM_RELAY_INSTANCE_ID:-}" ]; then
    print_info "Attempting to open a tunnel for backup..."
    aws ssm start-session \
      --target "$SSM_RELAY_INSTANCE_ID" \
      --document-name "AWS-StartPortForwardingSessionToRemoteHost" \
      --parameters "{\"host\":[\"$DB_HOST\"],\"portNumber\":[\"$DB_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
      --region "$REGION" \
      > /tmp/ssm-tunnel-stop.log 2>&1 &
    TUNNEL_PID=$!
    echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
    KILL_TUNNEL_AFTER_BACKUP=true

    # Wait up to 30s for tunnel
    elapsed=0
    until PGPASSWORD="$DB_PASSWORD" psql \
        -h localhost -p "$LOCAL_PORT" -U "$DB_USERNAME" -d postgres \
        -c "SELECT 1" &>/dev/null 2>&1; do
      sleep 3; elapsed=$((elapsed+3)); echo -n "."
      [ $elapsed -ge 30 ] && break
    done
    echo ""
  fi
fi

# ── Backup ────────────────────────────────────────────────────────────────────
print_section "Exporting Databases (Step 1/3)"

TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="$SCRIPT_DIR/backups/acg-aws-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

dump_db() {
  local db_name="$1"
  local label="$2"
  local backup_file="$BACKUP_DIR/${label}.sql"
  print_info "Dumping $db_name → ${label}.sql ..."
  if PGPASSWORD="$DB_PASSWORD" pg_dump \
      -h localhost -p "$LOCAL_PORT" -U "$DB_USERNAME" -d "$db_name" \
      --no-privileges --no-owner \
      -f "$backup_file" 2>/tmp/pgdump_err; then
    local size
    size=$(du -sh "$backup_file" | awk '{print $1}')
    print_status "$label: $size"
  else
    print_warning "pg_dump failed for $db_name:"
    head -5 /tmp/pgdump_err || true
    touch "$backup_file"
  fi
}

dump_db "runsapp_db"          "runsapp"
dump_db "event-service"       "eventstracker"
dump_db "runs_ai_analyzer_db" "runsai"

cat > "$BACKUP_DIR/RESTORE.md" << EOF
# ACG AWS Database Backup — $TIMESTAMP

## Databases
- runsapp.sql       → runsapp_db          (runs-app)
- eventstracker.sql → event-service       (eventstracker)
- runsai.sql        → runs_ai_analyzer_db (runs-ai-analyzer, needs pgvector)

## Restore steps
1. \`./acg-aws-start.sh\`   — recreates Aurora + opens SSM tunnel
2. Restore data:
\`\`\`bash
PGPASSWORD=\$DB_PASSWORD psql -h localhost -p 5432 -U \$DB_USERNAME -d runsapp_db         < runsapp.sql
PGPASSWORD=\$DB_PASSWORD psql -h localhost -p 5432 -U \$DB_USERNAME -d "event-service"    < eventstracker.sql
PGPASSWORD=\$DB_PASSWORD psql -h localhost -p 5432 -U \$DB_USERNAME -d runs_ai_analyzer_db < runsai.sql
\`\`\`
Note: runs-ai-analyzer Flyway migrations enable pgvector — run the app once before restoring runsai.sql.
EOF

print_status "Backups written to: $BACKUP_DIR"

# ── Kill tunnel now that backup is done ───────────────────────────────────────
if [ "${KILL_TUNNEL_AFTER_BACKUP:-false}" == "true" ] && [ -f "$TUNNEL_PID_FILE" ]; then
  TUNNEL_PID=$(cat "$TUNNEL_PID_FILE")
  print_info "Closing SSM tunnel (PID $TUNNEL_PID)..."
  kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$TUNNEL_PID_FILE"
  print_status "Tunnel closed"
fi

# ── Terraform destroy ─────────────────────────────────────────────────────────
print_section "Destroying Infrastructure (Step 2/3)"

cd "$SHARED_DB_DIR"
terraform destroy -var-file="$TFVARS_FILE" -input=false -auto-approve
print_status "Aurora cluster, SSM relay, and VPC destroyed — charges stopped."

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

echo "  Backups: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"/*.sql 2>/dev/null | awk '{printf "    %s (%s)\n", $NF, $5}' || true
echo ""
echo "  Project .env files reset to local Docker defaults."
echo ""
echo "Next ACG session:"
echo "  1. Export new ACG AWS credentials"
echo "  2. ./acg-aws-start.sh"
echo "  3. If needed, restore data:"
echo "     PGPASSWORD=... psql -h localhost -p 5432 -U ... -d runsapp_db < $BACKUP_DIR/runsapp.sql"
