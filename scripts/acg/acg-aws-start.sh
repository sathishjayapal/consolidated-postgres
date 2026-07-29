#!/usr/bin/env bash
set -euo pipefail

#################################################################
# ACG AWS Sandbox — PostgreSQL via SSM (Docker on EC2)
#
# Usage: ./scripts/acg/acg-aws-start.sh
#
# What it does:
#   1. Verifies prerequisites + AWS credentials
#   2. terraform init + apply (VPC + SSM relay EC2)
#   3. Waits for SSM agent to register on relay EC2
#   4. Opens SSM port-forwarding tunnel: localhost:5432 → EC2:5432
#   5. Waits for all three databases to be ready
#   6. Writes env/.env.cloud and updates each project's .env
#
# All three databases live in a single Docker pgvector/pgvector:pg16
# container on the EC2. user_data creates them on first boot.
#
# ACG credentials — export before running:
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_SESSION_TOKEN=...     ← required; absent = wrong profile
#   export AWS_DEFAULT_REGION=us-east-1
#
# Prerequisites: terraform, aws, aws-session-manager-plugin, psql, jq
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DB_DIR="$(cd "$REPO_ROOT/../iAC-NikeRuns/aws-modules/shared-db" && pwd)"
TFVARS_FILE="$SHARED_DB_DIR/terraform.tfvars"
TUNNEL_PID_FILE="$REPO_ROOT/.tunnel.pid"
LOCAL_PORT=5432    # single SSM tunnel: laptop → EC2 Docker PostgreSQL
ENV_CLOUD="$REPO_ROOT/env/.env.cloud"

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

print_section "ACG AWS Sandbox — PostgreSQL via SSM"

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

if ! command -v session-manager-plugin &>/dev/null; then
  print_error "session-manager-plugin not found."
  echo ""
  echo "  Install on macOS:"
  echo "    brew install --cask session-manager-plugin"
  echo "  OR: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  exit 1
fi
print_status "session-manager-plugin found"

# ── AWS credentials ───────────────────────────────────────────────────────────
print_section "Checking AWS Credentials"

if [ -z "${AWS_SESSION_TOKEN:-}" ]; then
  print_error "AWS_SESSION_TOKEN is not set — you are NOT using ACG sandbox credentials."
  echo ""
  echo "  From the ACG lab page → 'AWS Details' → 'Show' next to credentials:"
  echo ""
  echo "    export AWS_ACCESS_KEY_ID=ASIA..."
  echo "    export AWS_SECRET_ACCESS_KEY=..."
  echo "    export AWS_SESSION_TOKEN=..."
  echo "    export AWS_DEFAULT_REGION=us-east-1"
  exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
  print_error "AWS credentials are set but invalid (expired or wrong values)."
  echo "  Refresh credentials from the ACG lab page and re-export."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER=$(aws sts get-caller-identity --query Arn --output text)
REGION="${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || echo "us-east-1")}"
echo ""
echo -e "  ${YELLOW}Account : $ACCOUNT_ID${NC}"
echo -e "  ${YELLOW}Identity: $CALLER${NC}"
echo -e "  ${YELLOW}Region  : $REGION${NC}"
echo ""
read -r -p "  Is this your ACG sandbox account? (yes/no): " ACCT_CONFIRM
[[ "$ACCT_CONFIRM" == "yes" ]] || { print_error "Aborted — export the correct ACG credentials first."; exit 1; }
print_status "Credentials verified"

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
print_section "Provisioning Infrastructure (VPC + SSM relay EC2)"
print_info "EC2 t3.micro + Docker PostgreSQL 16 + pgvector."
print_info "First run takes ~3-5 min (image pull happens in the background after apply)."

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
DB_USER=$(terraform output -raw master_username)
SECRET_ARN=$(terraform output -raw secret_arn)

print_status "SSM relay instance: $INSTANCE_ID"

print_info "Fetching password from Secrets Manager..."
DB_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" --query SecretString --output text --region "$REGION" \
  | jq -r '.password')
print_status "Password retrieved"

# ── Step 1: Wait for EC2 to reach running state ───────────────────────────────
# Must do this BEFORE polling SSM — wasting SSM poll attempts on a
# not-yet-running instance burns the timeout for nothing.
print_section "Waiting for EC2 Instance to be Running"
print_info "Waiting for instance $INSTANCE_ID to reach running state..."

aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"
print_status "EC2 instance is running"

# ── Step 2: IAM propagation delay ────────────────────────────────────────────
# Known AWS race: EC2 boots and SSM agent starts BEFORE the instance profile
# credentials are fully available. SSM agent then fails auth on first attempt,
# backs off, and retries — this can take 30-60s.
# Waiting 45s here avoids burning SSM poll attempts during that window.
print_info "Waiting 45s for IAM instance profile credentials to propagate..."
sleep 45
print_status "IAM propagation wait done"

