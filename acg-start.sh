#!/usr/bin/env bash
set -euo pipefail

#################################################################
# ACG Azure Sandbox — Shared PostgreSQL Startup
#
# Usage: ./acg-start.sh
#
# What it does:
#   1. Reads ACG sandbox details (subscription_id, rg_name)
#      from acg.tfvars (create from acg.tfvars.example) or prompts
#   2. Runs terraform apply targeting ONLY the PostgreSQL module
#      in ../iAC-NikeRuns (avoids touching configserver, storage, etc.)
#   3. Extracts JDBC connection strings from terraform outputs
#   4. Writes .env.cloud in this directory
#   5. Updates each project's .env file with the new cloud DB settings
#
# Prerequisites:
#   - Terraform installed
#   - Azure CLI logged in (az login) OR ARM_* env vars set
#   - acg.tfvars exists with your sandbox credentials (see acg.tfvars.example)
#   - pg_admin_password set in acg.tfvars or as TF_VAR_pg_admin_password
#
# Cost: Azure PostgreSQL Flexible Server B1ms ~ $0.02/hour on ACG sandbox
# ACG sandboxes expire after their session time — check the lab timer!
#
# Next steps after running:
#   ./scripts/local/multi-dev-up.sh --cloud
#   (starts apps pointing at the cloud DB, skips local containers)
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IAC_DIR="$(cd "$SCRIPT_DIR/../iAC-NikeRuns" && pwd)"
TFVARS_FILE="$SCRIPT_DIR/acg.tfvars"

# ── Colors ────────────────────────────────────────────────────────────────────
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

print_section "ACG Azure Sandbox — PostgreSQL Startup"

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! command -v terraform &>/dev/null; then
  print_error "Terraform not found. Install from https://www.terraform.io/downloads"
  exit 1
fi
print_status "Terraform: $(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1)"

if ! command -v jq &>/dev/null; then
  print_error "jq not found: brew install jq  OR  apt-get install jq"
  exit 1
fi
print_status "jq found"

if [ ! -d "$IAC_DIR" ]; then
  print_error "iAC-NikeRuns not found at: $IAC_DIR"
  print_info  "Clone it as a sibling of consolidated-postgres"
  exit 1
fi
print_status "iAC-NikeRuns found at: $IAC_DIR"

# ── ACG sandbox credentials ───────────────────────────────────────────────────
print_section "ACG Sandbox Credentials"

if [ ! -f "$TFVARS_FILE" ]; then
  print_warning "acg.tfvars not found. Creating from template..."
  cat > "$TFVARS_FILE" << 'TEMPLATE'
# ACG Azure sandbox credentials — DO NOT COMMIT (gitignored)
# Fill in values from your ACG lab credentials page.

subscription_id = "PASTE_FROM_ACG_LAB"
tenant_id       = "PASTE_FROM_ACG_LAB"
rg_name         = "PASTE_FROM_ACG_LAB"   # e.g. "1-abc123-playground-sandbox"

# Database admin password — choose something strong
pg_admin_password = "ACGdev$2025!Pg"

# Required by other modules but not used when targeting postgres only.
# Leave as-is unless you're applying the full stack.
prefix          = "test"
environment     = "dev"
primary_location = "East US"
main_group_name = "sathisprj1"
TEMPLATE
  print_error "Edit $TFVARS_FILE with your ACG lab credentials, then re-run."
  exit 1
fi

# Validate key fields are filled in
for field in subscription_id tenant_id rg_name pg_admin_password; do
  value=$(grep -E "^${field}\s*=" "$TFVARS_FILE" | awk -F'"' '{print $2}')
  if [[ "$value" == *"PASTE_FROM_ACG_LAB"* ]] || [ -z "$value" ]; then
    print_error "$field in acg.tfvars is not set. Fill it in from your ACG lab credentials."
    exit 1
  fi
done
print_status "acg.tfvars looks complete"

# ── Terraform init + targeted apply ──────────────────────────────────────────
print_section "Terraform Init"

cd "$IAC_DIR"

# Delete stale lock file if the sandbox subscription changed
LOCK_FILE=".terraform.lock.hcl"
PREV_SUB=$(grep -r "subscription_id" .terraform/terraform.tfstate 2>/dev/null | awk -F'"' '{print $4}' | head -1 || true)
CURR_SUB=$(grep -E "^subscription_id" "$TFVARS_FILE" | awk -F'"' '{print $2}')
if [ -n "$PREV_SUB" ] && [ "$PREV_SUB" != "$CURR_SUB" ]; then
  print_warning "Sandbox subscription changed — cleaning stale Terraform state..."
  rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup 2>/dev/null || true
