#!/usr/bin/env bash
set -euo pipefail

#################################################################
# Prod Database Backup / Teardown (DigitalOcean, persistent)
#
# Usage: ./scripts/prod/prod-stop.sh [--destroy]
#
# What it does:
#   1. Exports all data from PostgreSQL to local backup (always)
#   2. Creates timestamped backup file (e.g., backup-2026-03-22-1130.sql)
#   3. Only with --destroy: destroys DigitalOcean infrastructure (stops all
#      charges). Without --destroy, this is backup-only — the infrastructure
#      keeps running. "prod" is persistent by design; --destroy is the
#      explicit opt-in for actually tearing it down.
#   4. Keeps local backup for recovery
#
# Cost Impact: --destroy stops ~$0.67/day charges immediately
# Data Safety: All data exported before any deletion
#
# Recovery: ./scripts/prod/prod-start.sh && psql < backup-2026-03-22-1130.sql
#################################################################

DESTROY=false
for arg in "$@"; do
  case "$arg" in
    --destroy) DESTROY=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_PROD="$REPO_ROOT/env/.env.prod"
PROD_STATUS_FILE="$REPO_ROOT/.PROD_STATUS"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
ORANGE='\033[0;33m'
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

print_warning() {
  echo -e "${ORANGE}⚠${NC} $1"
}

print_section() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

if $DESTROY; then
  print_section "🚨 Prod Database Backup + Destroy"
  print_warning "This will DESTROY prod infrastructure and stop all charges"
  print_warning "Data will be EXPORTED first (safe to delete)"
  echo ""
  echo "This action:"
  echo "  • Exports all data from PostgreSQL to local backup"
  echo "  • Deletes the PostgreSQL instance (stops \$0.67/day charges)"
  echo "  • Keeps exported data files for recovery"
  echo ""

  read -p "Are you sure? Type 'yes' to continue: " -r CONFIRM
  if [[ ! $CONFIRM == "yes" ]]; then
    print_error "Cancelled - infrastructure still running"
    exit 0
  fi
else
  print_section "Prod Database Backup (no --destroy — infrastructure stays up)"
  print_info "Exporting a backup only. Infrastructure will keep running and costing money."
  print_info "Pass --destroy if you actually want to tear it down."
  echo ""
fi

# Check if prod is actually running
if [ ! -f "terraform.tfstate" ]; then
  print_warning "Prod infrastructure doesn't appear to be running"
  print_info "No terraform state found - nothing to back up or destroy"
  exit 0
fi

# Load connection details from terraform
print_section "Step 1: Loading Connection Details"

DB_HOST=$(terraform output -raw database_host 2>/dev/null || echo "")
DB_PORT=$(terraform output -raw database_port 2>/dev/null || echo "")
# Use admin credentials from DigitalOcean cluster (not the custom devuser)
DB_USERNAME=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "digitalocean_database_cluster") | .values.user' || echo "")
DB_PASSWORD=$(terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type == "digitalocean_database_cluster") | .values.password' || echo "")
# Default to eventstracker_db (primary database)
EVENTSTRACKER_DB=$(terraform output -raw eventstracker_db_name 2>/dev/null || echo "eventstracker_db")

if [ -z "$DB_HOST" ] || [ -z "$DB_USERNAME" ] || [ -z "$DB_PASSWORD" ]; then
  print_error "Could not retrieve database connection details"
  print_info "Terraform state may be corrupted. You may need to manually destroy with:"
  echo "  terraform destroy -var-file='terraform.tfvars'"
  exit 1
fi

print_status "Database: $DB_HOST:$DB_PORT / $EVENTSTRACKER_DB"
print_info "Using admin user: $DB_USERNAME"

# Create backup directory if it doesn't exist
BACKUP_DIR="$REPO_ROOT/backups"
mkdir -p "$BACKUP_DIR"

# Export data with timestamp
print_section "Step 2: Exporting Data from PostgreSQL"

TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BACKUP_FILE="$BACKUP_DIR/backup-$TIMESTAMP.sql"

print_info "Exporting to: $BACKUP_FILE"
print_info "This may take 1-2 minutes..."

# Check if pg_dump is available
if ! command -v pg_dump &> /dev/null; then
  print_error "pg_dump command not found"
  echo "Install PostgreSQL client tools:"
  echo "  macOS:     brew install postgresql"
  echo "  Ubuntu:    sudo apt-get install postgresql-client"
  echo "  Or download from: https://www.postgresql.org/download/"
  exit 1
fi

print_info "Attempting to export data..."
print_info "Connecting to: $DB_HOST:$DB_PORT / $EVENTSTRACKER_DB"