# ── Step 3: Wait for SSM agent to register ───────────────────────────────────
print_section "Waiting for SSM Agent to Register"
print_info "Polling SSM — timeout 420s (7 min). AL2023 boot + SSM registration takes 2-4 min."

MAX_WAIT=420
elapsed=0
until aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --region "$REGION" \
    --query "InstanceInformationList[0].InstanceId" \
    --output text 2>/dev/null | grep -q "$INSTANCE_ID"; do
  sleep 10; elapsed=$((elapsed + 10)); echo -n "."
  if [ $elapsed -ge $MAX_WAIT ]; then
    echo ""
    print_error "SSM agent did not register after ${MAX_WAIT}s"
    echo ""
    echo "  Diagnostic steps:"
    echo ""
    echo "  1. Check instance state:"
    echo "     aws ec2 describe-instances --instance-ids $INSTANCE_ID \\"
    echo "       --query 'Reservations[0].Instances[0].State.Name' --region $REGION"
    echo ""
    echo "  2. Check SSM agent status (requires console access or another method):"
    echo "     aws ssm describe-instance-information --region $REGION"
    echo ""
    echo "  3. Most common causes:"
    echo "     a) ACG sandbox expired / credentials rotated — re-export and retry"
    echo "     b) Instance is in wrong subnet (not public) — check VPC routing"
    echo "     c) Security group blocking outbound port 443 — check SG egress"
    echo "     d) IAM instance profile not attached — check terraform state"
    echo ""
    echo "  To retry without reprovisioning:"
    echo "     INSTANCE_ID=$INSTANCE_ID"
    echo "     ./acg-aws-start.sh   # will reuse existing EC2 via lifecycle ignore_changes"
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
    sleep 1
  fi
  rm -f "$TUNNEL_PID_FILE"
fi

# ── Open SSM tunnel ───────────────────────────────────────────────────────────
print_section "Opening SSM Port-Forwarding Tunnel"
print_info "localhost:$LOCAL_PORT → EC2 Docker PostgreSQL 16 (all databases)"

aws ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name "AWS-StartPortForwardingSession" \
  --parameters "{\"portNumber\":[\"5432\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
  --region "$REGION" \
  > /tmp/ssm-tunnel.log 2>&1 &
TUNNEL_PID=$!
echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
print_status "Tunnel started (PID $TUNNEL_PID)"

# ── Wait for databases to be ready ───────────────────────────────────────────
# user_data on EC2 runs async: dnf install docker → docker pull pgvector:pg16
# → docker run → pg_isready → CREATE DATABASE x3 → CREATE EXTENSION vector
# On a cold t3.micro this takes 3-7 min depending on image pull speed.
print_section "Waiting for Databases"
print_info "user_data installs Docker + pulls pgvector:pg16 — first boot takes 3-7 min."
print_info "Polling localhost:$LOCAL_PORT every 10s (timeout 600s / 10 min)..."

MAX_WAIT=600
elapsed=0
until PGPASSWORD="$DB_PASS" psql \
    -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d runsapp_db \
    -c "SELECT 1" &>/dev/null 2>&1; do
  sleep 10; elapsed=$((elapsed + 10))
  # Print progress every 60s so it's clear something is happening
  if (( elapsed % 60 == 0 )); then
    echo -n " ${elapsed}s"
  else
    echo -n "."
  fi
  if [ $elapsed -ge $MAX_WAIT ]; then
    echo ""
    print_error "Databases not ready after ${MAX_WAIT}s"
    echo ""
    echo "  SSM tunnel log:"
    cat /tmp/ssm-tunnel.log 2>/dev/null || echo "  (no tunnel log)"
    echo ""
    echo "  To see what user_data is doing on the EC2:"
    echo "    aws ssm start-session --target $INSTANCE_ID --region $REGION"
    echo "    sudo tail -f /var/log/pg-setup.log"
    echo ""
    echo "  To check if Docker is running on EC2:"
    echo "    aws ssm send-command \\"
    echo "      --instance-ids $INSTANCE_ID \\"
    echo "      --document-name AWS-RunShellScript \\"
    echo "      --parameters 'commands=[\"docker ps\"]' \\"
    echo "      --region $REGION"
    exit 1
  fi
done
echo ""
print_status "runsapp_db ready"

# Verify the other databases (created by user_data alongside runsapp_db)
for db in "event-service" "runs_ai_analyzer_db" "my-github-cleaner" "dbcleaner"; do
  if PGPASSWORD="$DB_PASS" psql \
      -h localhost -p "$LOCAL_PORT" -U "$DB_USER" -d "$db" \
      -c "SELECT 1" &>/dev/null 2>&1; then
    print_status "$db ready"
  else
    print_warning "$db not yet ready — user_data may still be running. Apps will connect once it finishes."
  fi
