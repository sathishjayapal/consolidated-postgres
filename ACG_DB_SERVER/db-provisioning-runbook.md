# Runbook: Native PostgreSQL Server on the ACG Cloud Server

Goal: one PostgreSQL 17 instance on your ACG cloud server (Rocky/Alma/RHEL 8 or 9)
hosting all five project databases from your docker-compose — no Docker.
Script: `setup-pg-server.sh`. Box available until **Aug 2**.

## ACG facts that shape this setup

- Login is **`cloud_user`** + the password you set at first login (no .pem keys).
- **Port 5432 is already open** on ACG cloud servers — there is no security
  group to configure, and no way to close it. Your passwords ARE the firewall.
- The **public IP changes every restart** — always connect via the **public
  hostname** shown in the ACG server details panel; it survives restarts.
- The server **auto-stops 4 hours after each start**. Restart it from the ACG
  "Cloud Servers" page; PostgreSQL is enabled as a service and comes back
  automatically with the box.
- Expired/deleted servers are unrecoverable — dump your data out before Aug 2.

---

## Step 1 — Get your credentials ready (from Portainer on the old VM)

Portainer stack → **Environment** tab. Note these — reuse the same
users/passwords so your apps keep working:

| Database | User var | Password var |
|---|---|---|
| event-service | EVENTS_TRACKER_DB_USER | EVENTS_TRACKER_DB_PASSWORD |
| runsapp_db | RUNS_APP_DB_USER | RUNS_APP_DB_PASSWORD |
| runs_ai_analyzer_db | RUNS_AI_ANALYZER_DB_USER | RUNS_AI_ANALYZER_DB_PASSWORD |
| my-github-cleaner | GITHUB_CLEANER_DB_USER | GITHUB_CLEANER_DB_PASSWORD |
| dbcleaner | DBCLEANER_DB_USER | DBCLEANER_DB_PASSWORD |

If any password is weak, upgrade it now — 5432 is internet-facing on ACG.

## Step 2 — Create the credentials file (on your laptop)

Credentials live in `acg-db.env` next to the script — gitignored, never
committed. Copy `acg-db.env.example` → `acg-db.env` and fill in
(`dbname:user:password`, no colons in passwords):

```bash
PROJECT_DBS=(
  "event-service:eventstracker_local:MyRealPassword1"
  "runsapp_db:runsapp_local:MyRealPassword2"
  ...
)
```

The script sources this file automatically if it sits in the same directory.

