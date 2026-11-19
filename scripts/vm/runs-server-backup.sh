#!/usr/bin/env bash
# runs-server-backup.sh — nightly backup of the data on runs-server that can't be rebuilt.
#
#   native Postgres 16   one pg_dump -Fc per database (found at run time, so new
#                        databases are included automatically) + globals (roles)
#   pgvector (pg17)      pg_dump -Fc inside sathish-stack-runs-ai-analyzer-db,
#                        using the container's own POSTGRES_USER/POSTGRES_DB
#   RabbitMQ             definitions export (users, vhosts, queues, bindings).
#                        In-flight messages are not backed up.
#   NOT backed up        Loki (logs, rebuildable), Docker images, LiteLLM venv.
#
# Every dump is checked with `pg_restore --list` before it counts as good.
# Retention: KEEP_DAILY daily sets; Sunday's set is also copied to weekly/,
# keeping KEEP_WEEKLY. Exits non-zero if anything failed, so systemd marks the
# unit failed.
#
# Config (optional): /etc/default/runs-server-backup
#   BACKUP_ROOT=/var/backups/runs-server
#   KEEP_DAILY=7  KEEP_WEEKLY=4
#   OFFSITE_TARGET=            # empty = local only (warns)
#                              # rsync:  user@host:/path
#   OFFSITE_SSH_KEY=           # rsync only: key for the target (root runs this job)
#                              # rclone: rclone:remote:path
#
# Install and restore steps: docs/RUNS_SERVER_HOST.md
set -uo pipefail

BACKUP_ROOT=${BACKUP_ROOT:-/var/backups/runs-server}
KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-4}
OFFSITE_TARGET=${OFFSITE_TARGET:-}
OFFSITE_SSH_KEY=${OFFSITE_SSH_KEY:-}
PGVECTOR_CONTAINER=${PGVECTOR_CONTAINER:-sathish-stack-runs-ai-analyzer-db}
RABBITMQ_CONTAINER=${RABBITMQ_CONTAINER:-sathish-stack-rabbitmq}
TODAY=${BACKUP_DATE:-$(date +%F)}
DOW=${BACKUP_DOW:-$(date +%u)}   # 7 = Sunday

failures=0
log()  { printf '%s %s\n' "$(date +%T)" "$*"; }
fail() { log "FAIL: $*"; failures=$((failures + 1)); }

as_postgres() { runuser -u postgres -- "$@"; }

# A dump is good if it's non-empty and pg_restore can read its table of contents.
check_dump() {
  local f=$1
  if [[ -s $f ]] && pg_restore --list "$f" >/dev/null 2>&1; then
    log "ok   $(basename "$f") ($(du -h "$f" | cut -f1))"
  else
    fail "$(basename "$f") is empty or unreadable"
    mv -f "$f" "$f.bad" 2>/dev/null
  fi
}

umask 077
dest="$BACKUP_ROOT/daily/$TODAY"
mkdir -p "$dest" || { log "FAIL: cannot create $dest"; exit 1; }
log "backup to $dest"

# ── native Postgres 16 ──────────────────────────────────────────────────────
if as_postgres pg_dumpall --globals-only > "$dest/pg16-globals.sql" 2>"$dest/pg16-globals.err" \
   && [[ -s $dest/pg16-globals.sql ]]; then
  log "ok   pg16-globals.sql"; rm -f "$dest/pg16-globals.err"
else
  fail "pg_dumpall --globals-only (see pg16-globals.err)"
fi

mapfile -t dbs < <(as_postgres psql -XAtc \
  "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1")
[[ ${#dbs[@]} -gt 0 ]] || fail "no databases found on native Postgres 16"
for db in "${dbs[@]}"; do
  f="$dest/pg16-$db.dump"
  if as_postgres pg_dump -Fc -d "$db" > "$f" 2>"$f.err"; then
    rm -f "$f.err"; check_dump "$f"
  else
    fail "pg_dump $db (see $(basename "$f").err)"
  fi
done

# ── pgvector container ──────────────────────────────────────────────────────
f="$dest/pgvector-runs-ai-analyzer.dump"
if docker exec "$PGVECTOR_CONTAINER" sh -c 'pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
     > "$f" 2>"$f.err"; then
  rm -f "$f.err"
  # pg17 dump: read the TOC with the container's pg_restore, not the host's v16.
  if [[ -s $f ]] && docker exec -i "$PGVECTOR_CONTAINER" pg_restore --list < "$f" >/dev/null 2>&1; then
    log "ok   $(basename "$f") ($(du -h "$f" | cut -f1))"
  else
    fail "$(basename "$f") is empty or unreadable"; mv -f "$f" "$f.bad"
  fi
else
  fail "pg_dump in $PGVECTOR_CONTAINER (see $(basename "$f").err)"
fi

# ── RabbitMQ definitions ────────────────────────────────────────────────────
f="$dest/rabbitmq-definitions.json"
if docker exec "$RABBITMQ_CONTAINER" rabbitmqctl -q export_definitions - --format json \
     > "$f" 2>"$f.err" && grep -q '"rabbit_version"' "$f"; then
  rm -f "$f.err"; log "ok   rabbitmq-definitions.json"
else
  fail "rabbitmq export_definitions (see $(basename "$f").err)"
fi

(cd "$dest" && sha256sum -- * > SHA256SUMS 2>/dev/null)
printf 'failures=%d\nfinished=%s\n' "$failures" "$(date -Is)" > "$dest/STATUS"

# ── retention ───────────────────────────────────────────────────────────────
if [[ $DOW == 7 && $failures -eq 0 ]]; then
  mkdir -p "$BACKUP_ROOT/weekly"
  rm -rf "$BACKUP_ROOT/weekly/$TODAY"
  cp -a "$dest" "$BACKUP_ROOT/weekly/$TODAY" && log "weekly copy kept"
fi
prune() {  # keep the newest $2 dated directories in $1
  local dir=$1 keep=$2
  [[ -d $dir ]] || return 0
  ls -1d "$dir"/????-??-?? 2>/dev/null | sort | head -n -"$keep" | while read -r old; do
    rm -rf -- "$old" && log "pruned $old"
  done
}
prune "$BACKUP_ROOT/daily" "$KEEP_DAILY"
prune "$BACKUP_ROOT/weekly" "$KEEP_WEEKLY"

# ── offsite ─────────────────────────────────────────────────────────────────
# rsync/rclone mirror with deletes, so never push a run that had failures.
if [[ $failures -gt 0 && -n $OFFSITE_TARGET ]]; then
  log "WARN: skipping offsite sync because this run had failures"
  OFFSITE_TARGET=skip
fi
case $OFFSITE_TARGET in
  skip)     ;;
  "")       log "WARN: OFFSITE_TARGET not set — backups are on runs-server only" ;;
  rclone:*) rclone sync "$BACKUP_ROOT" "${OFFSITE_TARGET#rclone:}" \
              && log "offsite ok (rclone)" || fail "rclone sync to ${OFFSITE_TARGET#rclone:}" ;;
  *)        ssh_cmd="ssh -o BatchMode=yes -o ConnectTimeout=15"
            [[ -n $OFFSITE_SSH_KEY ]] && ssh_cmd+=" -i $OFFSITE_SSH_KEY -o IdentitiesOnly=yes"
            rsync -a --delete -e "$ssh_cmd" "$BACKUP_ROOT/" "$OFFSITE_TARGET/" \
              && log "offsite ok (rsync)" || fail "rsync to $OFFSITE_TARGET" ;;
esac

log "done, failures=$failures"
[[ $failures -eq 0 ]]
