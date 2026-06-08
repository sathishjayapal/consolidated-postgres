#!/usr/bin/env bash
set -euo pipefail

#################################################################
# ACG AWS Sandbox — Shared Aurora PostgreSQL Startup
#
# Usage: ./acg-aws-start.sh
#
# What it does:
#   1. Verifies prerequisites + AWS credentials
#   2. terraform init + apply (VPC, SSM relay EC2, Aurora)
#   3. Waits for SSM agent to register on relay EC2
#   4. Opens SSM port-forwarding tunnel: localhost:5432 → Aurora
#   5. Creates extra databases + enables pgvector via tunnel
#   6. Writes .env.cloud and updates each project's .env
#
# ACG credentials: copy from the ACG "Credentials" tab and export:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_SESSION_TOKEN=...     ← required for ACG sandboxes
#   export AWS_DEFAULT_REGION=us-east-1
#
# Prerequisites: terraform, aws, aws-session-manager-plugin, psql, jq
#   brew install session-manager-plugin   (or download from AWS docs)
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DB_DIR="$(cd "$SCRIPT_DIR/../iAC-NikeRuns/aws-modules/shared-db" && pwd)"
TFVARS_FILE="$SHARED_DB_DIR/terraform.tfvars"
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

print_section "ACG AWS Sandbox — Aurora PostgreSQL via SSM"

# ── Prerequisites ─────────────────────────────────────────────────────────────
print_section "Checking Prerequisites"

for tool in terraform aws psql jq; do
  if ! command -v "$tool" &>/dev/null; then
    print_error "$tool not found."
    case "$tool" in
      terraform) echo "  Install: https://www.terraform.io/downloads" ;;
      aws)       echo "  Install: brew install awscli" ;;
      psql)      echo "  macOS:   brew install libpq && brew link --force libpq" ;;
      jq)        echo "  Install: brew install jq" ;;
    esac
    exit 1
  fi
  print_status "$tool found"
done

# session-manager-plugin is a separate binary from aws CLI
if ! command -v session-manager-plugin &>/dev/null; then
  print_error "session-manager-plugin not found."
  echo ""
  echo "  Install on macOS:"
  echo "    brew install --cask session-manager-plugin"
  echo "  OR download from:"
  echo "    https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  exit 1
fi
print_status "session-manager-plugin found"

# ── AWS credentials ───────────────────────────────────────────────────────────
print_section "Checking AWS Credentials"

if ! aws sts get-caller-identity &>/dev/null; then
  print_error "AWS credentials not configured."
  echo ""
  echo "From the ACG 'Credentials' tab, export:"
  echo "  export AWS_ACCESS_KEY_ID=..."
  echo "  export AWS_SECRET_ACCESS_KEY=..."
  echo "  export AWS_SESSION_TOKEN=...   (required for ACG)"
  echo "  export AWS_DEFAULT_REGION=us-east-1"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region 2>/dev/null || echo "${AWS_DEFAULT_REGION:-us-east-1}")
print_status "Account: $ACCOUNT_ID  |  Region: $REGION"

# ── tfvars ────────────────────────────────────────────────────────────────────
print_section "Terraform Configuration"

if [ ! -f "$TFVARS_FILE" ]; then
  print_warning "terraform.tfvars not found — creating from example..."
  cp "$SHARED_DB_DIR/terraform.tfvars.example" "$TFVARS_FILE"
  echo ""
  print_info "Review and edit: $TFVARS_FILE"
  print_info "Then re-run this script."
  exit 0
fi
print_status "terraform.tfvars found"

# ── Terraform apply ───────────────────────────────────────────────────────────
print_section "Provisioning Infrastructure (VPC + SSM relay + Aurora)"
print_info "First run takes 8-12 minutes; subsequent runs are fast."

cd "$SHARED_DB_DIR"
terraform init -upgrade -input=false -reconfigure