# Export using pg_dump with password
# PGSSLMODE=require is needed for DigitalOcean managed databases
if PGPASSWORD="$DB_PASSWORD" PGSSLMODE=require pg_dump \
  -h "$DB_HOST" \
  -p "$DB_PORT" \
  -U "$DB_USERNAME" \
  -d "$EVENTSTRACKER_DB" \
  --verbose \
  --no-privileges \
  > "$BACKUP_FILE" 2>&1; then
  print_status "Data exported successfully"
  print_info "Backup file: $(ls -lh $BACKUP_FILE | awk '{print $5, $NF}')"
else
  print_error "pg_dump failed. Diagnose with:"
  echo ""
  echo "  1. Test connection with SSL (required for DigitalOcean):"
  echo "     PGSSLMODE=require psql -h $DB_HOST -p $DB_PORT -U $DB_USERNAME -d $EVENTSTRACKER_DB"
  echo "     (password: $(echo $DB_PASSWORD | sed 's/./*/g'))"
  echo ""
  echo "  2. Check if PostgreSQL client tools are installed:"
  echo "     psql --version"
  echo ""
  echo "  3. Check network connectivity:"
  echo "     ping $DB_HOST"
  echo ""
  exit 1
fi

# Create manifest of what was backed up
cat > "$BACKUP_DIR/manifest-$TIMESTAMP.txt" << EOF
PostgreSQL Backup Manifest
Created: $(date)

Database: $EVENTSTRACKER_DB
Host: $DB_HOST
Port: $DB_PORT
User: $DB_USERNAME

Backup File: $BACKUP_FILE
Size: $(ls -lh $BACKUP_FILE 2>/dev/null | awk '{print $5}' || echo "unknown")

To restore:
  ./scripts/prod/prod-start.sh  # Recreate infrastructure
  psql -h \$HOST -U \$USER -d \$DATABASE < $BACKUP_FILE

Files in this backup:
EOF

# Count tables in backup
if command -v pg_restore &> /dev/null && file "$BACKUP_FILE" | grep -q "PostgreSQL custom format"; then
  pg_restore --list "$BACKUP_FILE" 2>/dev/null | grep "TABLE" >> "$BACKUP_DIR/manifest-$TIMESTAMP.txt" || true
fi

print_status "Backup manifest created"

# Local backup saved
print_section "Step 3: Backup Summary"

print_status "Local backup created: $BACKUP_FILE"
print_info "This backup is stored locally for recovery"
print_info "If needed, restore with:"
echo "  ./scripts/prod/prod-start.sh"
echo "  psql -h \$HOST -U \$USER -d \$DATABASE < $BACKUP_FILE"

if ! $DESTROY; then
  print_section "✅ Backup Complete — Infrastructure Still Running"
  echo "Summary:"
  echo "  • Prod database backed up, NOT destroyed (no --destroy passed)"
  echo "  • Data backed up to: $BACKUP_FILE"
  echo "  • Manifest created: $BACKUP_DIR/manifest-$TIMESTAMP.txt"
  echo ""
  echo "To actually tear down and stop charges:"
  echo "  ./scripts/prod/prod-stop.sh --destroy"
  exit 0
fi

# Destroy infrastructure
print_section "Step 4: Destroying Prod Infrastructure (Takes 1-2 minutes)"

print_warning "Destroying DigitalOcean resources..."
print_info "(This takes 1-2 minutes)"
echo ""

terraform destroy -var-file="terraform.tfvars" -auto-approve

print_status "Prod infrastructure destroyed"
print_status "All charges stopped immediately"

# Verify destruction
if [ -f "terraform.tfstate" ]; then
  # Check if resources still exist
  RESOURCE_COUNT=$(grep -c "digitalocean_database" terraform.tfstate || echo "0")
  if [ "$RESOURCE_COUNT" -eq "0" ]; then
    print_status "All prod resources removed"
  fi
fi

# Cleanup
print_section "Step 5: Cleanup"

rm -f "$PROD_STATUS_FILE"
rm -f "$ENV_PROD"

print_status "Removed env/.env.prod and status files"

# Summary
print_section "✅ Prod Infrastructure Shutdown Complete"

echo "Summary:"
echo "  • Prod database destroyed"
echo "  • All charges stopped"
echo "  • Data backed up to: $BACKUP_FILE"
echo "  • Manifest created: $BACKUP_DIR/manifest-$TIMESTAMP.txt"
echo ""
echo "To restore later:"
echo "  1. ./prod-start.sh (recreates infrastructure)"
echo "  2. psql -h \$HOST -U \$USER -d \$DATABASE < $BACKUP_FILE"
echo ""
echo "💰 Cost Savings:"
echo "  Stopped paying: \$0.67/day × 30 days = \$20/month"
echo "  You only paid for actual usage time"
echo ""
echo "Files saved:"
ls -lh "$BACKUP_DIR" | tail -n +2 | awk '{printf "  %s (%s)\n", $NF, $5}'
