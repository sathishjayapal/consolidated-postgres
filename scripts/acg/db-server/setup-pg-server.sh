#!/usr/bin/env bash
# setup-pg-server.sh — native PostgreSQL 17 + RabbitMQ on an ACG cloud server
# (Rocky / Alma / RHEL 8 or 9 — auto-detected) hosting ALL project databases
# from the sathish-stack docker-compose:
#   event-service, runsapp_db, runs_ai_analyzer_db (pgvector),
#   my-github-cleaner, dbcleaner
# plus a native RabbitMQ broker (management plugin enabled).
#
# ACG port allowlist notes:
#   PostgreSQL 5432  — allowlisted, reachable from your laptop as-is
#   AMQP 5672        — NOT allowlisted: containers/local only
#   AMQP 61613       — extra listener on an allowlisted port for laptop access
#   Mgmt UI 8082     — 15672 is NOT allowlisted; UI moved into 8000-8100 range
#
# Usage: put credentials in acg-db.env next to this script, then:
#   sudo bash setup-pg-server.sh
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
RABBITMQ_USER="${RABBITMQ_USER:-CHANGE_ME}"
RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-CHANGE_ME}"
RABBITMQ_MGMT_PORT="${RABBITMQ_MGMT_PORT:-8082}"   # 8000-8100 is ACG-allowlisted
RABBITMQ_EXT_AMQP_PORT="${RABBITMQ_EXT_AMQP_PORT:-61613}"  # allowlisted AMQP for laptop
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
[[ "$RABBITMQ_USER$RABBITMQ_PASSWORD" != *CHANGE_ME* ]] || { echo "Set RABBITMQ_USER/RABBITMQ_PASSWORD in acg-db.env"; exit 1; }
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
  echo "==> firewalld active: opening PG, RabbitMQ + 31297 (ACG web console)"
  for p in 5432 5672 "$RABBITMQ_EXT_AMQP_PORT" "$RABBITMQ_MGMT_PORT" 31297; do
    firewall-cmd -q --permanent --add-port="${p}/tcp"
  done
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

### ===== RabbitMQ (official repos — Erlang + server) ====================
# NOTE: rabbitmq-server is a NOARCH rpm and lives in separate .../noarch
# repo paths — both the $ARCH and noarch sections are required, otherwise
# dnf reports "Unable to find a match: rabbitmq-server".
echo "==> Installing RabbitMQ"
rpm --import 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc'
rpm --import 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key'
rpm --import 'https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key'
cat > /etc/yum.repos.d/rabbitmq.repo <<EOF
[modern-erlang]
name=modern-erlang-el${EL}
baseurl=https://yum1.rabbitmq.com/erlang/el/${EL}/${ARCH}
        https://yum2.rabbitmq.com/erlang/el/${EL}/${ARCH}
repo_gpgcheck=0
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
gpgcheck=1

[modern-erlang-noarch]
name=modern-erlang-el${EL}-noarch
baseurl=https://yum1.rabbitmq.com/erlang/el/${EL}/noarch
        https://yum2.rabbitmq.com/erlang/el/${EL}/noarch
repo_gpgcheck=0
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1

[rabbitmq-server]
name=rabbitmq-el${EL}
baseurl=https://yum1.rabbitmq.com/rabbitmq/el/${EL}/${ARCH}
        https://yum2.rabbitmq.com/rabbitmq/el/${EL}/${ARCH}
repo_gpgcheck=0
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1

[rabbitmq-server-noarch]
name=rabbitmq-el${EL}-noarch
baseurl=https://yum1.rabbitmq.com/rabbitmq/el/${EL}/noarch
        https://yum2.rabbitmq.com/rabbitmq/el/${EL}/noarch
repo_gpgcheck=0
enabled=1
gpgkey=https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key
       https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
gpgcheck=1
EOF
dnf clean metadata -q >/dev/null 2>&1 || true
dnf install -y -q logrotate erlang rabbitmq-server