fi

terraform init -upgrade -input=false

print_section "Terraform Plan (PostgreSQL module only)"
print_info "Targeting: module.flexipostgresmodule"
print_info "This creates: 1 server + 3 databases + pgvector config + firewall rule"
echo ""

terraform plan \
  -var-file="$TFVARS_FILE" \
  -target=module.flexipostgresmodule \
  -input=false \
  -out=/tmp/acg-postgres.tfplan

echo ""
read -p "Apply the plan? (yes/no) " -r CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
  print_error "Cancelled — no infrastructure created."
  exit 0
fi

print_section "Creating Azure PostgreSQL (takes 5-8 minutes)"
terraform apply /tmp/acg-postgres.tfplan
rm -f /tmp/acg-postgres.tfplan

print_status "PostgreSQL Flexible Server created!"

# ── Extract outputs ───────────────────────────────────────────────────────────
print_section "Extracting Connection Details"

PG_HOST=$(terraform output -raw pg_host)
PG_PORT=$(terraform output -raw pg_port)
PG_USER=$(terraform output -raw pg_admin_user)
PG_PASS=$(terraform output -raw pg_admin_password)
JDBC_ET=$(terraform output -raw jdbc_eventstracker)
JDBC_RA=$(terraform output -raw jdbc_runsapp)
JDBC_AI=$(terraform output -raw jdbc_runsai)
JDBC_GC=$(terraform output -raw jdbc_githubcleaner 2>/dev/null || echo "jdbc:postgresql://${PG_HOST}:5432/my-github-cleaner?sslmode=require")
JDBC_DC=$(terraform output -raw jdbc_dbcleaner 2>/dev/null || echo "jdbc:postgresql://${PG_HOST}:5432/dbcleaner?sslmode=require")
DB_ET=$(terraform output -raw db_name_eventstracker)
DB_RA=$(terraform output -raw db_name_runsapp)
DB_AI=$(terraform output -raw db_name_runsai)
DB_GC=$(terraform output -raw db_name_githubcleaner 2>/dev/null || echo "my-github-cleaner")
DB_DC=$(terraform output -raw db_name_dbcleaner 2>/dev/null || echo "dbcleaner")

print_status "Host:  $PG_HOST"
print_status "Port:  $PG_PORT"
print_status "User:  $PG_USER"
print_status "DBs:   $DB_ET | $DB_RA | $DB_AI | $DB_GC | $DB_DC"

# ── Write .env.cloud ──────────────────────────────────────────────────────────
print_section "Writing .env.cloud"

ENV_CLOUD="$SCRIPT_DIR/.env.cloud"
{
  printf "# ACG Azure PostgreSQL — generated by acg-start.sh\n"
  printf "# DO NOT COMMIT — gitignored\n"
  printf "# Generated: %s\n\n" "$(date)"

  printf "# Shared connection info\n"
  printf "DB_HOST=%s\n" "$PG_HOST"
  printf "DB_PORT=%s\n" "$PG_PORT"
  printf "DB_USERNAME=%s\n" "$PG_USER"
  printf "DB_PASSWORD=%s\n\n" "$PG_PASS"

  printf "# eventstracker\n"
  printf "EVENTS_TRACKER_DB_URL=%s\n" "$JDBC_ET"
  printf "EVENTS_TRACKER_DB_USER=%s\n" "$PG_USER"
  printf "EVENTS_TRACKER_DB_PASSWORD=%s\n\n" "$PG_PASS"

  printf "# runs-app\n"
  printf "JDBC_DATABASE_URL=%s\n" "$JDBC_RA"
  printf "JDBC_DATABASE_USERNAME=%s\n" "$PG_USER"
  printf "JDBC_DATABASE_PASSWORD=%s\n\n" "$PG_PASS"

  printf "# runs-ai-analyzer\n"
  printf "RUNS_AI_ANALYZER_DB_URL=%s\n" "$JDBC_AI"
  printf "RUNS_AI_ANALYZER_DB_USER=%s\n" "$PG_USER"
  printf "RUNS_AI_ANALYZER_DB_PASSWORD=%s\n\n" "$PG_PASS"

  printf "# verbose-barnacle (github cleaner)\n"
  printf "GITHUB_CLEANER_DB_URL=%s\n" "$JDBC_GC"
  printf "GITHUB_CLEANER_DB_USER=%s\n" "$PG_USER"
  printf "GITHUB_CLEANER_DB_PASSWORD=%s\n\n" "$PG_PASS"

  printf "# dbcleaner\n"
  printf "DBCLEANER_DB_URL=%s\n" "$JDBC_DC"
  printf "DBCLEANER_DB_USER=%s\n" "$PG_USER"
  printf "DBCLEANER_DB_PASSWORD=%s\n\n" "$PG_PASS"
} > "$ENV_CLOUD"
print_status "Written: $ENV_CLOUD"

