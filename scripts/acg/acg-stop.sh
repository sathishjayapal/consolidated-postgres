#!/usr/bin/env bash
set -euo pipefail

#################################################################
# ACG Azure Sandbox — PostgreSQL Teardown
#
# Usage: ./scripts/acg/acg-stop.sh
#
# What it does:
#   1. Dumps all 3 databases to timestamped backup files
#   2. Runs terraform destroy (targeting PostgreSQL module only)
#   3. Cleans up env/.env.cloud and status marker
#
# Run this BEFORE your ACG sandbox session expires to save data.
# Backups are written to ./backups/acg-YYYY-MM-DD-HHMM/
#
# Recovery:
#   ./acg-start.sh                          # recreate infrastructure
#   psql <connection> < backups/<file>.sql  # restore each database
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IAC_DIR="$(cd "$REPO_ROOT/../iAC-NikeRuns" && pwd)"
TFVARS_FILE="$REPO_ROOT/env/acg.tfvars"
ENV_CLOUD="$REPO_ROOT/env/.env.cloud"
ACG_STATUS_FILE="$REPO_ROOT/.ACG_STATUS"

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

print_section "ACG Azure PostgreSQL — Teardown"
print_warning "This will EXPORT data and DESTROY the cloud database."
echo ""
read -p "Type 'yes' to continue: " -r CONFIRM
[[ "$CONFIRM" == "yes" ]] || { print_error "Cancelled."; exit 0; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! command -v pg_dump &>/dev/null; then
  print_error "pg_dump not found. Install PostgreSQL client tools:"
  echo "  macOS:  brew install libpq && brew link --force libpq"
  echo "  Ubuntu: sudo apt-get install postgresql-client"
  exit 1
fi

if [ ! -f "$TFVARS_FILE" ]; then
  print_error "acg.tfvars not found — run scripts/acg/acg-start.sh first"
  exit 1
fi

# ── Load connection details from Terraform state ──────────────────────────────
print_section "Loading Connection Details"

cd "$IAC_DIR"

PG_HOST=$(terraform output -raw pg_host 2>/dev/null || echo "")
PG_PORT=$(terraform output -raw pg_port 2>/dev/null || echo "5432")
PG_USER=$(terraform output -raw pg_admin_user 2>/dev/null || echo "")
PG_PASS=$(terraform output -raw pg_admin_password 2>/dev/null || echo "")
DB_ET=$(terraform output -raw db_name_eventstracker 2>/dev/null || echo "event-service")
DB_RA=$(terraform output -raw db_name_runsapp 2>/dev/null || echo "runsapp_db")
DB_AI=$(terraform output -raw db_name_runsai 2>/dev/null || echo "runs_ai_analyzer_db")
DB_GC=$(terraform output -raw db_name_githubcleaner 2>/dev/null || echo "my-github-cleaner")
DB_DC=$(terraform output -raw db_name_dbcleaner 2>/dev/null || echo "dbcleaner")

if [ -z "$PG_HOST" ] || [ -z "$PG_USER" ] || [ -z "$PG_PASS" ]; then
  print_error "Cannot read Terraform outputs. Infrastructure may already be destroyed."
  print_info  "Attempting destroy anyway..."
  terraform destroy \
    -var-file="$TFVARS_FILE" \
    -target=module.flexipostgresmodule \
    -input=false \
    -auto-approve || true
  rm -f "$ENV_CLOUD" "$ACG_STATUS_FILE"
  exit 0
fi

print_status "Host: $PG_HOST:$PG_PORT"
print_status "Databases: $DB_ET | $DB_RA | $DB_AI | $DB_GC | $DB_DC"

# ── Export ────────────────────────────────────────────────────────────────────
print_section "Exporting Data (Step 1/3)"

TIMESTAMP=$(date +%Y-%m-%d-%H%M)
BACKUP_DIR="$REPO_ROOT/backups/acg-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

dump_db() {
  local db_name="$1"
  local label="$2"
  local backup_file="$BACKUP_DIR/${label}.sql"
  print_info "Dumping $db_name → $backup_file ..."
  if PGPASSWORD="$PG_PASS" PGSSLMODE=require pg_dump \
      -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db_name" \
      --no-privileges --no-owner \
      -f "$backup_file" 2>/tmp/pgdump_err; then
    local size
    size=$(du -sh "$backup_file" | awk '{print $1}')
    print_status "$label: $size"
  else
    print_warning "pg_dump failed for $db_name (may be empty or inaccessible):"
    cat /tmp/pgdump_err | head -5
    print_info "Continuing — empty backup written."
  fi
}

dump_db "$DB_ET" "eventstracker"
dump_db "$DB_RA" "runsapp"
dump_db "$DB_AI" "runsai"
dump_db "$DB_GC" "githubcleaner"
dump_db "$DB_DC" "dbcleaner"

# Write restore instructions
cat > "$BACKUP_DIR/RESTORE.md" << EOF
# ACG Database Backup — $TIMESTAMP

## Databases backed up
- eventstracker.sql  → event-service
- runsapp.sql        → runsapp_db
- runsai.sql         → runs_ai_analyzer_db
- githubcleaner.sql  → my-github-cleaner
- dbcleaner.sql      → dbcleaner

## To restore
1. \`./scripts/acg/acg-start.sh\`  — recreate infrastructure
2. Load host/password from env/.env.cloud
3. Restore each database:
\`\`\`bash
PGPASSWORD=\$PG_PASS psql -h \$PG_HOST -p \$PG_PORT -U \$PG_USER -d event-service < eventstracker.sql
PGPASSWORD=\$PG_PASS psql -h \$PG_HOST -p \$PG_PORT -U \$PG_USER -d runsapp_db    < runsapp.sql
PGPASSWORD=\$PG_PASS psql -h \$PG_HOST -p \$PG_PORT -U \$PG_USER -d runs_ai_analyzer_db < runsai.sql
PGPASSWORD=\$PG_PASS psql -h \$PG_HOST -p \$PG_PORT -U \$PG_USER -d "my-github-cleaner" < githubcleaner.sql
PGPASSWORD=\$PG_PASS psql -h \$PG_HOST -p \$PG_PORT -U \$PG_USER -d dbcleaner < dbcleaner.sql
\`\`\`
Note: runs-ai-analyzer Flyway migrations enable the vector extension.
Run the Spring app once before restoring runsai.sql if the extension isn't present.
EOF

print_status "Backup complete: $BACKUP_DIR"

# ── Destroy ───────────────────────────────────────────────────────────────────
print_section "Destroying Azure Resources (Step 2/3)"

terraform destroy \
  -var-file="$TFVARS_FILE" \
  -target=module.flexipostgresmodule \
  -input=false \
  -auto-approve

print_status "PostgreSQL Flexible Server destroyed — charges stopped."

# ── Cleanup ───────────────────────────────────────────────────────────────────
print_section "Cleanup (Step 3/3)"

rm -f "$ENV_CLOUD" "$ACG_STATUS_FILE"
print_status "env/.env.cloud and status files removed"

# Restore project .env files to localhost defaults so local dev still works
restore_local_env() {
  local project="$1"
  local env_file
  if [ -d "$HOME/IdeaProjects/$project" ]; then
    env_file="$HOME/IdeaProjects/$project/.env"
  else
    env_file="$(cd "$REPO_ROOT/.." && pwd)/$project/.env"
  fi
  shift
  [ -f "$env_file" ] || return
  while [ "$#" -gt 0 ]; do
    local kv="$1"; shift
    local key="${kv%%=*}"
    local val="${kv#*=}"
    if grep -qE "^${key}=" "$env_file" 2>/dev/null; then
      sed -i.bak "s|^${key}=.*|${key}=${val}|" "$env_file"
      rm -f "${env_file}.bak"
    fi
  done
  print_status "$project .env reset to local defaults"
}

print_info "Resetting project .env files back to local Docker defaults..."
restore_local_env "eventstracker" \
  "EVENTS_TRACKER_DB_URL=jdbc:postgresql://localhost:6433/event-service"

restore_local_env "runs-app" \
  "JDBC_DATABASE_URL=jdbc:postgresql://localhost:5443/runsapp_db"

restore_local_env "runs-ai-analyzer" \
  "RUNS_AI_ANALYZER_DB_URL=jdbc:postgresql://localhost:5444/runs_ai_analyzer_db"

# ── Summary ───────────────────────────────────────────────────────────────────
print_section "Teardown Complete"

echo "  Backups saved: $BACKUP_DIR"
echo ""
ls -lh "$BACKUP_DIR" | tail -n +2 | awk '{printf "  %s (%s)\n", $NF, $5}'
echo ""
echo "  Project .env files reset to local Docker defaults."
echo ""
echo "To resume with ACG:"
echo "  1. Start a new ACG lab session"
echo "  2. Update acg.tfvars with the new subscription_id, tenant_id, rg_name"
echo "  3. ./scripts/acg/acg-start.sh"
echo "  4. Restore data if needed (see $BACKUP_DIR/RESTORE.md)"
