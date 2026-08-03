#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Prod Database Startup (DigitalOcean, persistent)
#
# Usage: ./scripts/prod/prod-start.sh
#
# What it does:
#   1. Creates DigitalOcean PostgreSQL instance ($15/month cost)
#   2. Creates 3 databases: eventstracker_db, runsapp_db, runsai_db
#   3. Creates backup bucket in DigitalOcean Spaces
#   4. Generates connection details to env/.env.prod
#   5. Ready to connect from your local apps
#
# Cost: ~$0.50/day = ~$15/month if run continuously
#
# This is the "prod" profile — persistent by design. Unlike the ACG sandboxes,
# it is NOT meant to be torn down casually: scripts/prod/prod-stop.sh takes a
# backup on every run but only destroys the infrastructure when you pass
# --destroy explicitly.
#
# Next steps:
#   1. Update application.yml in each project with env/.env.prod details
#      (or run each project's dev-up.sh --prod)
#   2. Deploy your applications (or run locally pointing to prod DB)
#   3. When actually done with this infra: ./scripts/prod/prod-stop.sh --destroy
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_PROD="$REPO_ROOT/env/.env.prod"
PROD_STATUS_FILE="$REPO_ROOT/.PROD_STATUS"
PROJECT_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
source "$REPO_ROOT/scripts/lib/project-config.sh"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_section() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Check prerequisites
print_section "Checking Prerequisites"

if ! command -v terraform &> /dev/null; then
  print_error "Terraform not found. Install from: https://www.terraform.io/downloads"
  exit 1
fi
print_status "Terraform found: $(terraform version -json | jq -r '.terraform_version')"

if ! command -v jq &> /dev/null; then
  print_error "jq not found. Install with: brew install jq (macOS) or apt-get install jq (Linux)"
  exit 1
fi
print_status "jq found"

# Check terraform files exist
if [ ! -f "terraform.tf" ]; then
  print_error "terraform.tf not found in $SCRIPT_DIR"
  exit 1
fi
print_status "terraform.tf found"

if [ ! -f "terraform.tfvars" ]; then
  print_error "terraform.tfvars not found. Create it with your DigitalOcean API token."
  echo ""
  echo "Create terraform.tfvars with:"
  echo "  do_token = \"dop_v1_your_token_here\""
  echo "  region = \"nyc3\""
  exit 1
fi
print_status "terraform.tfvars found"

# Verify DigitalOcean token
print_section "Verifying DigitalOcean Access"

DO_TOKEN=$(grep "^do_token" terraform.tfvars | awk -F'"' '{print $2}')

if [ -z "$DO_TOKEN" ]; then
  print_error "Could not extract DigitalOcean token from terraform.tfvars"
  exit 1
fi

# Test DO API access
if curl -s -H "Authorization: Bearer $DO_TOKEN" https://api.digitalocean.com/v2/account | jq .account > /dev/null 2>&1; then
  print_status "DigitalOcean API access verified"
else
  print_error "Could not access DigitalOcean API. Check your token in terraform.tfvars"
  exit 1
fi

# Initialize Terraform
print_section "Initializing Terraform"

if [ -d ".terraform" ]; then
  print_status "Terraform already initialized"
else
  print_info "First time setup - initializing terraform..."
  terraform init
  print_status "Terraform initialized"
fi

# Show what will be created
print_section "Terraform Plan (Review Before Proceeding)"

print_info "This will create:"
print_info "  • PostgreSQL instance (db-s-1vcpu-1gb): ~\$0.50/day"
print_info "  • 3 databases: eventstracker_db, runsapp_db, runsai_db"
print_info "  • DigitalOcean Spaces bucket for backups: ~\$0.17/day"
echo ""
print_info "This is the prod profile — prod-stop.sh backs up but does not destroy unless you pass --destroy"
echo ""

terraform plan -var-file="terraform.tfvars" > /tmp/tf_plan.txt 2>&1

# Show summary
print_info "Plan summary:"
grep "Plan:" /tmp/tf_plan.txt || echo "  (Check /tmp/tf_plan.txt for details)"

echo ""
read -p "Continue with creation? (yes/no) " -r CONFIRM
if [[ ! $CONFIRM =~ ^[Yy][Ee][Ss]$ ]]; then
  print_error "Cancelled"
  exit 0
fi

# Create infrastructure
print_section "Creating Cloud Infrastructure"

print_info "Creating DigitalOcean resources... (this takes 3-5 minutes)"
terraform apply -var-file="terraform.tfvars" -auto-approve

print_status "Cloud infrastructure created!"

# Get outputs
print_section "Retrieving Connection Details"

