#!/usr/bin/env bash
set -euo pipefail

#################################################################
# On-Demand Cloud Database Startup
#
# Usage: ./cloud-start.sh
#
# What it does:
#   1. Creates DigitalOcean PostgreSQL instance ($15/month cost)
#   2. Creates 3 databases: eventstracker_db, runsapp_db, runsai_db
#   3. Creates backup bucket in DigitalOcean Spaces
#   4. Generates cloud connection details to .env.cloud
#   5. Ready to connect from your local apps
#
# Cost: ~$0.50/day = ~$15/month if run continuously
# You control when this runs - only run when coding!
#
# Next steps:
#   1. Update application.yml in each project with .env.cloud details
#   2. Deploy your applications (or run locally pointing to cloud DB)
#   3. When done: ./cloud-stop.sh (exports data and destroys infrastructure)
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
print_info "Remember: Run ./cloud-stop.sh when done coding to stop charges!"
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

# Create .env.cloud file
print_section "Generating .env.cloud Configuration"

cat > .env.cloud << 'EOF'
# Cloud Database Configuration
# Generated by cloud-start.sh
# WARNING: Sensitive data - don't commit to git!

# DigitalOcean PostgreSQL Details
EOF

# Append configuration values safely (using printf to handle special characters)
{
  printf "DB_HOST=%s\n" "$DB_HOST"
  printf "DB_PORT=%s\n" "$DB_PORT"
  printf "DB_USERNAME=%s\n" "$DB_USER"
  printf "DB_PASSWORD=%s\n" "$DB_PASSWORD"
  printf "\n# eventstracker\n"
  printf "EVENTS_TRACKER_DB_URL=jdbc:postgresql://%s:%s/%s?sslmode=require\n" "$DB_HOST" "$DB_PORT" "$EVENTSTRACKER_DB"
  printf "EVENTS_TRACKER_DB_USER=%s\n" "$DB_USER"
  printf "EVENTS_TRACKER_DB_PASSWORD=%s\n" "$DB_PASSWORD"
  printf "\n# runs-app\n"
  printf "RUNSAPP_DATASOURCE_URL=jdbc:postgresql://%s:%s/%s?sslmode=require\n" "$DB_HOST" "$DB_PORT" "$RUNSAPP_DB"
  printf "RUNSAPP_DATASOURCE_USERNAME=%s\n" "$DB_USER"
  printf "RUNSAPP_DATASOURCE_PASSWORD=%s\n" "$DB_PASSWORD"
  printf "\n# runs-ai-analyzer\n"
  printf "RUNSAI_DATASOURCE_URL=jdbc:postgresql://%s:%s/%s?sslmode=require\n" "$DB_HOST" "$DB_PORT" "$RUNSAI_DB"
  printf "RUNSAI_DATASOURCE_USERNAME=%s\n" "$DB_USER"
  printf "RUNSAI_DATASOURCE_PASSWORD=%s\n" "$DB_PASSWORD"
  printf "\n# RabbitMQ (set explicitly if using managed broker)\n"
  printf "# RABBITMQ_HOST=\n"
  printf "# RABBITMQ_PORT=\n"
  printf "# RABBITMQ_USERNAME=\n"
  printf "# RABBITMQ_PASSWORD=\n"
  printf "\n# Generated at: $(date)\n"
  printf "# Cost: Approximately \$0.67/day while infrastructure is running\n"
  printf "# Action: Run ./cloud-stop.sh to stop charges and export data\n"
} >> .env.cloud

print_status "Created .env.cloud"
print_info "Copy connection details from above to your applications"

# Create reminder file
cat > .CLOUD_STATUS << EOF
🌥️  CLOUD INFRASTRUCTURE ACTIVE
Created: $(date)
Cost: ~\$0.67/day = ~\$20/month if always running

TO STOP INFRASTRUCTURE & SAVE MONEY:
  ./cloud-stop.sh

This will:
  1. Export all data to DigitalOcean Spaces
  2. Destroy the database (stop charges immediately)
  3. Keep backups for recovery

⏰ Don't forget to run ./cloud-stop.sh when done coding!
EOF

print_status "Status file: .CLOUD_STATUS"

# Summary
print_section "✅ Cloud Infrastructure Ready"

echo "Your cloud database is now active!"
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
echo "  1. Copy connection details from .env.cloud to each application"
echo "  2. Deploy your applications (or run locally pointing to cloud)"
echo "  3. Test connections with:"
echo "       psql -h $DB_HOST -U $DB_USER -d $EVENTSTRACKER_DB"
echo "       psql -h $DB_HOST -U $DB_USER -d $RUNSAPP_DB"
echo "       psql -h $DB_HOST -U $DB_USER -d $RUNSAI_DB"
echo ""
echo "⏰ IMPORTANT: When done coding, run:"
echo "   ./cloud-stop.sh"
echo ""
echo "This will:"
echo "  • Export all data to DigitalOcean Spaces"
echo "  • Destroy the database (stop \$20/month charges)"
echo "  • Keep backups for later recovery"
echo ""
echo "Cost: ~\$0.67/day while running"
echo "Savings: Only pay for time you actually use!"