print_info "Planning..."
terraform plan -var-file="$TFVARS_FILE" -input=false -out=/tmp/acg-aws.tfplan

echo ""
read -r -p "Apply? (yes/no) " CONFIRM
[[ "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]] || { print_error "Cancelled."; exit 0; }

terraform apply /tmp/acg-aws.tfplan
rm -f /tmp/acg-aws.tfplan
print_status "Infrastructure created!"

# ── Read Terraform outputs ────────────────────────────────────────────────────
print_section "Reading Outputs"

INSTANCE_ID=$(terraform output -raw ssm_relay_instance_id)
DB_HOST=$(terraform output -raw cluster_endpoint)
DB_PORT=$(terraform output -raw cluster_port)
DB_USER=$(terraform output -raw master_username)
SECRET_ARN=$(terraform output -raw secret_arn)

print_status "SSM relay instance: $INSTANCE_ID"
print_status "Aurora endpoint:    $DB_HOST:$DB_PORT"

print_info "Fetching password from Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString \
  --output text \
  --region "$REGION")
DB_PASS=$(echo "$SECRET_JSON" | jq -r '.password')
print_status "Password retrieved"

# ── Wait for SSM agent to register ───────────────────────────────────────────
print_section "Waiting for SSM Agent on Relay EC2"
print_info "The relay EC2 needs ~60-90s to boot and register with SSM..."

MAX_WAIT=180
elapsed=0
until aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --region "$REGION" \
    --query "InstanceInformationList[0].InstanceId" \
    --output text 2>/dev/null | grep -q "$INSTANCE_ID"; do
  sleep 10
  elapsed=$((elapsed + 10))
  echo -n "."
  if [ $elapsed -ge $MAX_WAIT ]; then
    print_error "SSM agent did not register after ${MAX_WAIT}s"
    echo "Check that the EC2 instance has internet access (public subnet + IGW)."
    exit 1
  fi
done
echo ""
print_status "SSM agent registered — relay EC2 is online"

# ── Kill any existing tunnel ──────────────────────────────────────────────────
if [ -f "$TUNNEL_PID_FILE" ]; then
  OLD_PID=$(cat "$TUNNEL_PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    print_info "Killing existing tunnel (PID $OLD_PID)..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 2
  fi
  rm -f "$TUNNEL_PID_FILE"
fi

# ── Open SSM port-forwarding tunnel ──────────────────────────────────────────
print_section "Opening SSM Port-Forwarding Tunnel"
print_info "localhost:$LOCAL_PORT → $DB_HOST:$DB_PORT (via SSM, no SSH)"

aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name "AWS-StartPortForwardingSessionToRemoteHost" \
  --parameters "{\"host\":[\"$DB_HOST\"],\"portNumber\":[\"$DB_PORT\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
  --region "$REGION" \
  > /tmp/ssm-tunnel.log 2>&1 &

TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
print_status "Tunnel started (PID $TUNNEL_PID)"

# Wait for the tunnel to be ready by polling localhost
print_info "Waiting for tunnel to be ready..."
elapsed=0
MAX_TUNNEL_WAIT=60
until PGPASSWORD="$DB_PASS" psql \
    -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d "runsapp_db" \
    -c "SELECT 1" &>/dev/null 2>&1; do
  sleep 3
  elapsed=$((elapsed + 3))
  echo -n "."
  if [ $elapsed -ge $MAX_TUNNEL_WAIT ]; then
    print_error "Tunnel not ready after ${MAX_TUNNEL_WAIT}s"
    echo "SSM tunnel log:"
    cat /tmp/ssm-tunnel.log || true
    exit 1
  fi
done
echo ""
print_status "Tunnel is live — localhost:$LOCAL_PORT reaches Aurora"

# ── Create additional databases + enable pgvector ─────────────────────────────
print_section "Creating Databases & Enabling pgvector"

run_sql() {
  local db="$1"; local sql="$2"
  PGPASSWORD="$DB_PASS" psql \
    -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d "$db" \
    -c "$sql" -q 2>&1
}

# event-service (eventstracker)
if PGPASSWORD="$DB_PASS" psql \
    -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname='event-service'" 2>/dev/null | grep -q 1; then
  print_status "event-service: already exists"
else
  run_sql "postgres" 'CREATE DATABASE "event-service";'
  print_status "event-service: created"
fi

# runs_ai_analyzer_db
if PGPASSWORD="$DB_PASS" psql \
    -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d postgres \
    -tc "SELECT 1 FROM pg_database WHERE datname='runs_ai_analyzer_db'" 2>/dev/null | grep -q 1; then
  print_status "runs_ai_analyzer_db: already exists"
else
  run_sql "postgres" "CREATE DATABASE runs_ai_analyzer_db;"
  print_status "runs_ai_analyzer_db: created"
fi

# Enable pgvector (Aurora PostgreSQL 15.5+ and 16.x include it natively)
run_sql "runs_ai_analyzer_db" "CREATE EXTENSION IF NOT EXISTS vector;" && \
  print_status "pgvector: enabled in runs_ai_analyzer_db" || \
  print_warning "pgvector: could not enable — check Aurora engine version (needs 15.5+ or 16.x)"

print_status "All 3 databases ready"

# ── Write .env.cloud ──────────────────────────────────────────────────────────
print_section "Writing .env.cloud"

# JDBC URLs use localhost because all apps connect via the SSM tunnel
JDBC_RA="jdbc:postgresql://localhost:${LOCAL_PORT}/runsapp_db"
JDBC_ET="jdbc:postgresql://localhost:${LOCAL_PORT}/event-service"
JDBC_AI="jdbc:postgresql://localhost:${LOCAL_PORT}/runs_ai_analyzer_db"

ENV_CLOUD="$SCRIPT_DIR/.env.cloud"
{
  printf "# ACG AWS Aurora — generated by acg-aws-start.sh\n"
  printf "# DO NOT COMMIT — gitignored\n"
  printf "# Generated: %s\n\n" "$(date)"

  printf "# SSM tunnel info\n"
  printf "SSM_RELAY_INSTANCE_ID=%s\n" "$INSTANCE_ID"
  printf "SSM_TUNNEL_LOCAL_PORT=%s\n\n" "$LOCAL_PORT"

  printf "# Shared connection (via tunnel → localhost)\n"
  printf "DB_HOST=localhost\n"
  printf "DB_PORT=%s\n" "$LOCAL_PORT"
  printf "DB_AURORA_HOST=%s\n" "$DB_HOST"
  printf "DB_AURORA_PORT=%s\n" "$DB_PORT"
  printf "DB_USERNAME=%s\n" "$DB_USER"
  printf "DB_PASSWORD=%s\n" "$DB_PASS"
  printf "SECRET_ARN=%s\n\n" "$SECRET_ARN"

  printf "# eventstracker\n"
  printf "EVENTS_TRACKER_DB_URL=%s\n" "$JDBC_ET"
  printf "EVENTS_TRACKER_DB_USER=%s\n" "$DB_USER"
  printf "EVENTS_TRACKER_DB_PASSWORD=%s\n\n" "$DB_PASS"

  printf "# runs-app\n"
  printf "JDBC_DATABASE_URL=%s\n" "$JDBC_RA"
  printf "JDBC_DATABASE_USERNAME=%s\n" "$DB_USER"
  printf "JDBC_DATABASE_PASSWORD=%s\n\n" "$DB_PASS"

  printf "# runs-ai-analyzer\n"
  printf "RUNS_AI_ANALYZER_DB_URL=%s\n" "$JDBC_AI"
  printf "RUNS_AI_ANALYZER_DB_USER=%s\n" "$DB_USER"
  printf "RUNS_AI_ANALYZER_DB_PASSWORD=%s\n\n" "$DB_PASS"
} > "$ENV_CLOUD"
print_status "Written: $ENV_CLOUD"

# ── Update project .env files ─────────────────────────────────────────────────
print_section "Updating Project .env Files"

upsert_env() {
  local env_file="$1"; shift
  touch "$env_file"
  while [ "$#" -gt 0 ]; do
    local kv="$1"; shift
    local key="${kv%%=*}"
    local val="${kv#*=}"
    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
      sed -i.bak "s|^${key}=.*|${key}=${val}|" "$env_file"
      rm -f "${env_file}.bak"
    else
      printf "%s=%s\n" "$key" "$val" >> "$env_file"
    fi
  done
}

resolve_env() {
  local project="$1"
  if [ -d "$HOME/IdeaProjects/$project" ]; then
    echo "$HOME/IdeaProjects/$project/.env"
  else
    echo "$(cd "$SCRIPT_DIR/.." && pwd)/$project/.env"
  fi
}

upsert_env "$(resolve_env eventstracker)" \
  "EVENTS_TRACKER_DB_URL=$JDBC_ET" \
  "EVENTS_TRACKER_DB_USER=$DB_USER" \
  "EVENTS_TRACKER_DB_PASSWORD=$DB_PASS"
print_status "eventstracker/.env updated"

upsert_env "$(resolve_env runs-app)" \
  "JDBC_DATABASE_URL=$JDBC_RA" \
  "JDBC_DATABASE_USERNAME=$DB_USER" \
  "JDBC_DATABASE_PASSWORD=$DB_PASS"
print_status "runs-app/.env updated"

upsert_env "$(resolve_env runs-ai-analyzer)" \
  "RUNS_AI_ANALYZER_DB_URL=$JDBC_AI" \
  "RUNS_AI_ANALYZER_DB_USER=$DB_USER" \
  "RUNS_AI_ANALYZER_DB_PASSWORD=$DB_PASS"
print_status "runs-ai-analyzer/.env updated"

# ── Status marker ─────────────────────────────────────────────────────────────
cat > "$SCRIPT_DIR/.ACG_AWS_STATUS" << EOF
ACG AWS Aurora PostgreSQL ACTIVE
Started: $(date)
SSM relay: $INSTANCE_ID
Aurora:    $DB_HOST:$DB_PORT  (private subnet — not directly reachable)
Tunnel:    localhost:$LOCAL_PORT  (PID $TUNNEL_PID)
Databases: runsapp_db | event-service | runs_ai_analyzer_db

KEEP THIS TERMINAL OPEN — the SSM tunnel runs in the background.
If you close this terminal, run: ./acg-aws-start.sh again (fast, no terraform apply)

TO TEAR DOWN:
  ./acg-aws-stop.sh

ACG sandbox sessions expire — check the lab timer!
EOF

# ── Summary ───────────────────────────────────────────────────────────────────
print_section "Aurora Ready"

echo "  Tunnel:    localhost:$LOCAL_PORT  (SSM, PID $TUNNEL_PID)"
echo "  Aurora:    $DB_HOST:$DB_PORT  (private subnet)"
echo "  User:      $DB_USER"
echo "  Databases: runsapp_db | event-service | runs_ai_analyzer_db"
echo ""
echo "  Start apps in this order:"
echo ""
echo "  1. EventTracker (provisions RabbitMQ queues first):"
echo "     cd eventstracker && ./mvnw spring-boot:run"
echo ""
echo "  2. Runs App:"
echo "     cd runs-app && ./mvnw spring-boot:run"
echo ""
echo "  3. Runs AI Analyzer:"
echo "     cd runs-ai-analyzer && ./mvnw spring-boot:run"
echo ""
print_warning "SSM tunnel PID $TUNNEL_PID written to .tunnel.pid"
print_warning "ACG sandbox sessions expire — run ./acg-aws-stop.sh to save data before it ends!"
