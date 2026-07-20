#!/usr/bin/env bash
# setup-pg-server.sh — native PostgreSQL 17 server on an ACG cloud server
# (Rocky / Alma / RHEL 8 or 9 — auto-detected) hosting ALL project databases
# from the sathish-stack docker-compose:
#   event-service, runsapp_db, runs_ai_analyzer_db (pgvector),
#   my-github-cleaner, dbcleaner
#
# One PG instance, port 5432 (already allowlisted on ACG cloud servers),
# one DB + one role per project.
# Usage: edit CONFIG below, then:  sudo bash setup-pg-server.sh
set -euo pipefail

### ---- CONFIG ----------------------------------------------------------
# Credentials live in acg-db.env NEXT TO THIS SCRIPT (gitignored — never
# commit real passwords). Copy acg-db.env.example → acg-db.env and fill in.
# Format: dbname:user:password  (no colons in passwords)
# NOTE: port 5432 on ACG servers is open to the ENTIRE internet and you
# cannot change that — use long random passwords, not dictionary words.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/acg-db.env" ] && source "$SCRIPT_DIR/acg-db.env"

if [ -z "${PROJECT_DBS+x}" ]; then
  PROJECT_DBS=(
    "event-service:eventstracker_local:CHANGE_ME"
    "runsapp_db:runsapp_local:CHANGE_ME"
    "runs_ai_analyzer_db:runsai_local:CHANGE_ME"
    "my-github-cleaner:githubcleaner_local:CHANGE_ME"
    "dbcleaner:dbcleaner_local:CHANGE_ME"
  )
fi
[ -z "${PGVECTOR_DBS+x}" ] && PGVECTOR_DBS=("runs_ai_analyzer_db")
# STRONGLY recommended on ACG: set to your home IP /32 (see checkip.amazonaws.com).
# This is your only network-level filter — there is no security group you control.
ALLOWED_CIDR="${ALLOWED_CIDR:-0.0.0.0/0}"
PGMAJOR="${PGMAJOR:-17}"
### ----------------------------------------------------------------------

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
source /etc/os-release
case "$ID" in rocky|almalinux|rhel|centos) ;; *) echo "Targets Rocky/Alma/RHEL, got: $ID"; exit 1;; esac
EL=$(rpm -E %rhel)   # 8 or 9
[[ "$EL" =~ ^(8|9)$ ]] || { echo "Unsupported EL version: $EL"; exit 1; }
for entry in "${PROJECT_DBS[@]}"; do
  [[ "$entry" != *CHANGE_ME* ]] || { echo "Edit the passwords in PROJECT_DBS first"; exit 1; }
done
ARCH=$(uname -m)

### ===== PGDG repo + PostgreSQL 17 + pgvector ===========================
echo "==> Adding PGDG repo (EL${EL}/${ARCH}) and installing PostgreSQL ${PGMAJOR}"
rpm -q pgdg-redhat-repo >/dev/null 2>&1 || \
  dnf install -y -q "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${EL}-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm"
dnf -qy module disable postgresql 2>/dev/null || true   # EL built-in stream conflicts with PGDG
dnf install -y -q "postgresql${PGMAJOR}-server" "postgresql${PGMAJOR}-contrib" "pgvector_${PGMAJOR}"

PGDATA="/var/lib/pgsql/${PGMAJOR}/data"
SVC="postgresql-${PGMAJOR}"
[ -f "$PGDATA/PG_VERSION" ] || "/usr/pgsql-${PGMAJOR}/bin/postgresql-${PGMAJOR}-setup" initdb

### ===== Remote access + auth ==========================================
sed -ri "s/^#?listen_addresses.*/listen_addresses = '*'/"                 "$PGDATA/postgresql.conf"
sed -ri "s/^#?password_encryption.*/password_encryption = scram-sha-256/" "$PGDATA/postgresql.conf"
grep -q "$ALLOWED_CIDR" "$PGDATA/pg_hba.conf" || \
  echo "host    all    all    $ALLOWED_CIDR    scram-sha-256" >> "$PGDATA/pg_hba.conf"
# Docker bridge networks (containers on this host reach native PG via host-gateway)
grep -q "172.16.0.0/12" "$PGDATA/pg_hba.conf" || \
  echo "host    all    all    172.16.0.0/12    scram-sha-256" >> "$PGDATA/pg_hba.conf"

systemctl enable --now "$SVC"
systemctl restart "$SVC"

### ===== Host firewall (if running) =====================================
if systemctl is-active --quiet firewalld; then
  echo "==> firewalld active: opening 5432 + 31297 (ACG web console)"
  firewall-cmd -q --permanent --add-port=5432/tcp
  firewall-cmd -q --permanent --add-port=31297/tcp
  firewall-cmd -q --reload
fi

### ===== Create roles + databases (idempotent) ==========================
echo "==> Creating project roles and databases"
for entry in "${PROJECT_DBS[@]}"; do
  IFS=: read -r dbname dbuser dbpass <<< "$entry"
  echo "    -> $dbname (owner: $dbuser)"
  sudo -u postgres psql -v ON_ERROR_STOP=1 \
       -v u="$dbuser" -v p="$dbpass" -v d="$dbname" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'u', :'p')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'u') \gexec
SELECT format('ALTER ROLE %I PASSWORD %L', :'u', :'p') \gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'d', :'u')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'d') \gexec
SQL
done

### ===== pgvector extension =============================================
for db in "${PGVECTOR_DBS[@]}"; do
  sudo -u postgres psql -d "$db" -c "CREATE EXTENSION IF NOT EXISTS vector;"
done

### ===== Verify =========================================================
echo "==> Verifying"
PSQL="/usr/pgsql-${PGMAJOR}/bin/psql"
for entry in "${PROJECT_DBS[@]}"; do
  IFS=: read -r dbname dbuser dbpass <<< "$entry"
  PGPASSWORD="$dbpass" "$PSQL" -h 127.0.0.1 -U "$dbuser" -d "$dbname" -tAc "SELECT current_database()" >/dev/null \
    && echo "    OK: $dbname as $dbuser"
done
sudo -u postgres psql -d "${PGVECTOR_DBS[0]:-postgres}" -tAc \
  "SELECT 'pgvector '||extversion FROM pg_extension WHERE extname='vector'" || true

HOSTNAME_MSG=$(hostname -f 2>/dev/null || hostname)
cat <<EOF

=========================================================
 Done. One server, port 5432, five databases.

 IMPORTANT (ACG): the public IP changes on EVERY server
 restart. Use the server's PUBLIC HOSTNAME from the ACG
 "Cloud Servers" details panel in your JDBC URLs:

   jdbc:postgresql://<public-hostname>:5432/event-service
   jdbc:postgresql://<public-hostname>:5432/runsapp_db
   jdbc:postgresql://<public-hostname>:5432/runs_ai_analyzer_db
   jdbc:postgresql://<public-hostname>:5432/my-github-cleaner
   jdbc:postgresql://<public-hostname>:5432/dbcleaner

 Port 5432 is already open on ACG — no firewall step
 needed, but that means the whole internet can reach it.
 Keep passwords strong; tighten ALLOWED_CIDR if possible.
 (This box reports hostname: $HOSTNAME_MSG — use the one
 shown in the ACG panel, not this.)
=========================================================
EOF
