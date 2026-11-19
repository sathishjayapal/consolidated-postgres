#!/usr/bin/env bats
# Tests for scripts/vm/runs-server-backup.sh with mocked runuser/docker/pg_restore/rsync.
# Nothing touches a real database: each mock writes canned output.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/vm/runs-server-backup.sh"

setup() {
  T="$(mktemp -d)"; MOCK="$T/bin"; mkdir -p "$MOCK"
  export BACKUP_ROOT="$T/backups" BACKUP_DATE=2026-11-18 BACKUP_DOW=3 OFFSITE_TARGET=""
  export MOCK_LOG="$T/calls.log"

  # runuser -u postgres -- <cmd...>: emulate psql / pg_dump / pg_dumpall
  cat > "$MOCK/runuser" <<'EOF'
#!/usr/bin/env bash
shift 3; echo "runuser $*" >> "$MOCK_LOG"
case $1 in
  psql)       printf 'dbcleaner\nevent-service\nlitellm\n' ;;
  pg_dumpall) echo "CREATE ROLE x;" ;;
  pg_dump)    db=${*: -1}; [[ $db == "${FAIL_DB:-}" ]] && exit 1; echo "PGDMP-$db" ;;
esac
EOF
  cat > "$MOCK/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$MOCK_LOG"
case "$*" in
  *export_definitions*) echo '{"rabbit_version":"3.13"}' ;;
  *pg_restore*)         grep -q PGDMP ;;
  *pg_dump*)            echo "PGDMP-pgvector" ;;
esac
EOF
  printf '#!/usr/bin/env bash\ngrep -q PGDMP "${@: -1}"\n' > "$MOCK/pg_restore"
  printf '#!/usr/bin/env bash\necho "rsync $*" >> "$MOCK_LOG"\n' > "$MOCK/rsync"
  chmod +x "$MOCK"/*
  export PATH="$MOCK:$PATH"
}
teardown() { rm -rf "$T"; }

@test "dumps every native DB, globals, pgvector and rabbitmq; writes checksums" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  d="$BACKUP_ROOT/daily/2026-11-18"
  for f in pg16-globals.sql pg16-dbcleaner.dump pg16-event-service.dump pg16-litellm.dump \
           pgvector-runs-ai-analyzer.dump rabbitmq-definitions.json SHA256SUMS STATUS; do
    [ -s "$d/$f" ] || { echo "missing $f"; false; }
  done
  ! ls "$d" | grep -q 'pg16-postgres'
  grep -q 'failures=0' "$d/STATUS"
  [[ "$output" == *"OFFSITE_TARGET not set"* ]]
}

@test "files are private (umask 077)" {
  run "$SCRIPT"
  [ "$(stat -c %a "$BACKUP_ROOT/daily/2026-11-18/pg16-litellm.dump")" = 600 ]
  [ "$(stat -c %a "$BACKUP_ROOT/daily/2026-11-18")" = 700 ]
}

@test "a failed DB dump fails the run, other DBs still dumped, no offsite push" {
  export FAIL_DB=event-service OFFSITE_TARGET="me@host:/b"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: pg_dump event-service"* ]]
  [ -s "$BACKUP_ROOT/daily/2026-11-18/pg16-litellm.dump" ]
  ! grep -q '^rsync' "$MOCK_LOG"
}

@test "an unreadable dump is renamed .bad and fails the run" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$MOCK/pg_restore"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ -e "$BACKUP_ROOT/daily/2026-11-18/pg16-dbcleaner.dump.bad" ]
}

@test "retention keeps 7 daily; Sunday copies to weekly and keeps 4" {
  for i in 01 02 03 04 05 06 07 08 09; do mkdir -p "$BACKUP_ROOT/daily/2026-11-$i" "$BACKUP_ROOT/weekly/2026-10-$i"; done
  export BACKUP_DOW=7
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(ls "$BACKUP_ROOT/daily" | wc -l)" -eq 7 ]
  [ -d "$BACKUP_ROOT/daily/2026-11-18" ]
  [ "$(ls "$BACKUP_ROOT/weekly" | wc -l)" -eq 4 ]
  [ -d "$BACKUP_ROOT/weekly/2026-11-18" ]
}

@test "rsync offsite runs when target set and run is clean" {
  export OFFSITE_TARGET="skminfotech@192.168.4.236:/srv/backups/runs-server"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "rsync -a --delete -e ssh -o BatchMode=yes -o ConnectTimeout=15 $BACKUP_ROOT/ skminfotech@192.168.4.236:/srv/backups/runs-server/" "$MOCK_LOG"
}

@test "rsync uses the dedicated key when OFFSITE_SSH_KEY is set" {
  export OFFSITE_TARGET="u@h:/b" OFFSITE_SSH_KEY=/root/.ssh/runs-server-backup
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- "-i /root/.ssh/runs-server-backup -o IdentitiesOnly=yes" "$MOCK_LOG"
}

@test "failed rsync fails the run" {
  printf '#!/usr/bin/env bash\nexit 12\n' > "$MOCK/rsync"
  export OFFSITE_TARGET="u@h:/b"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL: rsync to u@h:/b"* ]]
}