Recommended: set `ALLOWED_CIDR` to your home IP, e.g. `"203.0.113.5/32"`
(check https://checkip.amazonaws.com). Since ACG's network firewall can't be
tightened, this pg_hba rule is your only IP-level restriction. If your home IP
changes often, leave `0.0.0.0/0` and rely on strong passwords.

## Step 3 — Copy the script to the server

From the ACG "Cloud Servers" page, expand your server → note the
**public hostname** and **credentials**.

```bash
scp setup-pg-server.sh acg-db.env cloud_user@<public-hostname>:~
```

Note the trailing `:~` — without it, scp creates a LOCAL file named
`cloud_user@<hostname>` instead of uploading.

(First-time login forces a password change — do that via `ssh` or the ACG
**Open Terminal** web console before scp will work. No scp from the web
console: if you only use the browser terminal, `nano setup-pg-server.sh`
and paste.)

## Step 4 — Run it

```bash
ssh cloud_user@<public-hostname>
sudo bash setup-pg-server.sh
```

~2–3 minutes. Idempotent — if it fails partway, fix and rerun.

**Expected ending:**

```
    OK: event-service as eventsuser
    OK: runsapp_db as runsuser
    OK: runs_ai_analyzer_db as runsaiuser
    OK: my-github-cleaner as ghcleaner
    OK: dbcleaner as dbcleaner
 pgvector 0.x.x
=========================================================
 Done. One server, port 5432, five databases.
```

## Step 5 — Test from your local machine

No firewall step needed — 5432 is pre-opened by ACG.

```bash
psql "host=<public-hostname> port=5432 dbname=event-service user=eventsuser" -c "SELECT version();"
```

Or IntelliJ/DBeaver: host `<public-hostname>`, port `5432`, DB name + user
per project.

## Step 6 — Point your local apps at it

Per-container ports collapse to one port + different DB names, and the host
is the persistent hostname (never the IP — it changes each restart):

| Old (VM/docker) | New (ACG native) |
|---|---|
| `jdbc:postgresql://<vm-ip>:6433/event-service` | `jdbc:postgresql://<public-hostname>:5432/event-service` |
| `jdbc:postgresql://<vm-ip>:5443/runsapp_db` | `jdbc:postgresql://<public-hostname>:5432/runsapp_db` |
| `jdbc:postgresql://<vm-ip>:5444/runs_ai_analyzer_db` | `jdbc:postgresql://<public-hostname>:5432/runs_ai_analyzer_db` |
| `jdbc:postgresql://<vm-ip>:5439/my-github-cleaner` | `jdbc:postgresql://<public-hostname>:5432/my-github-cleaner` |
| `jdbc:postgresql://<vm-ip>:5433/dbcleaner` | `jdbc:postgresql://<public-hostname>:5432/dbcleaner` |

Usernames/passwords unchanged (reused in Step 2).

## Step 7 — (Optional) migrate existing data from the VM

On the old VM, per database:

```bash
docker exec postgres            pg_dump -U $EVENTS_TRACKER_DB_USER event-service         > event-service.sql
docker exec runs-app-db         pg_dump -U $RUNS_APP_DB_USER runsapp_db                  > runsapp_db.sql
docker exec runs-ai-analyzer-db pg_dump -U $RUNS_AI_ANALYZER_DB_USER runs_ai_analyzer_db > runs_ai.sql
docker exec github-cleaner-db   pg_dump -U $GITHUB_CLEANER_DB_USER my-github-cleaner     > ghcleaner.sql
docker exec dbcleaner-db        pg_dump -U $DBCLEANER_DB_USER dbcleaner                  > dbcleaner.sql
```

Copy and restore (run the setup script FIRST — runs_ai needs the vector
extension in place):

```bash
scp *.sql cloud_user@<public-hostname>:~
ssh cloud_user@<public-hostname>
psql -h 127.0.0.1 -U eventsuser -d event-service       < event-service.sql
psql -h 127.0.0.1 -U runsuser   -d runsapp_db          < runsapp_db.sql
psql -h 127.0.0.1 -U runsaiuser -d runs_ai_analyzer_db < runs_ai.sql
psql -h 127.0.0.1 -U ghcleaner  -d my-github-cleaner   < ghcleaner.sql
psql -h 127.0.0.1 -U dbcleaner  -d dbcleaner           < dbcleaner.sql
```

## Step 8 — Daily reality: the 4-hour auto-stop

Every time you sit down to work: ACG **Cloud Servers** page → **Start Server**
(also resets the 14-day expiry). PostgreSQL starts with the box — nothing to
do on the server. Hostname stays the same; your app configs keep working.
Mid-session shutdowns kill open connections; Hikari pools in your Spring apps
will reconnect once you start the server again.

## Step 9 — Before Aug 2: dump everything off the box

```bash
ssh cloud_user@<public-hostname>
sudo -u postgres pg_dumpall > all-dbs-$(date +%F).sql
exit
scp cloud_user@<public-hostname>:~/all-dbs-*.sql .
```

Do this a day early. Watch the 4-hour window — a shutdown mid-scp truncates
the file.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Script: "Edit the passwords" | A `CHANGE_ME` is still in `PROJECT_DBS` |
| Script: "Targets Rocky/Alma/RHEL" | You picked a different distro — tell me which and I'll re-target |
| `connection timed out` from laptop | Server auto-stopped (4h) — start it from the ACG page |
| Connects via hostname but wrong server / refused | Stale DNS after restart — `dig <public-hostname>`, compare with panel IP, restart server if mismatched |
| `password authentication failed` | Mismatch between script values and app config |
| `FATAL: no pg_hba.conf entry` | Your IP isn't in `ALLOWED_CIDR` (home IP changed?) — edit `/var/lib/pgsql/17/data/pg_hba.conf`, then `sudo systemctl reload postgresql-17` |
| Web console stops working after enabling firewalld | Port 31297 must stay open — the script handles this if firewalld was active when it ran; otherwise `sudo firewall-cmd --add-port=31297/tcp --permanent && sudo firewall-cmd --reload` |