done

# ── Write env/.env.cloud ──────────────────────────────────────────────────────────
print_section "Writing env/.env.cloud"

JDBC_RA="jdbc:postgresql://localhost:${LOCAL_PORT}/runsapp_db"
JDBC_ET="jdbc:postgresql://localhost:${LOCAL_PORT}/event-service"
JDBC_AI="jdbc:postgresql://localhost:${LOCAL_PORT}/runs_ai_analyzer_db"
JDBC_GC="jdbc:postgresql://localhost:${LOCAL_PORT}/my-github-cleaner"
JDBC_DC="jdbc:postgresql://localhost:${LOCAL_PORT}/dbcleaner"

{
  printf "# ACG AWS — generated by acg-aws-start.sh\n"
  printf "# DO NOT COMMIT — gitignored\n"
  printf "# Generated: %s\n\n" "$(date)"

  printf "# SSM tunnel info\n"
  printf "SSM_RELAY_INSTANCE_ID=%s\n" "$INSTANCE_ID"
  printf "SSM_TUNNEL_PORT=%s\n\n" "$LOCAL_PORT"

  printf "# Shared credentials (all databases)\n"
  printf "DB_HOST=localhost\n"
  printf "DB_PORT=%s\n" "$LOCAL_PORT"
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

  printf "# verbose-barnacle (github cleaner)\n"
  printf "GITHUB_CLEANER_DB_URL=%s\n" "$JDBC_GC"
  printf "GITHUB_CLEANER_DB_USER=%s\n" "$DB_USER"
  printf "GITHUB_CLEANER_DB_PASSWORD=%s\n\n" "$DB_PASS"

  printf "# dbcleaner\n"
  printf "DBCLEANER_DB_URL=%s\n" "$JDBC_DC"
  printf "DBCLEANER_DB_USER=%s\n" "$DB_USER"
  printf "DBCLEANER_DB_PASSWORD=%s\n\n" "$DB_PASS"
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

# verbose-barnacle has no .env by default; create/update one so the app can
# read cloud DB settings if configured to do so
upsert_env "$(resolve_env verbose-barnacle)" \
  "GITHUB_CLEANER_DB_URL=$JDBC_GC" \
  "GITHUB_CLEANER_DB_USER=$DB_USER" \
  "GITHUB_CLEANER_DB_PASSWORD=$DB_PASS"
print_status "verbose-barnacle/.env updated"

upsert_env "$(resolve_env dbcleaner)" \
  "JDBC_DATABASE_URL=$JDBC_DC" \
  "JDBC_DATABASE_USERNAME=$DB_USER" \
  "JDBC_DATABASE_PASSWORD=$DB_PASS"
print_status "dbcleaner/.env updated"

# ── Status marker ─────────────────────────────────────────────────────────────
ACG_AWS_STATUS_FILE="$REPO_ROOT/.ACG_AWS_STATUS"

cat > "$ACG_AWS_STATUS_FILE" << EOF
ACG AWS PostgreSQL ACTIVE
Started: $(date)
EC2 instance: $INSTANCE_ID
SSM tunnel: localhost:$LOCAL_PORT (PID $TUNNEL_PID)

Databases (all on localhost:$LOCAL_PORT, user: $DB_USER):
  runsapp_db          → runs-app
  event-service       → eventstracker
  runs_ai_analyzer_db → runs-ai-analyzer (pgvector enabled)
  my-github-cleaner   → verbose-barnacle
  dbcleaner           → dbcleaner

TUNNEL RUNS IN BACKGROUND — keep credentials exported.
Re-run ./acg-aws-start.sh to reconnect if tunnel drops.
TO TEAR DOWN: ./acg-aws-stop.sh
ACG sandbox sessions expire — check the lab timer!
EOF

# ── Summary ───────────────────────────────────────────────────────────────────
print_section "All Databases Ready"

echo "  SSM tunnel: localhost:$LOCAL_PORT  (PID $TUNNEL_PID)"
echo "  User:       $DB_USER"
echo ""
echo "  runsapp_db          → runs-app"
echo "  event-service       → eventstracker"
echo "  runs_ai_analyzer_db → runs-ai-analyzer (pgvector enabled)"
echo "  my-github-cleaner   → verbose-barnacle"
echo "  dbcleaner           → dbcleaner"
echo ""
echo "  Start apps in this order:"
echo "  1. cd eventstracker    && ./mvnw spring-boot:run"
echo "  2. cd runs-app         && ./mvnw spring-boot:run"
echo "  3. cd runs-ai-analyzer && ./mvnw spring-boot:run"
echo ""
print_warning "ACG sandbox sessions expire — run ./acg-aws-stop.sh to save data before it ends!"