# ── Update each project's .env ────────────────────────────────────────────────
print_section "Updating Project .env Files"

WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

update_project_env() {
  local project="$1"
  local env_file

  # Resolve project dir: prefer ~/IdeaProjects/<name>
  if [ -d "$HOME/IdeaProjects/$project" ]; then
    env_file="$HOME/IdeaProjects/$project/.env"
  else
    env_file="$WORKSPACE_ROOT/$project/.env"
  fi

  shift  # remaining args are KEY=VALUE pairs to set

  print_info "Updating $project → $env_file"

  # Create .env if it doesn't exist
  touch "$env_file"

  # For each KEY=VALUE pair, upsert in the file
  while [ "$#" -gt 0 ]; do
    local kv="$1"; shift
    local key="${kv%%=*}"
    local val="${kv#*=}"
    # Escape special chars in val for sed
    local escaped_val
    escaped_val=$(printf '%s\n' "$val" | sed 's/[[\.*^$()+?{|]/\\&/g; s/]/\\]/g')

    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
      # Replace existing line
      sed -i.bak "s|^${key}=.*|${key}=${escaped_val}|" "$env_file"
    else
      # Append new line
      printf "%s=%s\n" "$key" "$val" >> "$env_file"
    fi
  done

  # Clean up sed backup files
  rm -f "${env_file}.bak"
  print_status "$project .env updated"
}

update_project_env "eventstracker" \
  "EVENTS_TRACKER_DB_URL=$JDBC_ET" \
  "EVENTS_TRACKER_DB_USER=$PG_USER" \
  "EVENTS_TRACKER_DB_PASSWORD=$PG_PASS"

update_project_env "runs-app" \
  "JDBC_DATABASE_URL=$JDBC_RA" \
  "JDBC_DATABASE_USERNAME=$PG_USER" \
  "JDBC_DATABASE_PASSWORD=$PG_PASS"

update_project_env "runs-ai-analyzer" \
  "RUNS_AI_ANALYZER_DB_URL=$JDBC_AI" \
  "RUNS_AI_ANALYZER_DB_USER=$PG_USER" \
  "RUNS_AI_ANALYZER_DB_PASSWORD=$PG_PASS"

update_project_env "verbose-barnacle" \
  "GITHUB_CLEANER_DB_URL=$JDBC_GC" \
  "GITHUB_CLEANER_DB_USER=$PG_USER" \
  "GITHUB_CLEANER_DB_PASSWORD=$PG_PASS"

update_project_env "dbcleaner" \
  "JDBC_DATABASE_URL=$JDBC_DC" \
  "JDBC_DATABASE_USERNAME=$PG_USER" \
  "JDBC_DATABASE_PASSWORD=$PG_PASS"

# ── Write status marker ───────────────────────────────────────────────────────
cat > "$SCRIPT_DIR/.ACG_STATUS" << EOF
ACG Azure PostgreSQL ACTIVE
Started: $(date)
Host: $PG_HOST
Databases: $DB_ET | $DB_RA | $DB_AI | $DB_GC | $DB_DC

TO TEAR DOWN (export + destroy):
  ./acg-stop.sh

Remember: ACG sandbox sessions expire! Check the lab timer.
EOF

# ── Summary ───────────────────────────────────────────────────────────────────
print_section "ACG PostgreSQL Ready"

echo "  Host:      $PG_HOST"
echo "  Port:      $PG_PORT"
echo "  User:      $PG_USER"
echo "  Databases: $DB_ET | $DB_RA | $DB_AI | $DB_GC | $DB_DC"
echo ""
echo "All project .env files updated. Start apps in this order:"
echo ""
echo "  1. EventTracker (provisions RabbitMQ queues)"
echo "     cd \$(resolve eventstracker) && ./mvnw spring-boot:run"
echo ""
echo "  2. Runs App"
echo "     cd \$(resolve runs-app) && ./mvnw spring-boot:run"
echo ""
echo "  3. Runs AI Analyzer"
echo "     cd \$(resolve runs-ai-analyzer) && ./mvnw spring-boot:run"
echo ""
print_warning "ACG sandbox sessions expire — run ./acg-stop.sh to save data before the session ends!"