echo "==> Configuring RabbitMQ (ACG port remaps)"
mkdir -p /etc/rabbitmq
# ACG images map only the FQDN in /etc/hosts; the short hostname doesn't
# resolve, which kills startup with {epmd_error,"<shortname>",timeout}.
# Pin the node name to localhost — correct for a single-node broker and
# immune to ACG hostname quirks across restarts.
cat > /etc/rabbitmq/rabbitmq-env.conf <<'EOF'
NODENAME=rabbit@localhost
EOF
cat > /etc/rabbitmq/rabbitmq.conf <<EOF
# AMQP for containers/local processes on this box (NOT reachable from internet on ACG)
listeners.tcp.local    = 0.0.0.0:5672
# AMQP on an ACG-allowlisted port for connections from your laptop
listeners.tcp.external = 0.0.0.0:${RABBITMQ_EXT_AMQP_PORT}
# Management UI — 15672 is not ACG-allowlisted, use ${RABBITMQ_MGMT_PORT}
management.tcp.ip   = 0.0.0.0
management.tcp.port = ${RABBITMQ_MGMT_PORT}
loopback_users = none
EOF
rabbitmq-plugins enable --offline rabbitmq_management >/dev/null
systemctl enable --now rabbitmq-server
# wait for broker
for i in {1..30}; do rabbitmqctl -q ping >/dev/null 2>&1 && break; sleep 2; done
rabbitmqctl -q ping || { echo "RabbitMQ did not come up"; journalctl -u rabbitmq-server -n 20 --no-pager; exit 1; }

echo "==> Creating RabbitMQ user"
if rabbitmqctl -q list_users | awk '{print $1}' | grep -qx "$RABBITMQ_USER"; then
  rabbitmqctl -q change_password "$RABBITMQ_USER" "$RABBITMQ_PASSWORD"
else
  rabbitmqctl -q add_user "$RABBITMQ_USER" "$RABBITMQ_PASSWORD"
fi
rabbitmqctl -q set_user_tags "$RABBITMQ_USER" administrator
rabbitmqctl -q set_permissions -p / "$RABBITMQ_USER" ".*" ".*" ".*"
# remove default guest account (only ever worked on localhost, but be tidy)
rabbitmqctl -q list_users | awk '{print $1}' | grep -qx guest && rabbitmqctl -q delete_user guest || true

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
rabbitmqctl -q ping && echo "    OK: rabbitmq broker up (user: $RABBITMQ_USER)"
ss -ltn | grep -E ":(5432|5672|${RABBITMQ_EXT_AMQP_PORT}|${RABBITMQ_MGMT_PORT}) " || true

HOSTNAME_MSG=$(hostname -f 2>/dev/null || hostname)
cat <<EOF

=========================================================
 Done. PostgreSQL (5 DBs) + RabbitMQ, all native.

 IMPORTANT (ACG): the public IP changes on EVERY server
 restart. Use the server's PUBLIC HOSTNAME from the ACG
 "Cloud Servers" details panel:

 PostgreSQL (5432 is ACG-allowlisted):
   jdbc:postgresql://<public-hostname>:5432/event-service
   jdbc:postgresql://<public-hostname>:5432/runsapp_db
   jdbc:postgresql://<public-hostname>:5432/runs_ai_analyzer_db
   jdbc:postgresql://<public-hostname>:5432/my-github-cleaner
   jdbc:postgresql://<public-hostname>:5432/dbcleaner

 RabbitMQ:
   from containers on this box:  host.docker.internal:5672
   from your laptop (AMQP):      <public-hostname>:${RABBITMQ_EXT_AMQP_PORT}
   management UI:                http://<public-hostname>:${RABBITMQ_MGMT_PORT}
   (5672/15672 are NOT in ACG's allowlist — hence the remaps)

 These ports are open to the whole internet on ACG.
 Keep passwords strong; tighten ALLOWED_CIDR if possible.
 (This box reports hostname: $HOSTNAME_MSG — use the one
 shown in the ACG panel, not this.)
=========================================================
EOF