DB_HOST=$(terraform output -raw database_host)
DB_PORT=$(terraform output -raw database_port)
DB_USER=$(terraform output -raw database_user)
DB_PASSWORD=$(terraform output -raw database_password 2>/dev/null || echo "CHECK_TERRAFORM_OUTPUT")
EVENTSTRACKER_DB=$(terraform output -raw eventstracker_db_name)
RUNSAPP_DB=$(terraform output -raw runsapp_db_name)
RUNSAI_DB=$(terraform output -raw runsai_db_name)

print_status "Database host: $DB_HOST"
print_status "Database port: $DB_PORT"
print_status "Database user: $DB_USER"
print_status "Databases: $EVENTSTRACKER_DB, $RUNSAPP_DB, $RUNSAI_DB"

# Create env/.env.prod file
# Key names come from project-config.sh (get_project_db_url_key /
# get_project_db_user_env_key / get_project_env_password_key) — the same
# per-project "domain A" keys used by local dev, ACG, and each project's
# dev-up.sh --prod, so this file and dev-up.sh never disagree on a key name.
print_section "Generating env/.env.prod Configuration"

cat > "$ENV_PROD" << 'EOF'
# Prod Database Configuration (DigitalOcean)
# Generated by scripts/prod/prod-start.sh
# WARNING: Sensitive data - don't commit to git!

# DigitalOcean PostgreSQL Details
EOF

# Append configuration values safely (using printf to handle special characters)
{
  printf "DB_HOST=%s\n" "$DB_HOST"
  printf "DB_PORT=%s\n" "$DB_PORT"
  printf "DB_USERNAME=%s\n" "$DB_USER"
  printf "DB_PASSWORD=%s\n" "$DB_PASSWORD"

  for entry in "eventstracker:$EVENTSTRACKER_DB" "runs-app:$RUNSAPP_DB" "runs-ai-analyzer:$RUNSAI_DB"; do
    project="${entry%%:*}"; dbname="${entry#*:}"
    jdbc_url=$(printf "jdbc:postgresql://%s:%s/%s?sslmode=require" "$DB_HOST" "$DB_PORT" "$dbname")
    printf "\n# %s\n" "$project"
    printf "%s=%s\n" "$(get_project_db_url_key "$project")" "$jdbc_url"
    printf "%s=%s\n" "$(get_project_db_user_env_key "$project")" "$DB_USER"
    printf "%s=%s\n" "$(get_project_env_password_key "$project")" "$DB_PASSWORD"
  done

  printf "\n# RabbitMQ (set explicitly if using managed broker)\n"
  printf "# RABBITMQ_HOST=\n"
  printf "# RABBITMQ_PORT=\n"
  printf "# RABBITMQ_USERNAME=\n"
  printf "# RABBITMQ_PASSWORD=\n"
  printf "\n# Generated at: $(date)\n"
  printf "# Cost: Approximately \$0.67/day while infrastructure is running\n"
  printf "# Action: Run ./scripts/prod/prod-stop.sh --destroy to actually tear this down\n"
} >> "$ENV_PROD"

print_status "Created $ENV_PROD"
print_info "Copy connection details from above to your applications"

# Create reminder file
cat > "$PROD_STATUS_FILE" << EOF
🌥️  PROD INFRASTRUCTURE ACTIVE
Created: $(date)
Cost: ~\$0.67/day = ~\$20/month if always running

This is the persistent "prod" profile. ./scripts/prod/prod-stop.sh backs up
on every run but only DESTROYS the infrastructure when you pass --destroy —
running it plain is safe.

TO ACTUALLY TEAR DOWN & STOP CHARGES:
  ./scripts/prod/prod-stop.sh --destroy
EOF

print_status "Status file: $PROD_STATUS_FILE"

# Summary
print_section "✅ Prod Infrastructure Ready"

echo "Your prod database is now active!"
echo ""
echo "Connection Details:"
echo "  Host:     $DB_HOST"
echo "  Port:     $DB_PORT"
echo "  User:     $DB_USER"
echo "  Databases:"
echo "    eventstracker: $EVENTSTRACKER_DB"
echo "    runs-app:      $RUNSAPP_DB"
echo "    runs-ai:       $RUNSAI_DB"
echo ""
echo "Next Steps:"
echo "  1. Copy connection details from env/.env.prod to each application"
echo "     (or run each project's ./dev-up.sh --prod)"
echo "  2. Deploy your applications (or run locally pointing to prod)"
echo "  3. Test connections with:"
echo "       psql -h $DB_HOST -U $DB_USER -d $EVENTSTRACKER_DB"
echo "       psql -h $DB_HOST -U $DB_USER -d $RUNSAPP_DB"
echo "       psql -h $DB_HOST -U $DB_USER -d $RUNSAI_DB"
echo ""
echo "This is prod — it will NOT be torn down automatically. When you"
echo "actually want to destroy it and stop charges:"
echo "   ./scripts/prod/prod-stop.sh --destroy"
echo ""
echo "Cost: ~\$0.67/day while running"
