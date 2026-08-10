#!/usr/bin/env bash
set -uo pipefail

#################################################################
# check-cred-drift.sh — read-only credential drift auditor
#
# For each project it compares THREE credential sources and reports
# where they disagree:
#   1. golden      : consolidated-postgres/env/.env.local (intended source of truth)
#   2. project .env: the value the app actually loads (EnvFile plugin)
#   3. VM (live)   : whether that project-.env credential authenticates
#                    against the VM database / RabbitMQ right now
#
# It NEVER writes anything and never prints secret values — only
# MATCH/DIFFERS/OK/FAIL. Complements check-stack-consistency.sh
# (which checks VM role drift); this one also covers the golden source
# and RabbitMQ.
#
# Usage: ./check-cred-drift.sh
# Requires: psql, curl (tests are skipped gracefully if absent/unreachable).
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
GOLDEN="$REPO_ROOT/env/.env.local"
VM_ENV="$REPO_ROOT/env/vm.env"

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[1;34m'; NC='\033[0m'

val() { # val <file> <key>  -> value (last wins), empty if absent
  [ -f "$1" ] || { echo ""; return; }
  grep -E "^$2=" "$1" 2>/dev/null | tail -n1 | cut -d= -f2-
}
have() { command -v "$1" >/dev/null 2>&1; }

MGMT_PORT=15672
[ -f "$VM_ENV" ] && VM_IP="$(val "$VM_ENV" VM_IP)" || VM_IP=""

# project | env_file(rel) | db_url_key | db_user_key | db_pass_key | golden_user_key | golden_pass_key
ROWS=(
 "eventstracker|eventstracker/.env|EVENTS_TRACKER_DB_URL|EVENTS_TRACKER_DB_USER|EVENTS_TRACKER_DB_PASSWORD|EVENTS_TRACKER_DB_USER|EVENTS_TRACKER_DB_PASSWORD"
 "runs-app|runs-app/.env|JDBC_DATABASE_URL|JDBC_DATABASE_USERNAME|JDBC_DATABASE_PASSWORD|RUNS_APP_DB_USER|RUNS_APP_DB_PASSWORD"
 "runs-ai-analyzer|runs-ai-analyzer/.env|RUNS_AI_ANALYZER_DB_URL|RUNS_AI_ANALYZER_DB_USER|RUNS_AI_ANALYZER_DB_PASSWORD|RUNS_AI_ANALYZER_DB_USER|RUNS_AI_ANALYZER_DB_PASSWORD"
 "dbcleaner|dbcleaner/.env|JDBC_DATABASE_URL|JDBC_DATABASE_USERNAME|JDBC_DATABASE_PASSWORD||"
 "verbose-barnacle|verbose-barnacle/.env|GITHUB_CLEANER_DB_URL|GITHUB_CLEANER_DB_USER|GITHUB_CLEANER_DB_PASSWORD||"
 "sathish-projects-logger|sathish-projects-logger/.env|DATABASE_URL|DATABASE_USERNAME|DATABASE_PASSWORD||"
)

echo -e "${B}== Credential drift audit ==${NC}   golden: env/.env.local   VM: ${VM_IP:-<unknown>}"
echo ""
printf "%-24s %-16s %-14s %-16s %s\n" "PROJECT" "DB-USER" "vs-GOLDEN" "VM-DB-AUTH" "URL-HOST"
printf '%.0s-' {1..92}; echo ""

for r in "${ROWS[@]}"; do
  IFS='|' read -r proj envrel uk_url uk_user uk_pass gk_user gk_pass <<<"$r"
  ef="$WORKSPACE_ROOT/$envrel"
  url=$(val "$ef" "$uk_url"); user=$(val "$ef" "$uk_user"); pass=$(val "$ef" "$uk_pass")
  [ -z "$url$user" ] && { printf "%-24s %s\n" "$proj" "(no .env / keys)"; continue; }
  host=$(sed -E 's#.*://([^:/]+).*#\1#' <<<"$url")
  port=$(sed -E 's#.*://[^:]+:([0-9]+)/.*#\1#' <<<"$url"); [[ "$port" =~ ^[0-9]+$ ]] || port=5432
  db=$(sed -E 's#.*/([^/?]+).*#\1#' <<<"$url")

  # golden comparison
  gcmp="(no golden)"
  if [ -n "$gk_user" ]; then
    gu=$(val "$GOLDEN" "$gk_user"); gp=$(val "$GOLDEN" "$gk_pass")
    if [ "$user" = "$gu" ] && [ "$pass" = "$gp" ]; then gcmp="MATCH"
    elif [ "$user" = "$gu" ]; then gcmp="PASS-DIFF"
    else gcmp="USER+PASS-DIFF"; fi
  fi

  # live VM auth (only if URL points at the VM and psql present)
  auth="skip"
  if have psql && [ -n "$host" ]; then
    if PGPASSWORD="$pass" psql -h "$host" -p "$port" -U "$user" -d "$db" -tAc 'select 1' >/dev/null 2>&1; then auth="OK"
    else auth="FAIL"; fi
  fi
  col() { case "$1" in OK|MATCH) echo -e "${G}$1${NC}";; FAIL|USER+PASS-DIFF) echo -e "${R}$1${NC}";; PASS-DIFF) echo -e "${Y}$1${NC}";; *) echo "$1";; esac; }
  printf "%-24s %-16s %-25s %-27s %s\n" "$proj" "$user" "$(col "$gcmp")" "$(col "$auth")" "$host:$port"
done

echo ""
echo -e "${B}== RabbitMQ (VM mgmt API $VM_IP:$MGMT_PORT) ==${NC}"
printf "%-24s %-14s %-10s %s\n" "PROJECT" "MQ-USER" "VM-AUTH" "vs-GOLDEN(rabbit_local)"
printf '%.0s-' {1..70}; echo ""
gmqu=$(val "$GOLDEN" RABBITMQ_USERNAME); gmqp=$(val "$GOLDEN" RABBITMQ_PASSWORD)
for envrel in eventstracker/.env runs-app/.env runs-ai-analyzer/.env verbose-barnacle/.env; do
  ef="$WORKSPACE_ROOT/$envrel"; proj=$(dirname "$envrel")
  mu=$(val "$ef" RABBITMQ_USERNAME); mp=$(val "$ef" RABBITMQ_PASSWORD); mh=$(val "$ef" RABBITMQ_HOST)
  [ -z "$mu" ] && continue
  a="skip"
  if have curl && [ -n "$mh" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$mu:$mp" --max-time 8 "http://$mh:$MGMT_PORT/api/whoami" 2>/dev/null)
    [ "$code" = "200" ] && a="OK" || a="FAIL($code)"
  fi
  gc=$([ "$mu" = "$gmqu" ] && [ "$mp" = "$gmqp" ] && echo "MATCH" || echo "DIFFERS")
  printf "%-24s %-14s %-10s %s\n" "$proj" "$mu" "$a" "$gc"
done
echo ""
echo "Legend: MATCH/OK = consistent · PASS-DIFF = same user, golden password stale · USER+PASS-DIFF = both differ · FAIL = does not authenticate against VM"
