# Runbook: Native PostgreSQL + RabbitMQ on the ACG Cloud Server

Goal: one PostgreSQL 17 instance (five project databases) **and** a native
RabbitMQ broker on your ACG cloud server (Rocky/Alma/RHEL 8 or 9), plus the
app stack (config-server, eventstracker, sathishlogger, dbcleaner, watchtower)
via Docker/Portainer. Script: `setup-pg-server.sh`. Compose:
`docker-compose.acg.yml`. Box available until **Aug 2**.

## ACG facts that shape this setup

- Login is **`cloud_user`** + the password you set at first login (no .pem keys).
- ACG has a **fixed port allowlist** you cannot change. Everything below is
  mapped into it; your passwords are the real firewall.
- The **public IP changes every restart** — always use the **public hostname**
  from the ACG server details panel; it survives restarts.
- The server **auto-stops 4 hours after each start**. Restart from the ACG
  page; PostgreSQL, RabbitMQ (and Docker, if enabled) come back automatically.
- Expired/deleted servers are unrecoverable — dump data out before Aug 2.

## Port map (all within ACG's allowlist)

| Service | Native port | Reach from laptop |
|---|---|---|
| PostgreSQL (all 5 DBs) | 5432 | `<hostname>:5432` (allowlisted as-is) |
| RabbitMQ AMQP (containers/local) | 5672 | — not allowlisted; box-internal only |
| RabbitMQ AMQP (external) | 61613 | `<hostname>:61613` (plain AMQP on an allowlisted port) |
| RabbitMQ management UI | 8082 | `http://<hostname>:8082` (15672 not allowlisted) |
| Portainer UI | 8443→9443 | `https://<hostname>:8443` (9443 not allowlisted) |
| config-server | 8088→8888 | `http://<hostname>:8088` |
| sathishlogger | 8090→8080 | `http://<hostname>:8090` |
| eventstracker | 9091→9081 | `http://<hostname>:9091` |
| dbcleaner | 8085 | `http://<hostname>:8085` |

---

## Step 1 — Credentials file

`acg-db.env` sits next to the script — gitignored, never committed. Copy
`acg-db.env.example` → `acg-db.env` and fill in. It now covers **both**
PostgreSQL and RabbitMQ:

```bash
PROJECT_DBS=(                       # dbname:user:password — no colons in passwords
  "event-service:eventstracker_local:MyRealPassword1"
  "runsapp_db:runsapp_local:MyRealPassword2"
  ...
)
PGVECTOR_DBS=("runs_ai_analyzer_db")
ALLOWED_CIDR="0.0.0.0/0"            # tighten to your home IP /32 if it's stable
RABBITMQ_USER="..."                 # must match RABBITMQ_DEFAULT_USER in the compose env
RABBITMQ_PASSWORD="..."             # must match RABBITMQ_DEFAULT_PASS
```

The script sources this file automatically from its own directory.

## Step 2 — Copy script + creds to the server

```bash
scp setup-pg-server.sh acg-db.env cloud_user@<public-hostname>:~
```

Note the trailing `:~` — without it, scp creates a LOCAL file named
`cloud_user@<hostname>` instead of uploading.

## Step 3 — Run it

```bash
ssh cloud_user@<public-hostname>
sudo bash setup-pg-server.sh
```

~3–5 minutes. Idempotent — safe to rerun after a failure or to apply script
updates; completed steps are skipped or refreshed harmlessly.

What it does: installs PostgreSQL 17 + pgvector (PGDG repo), creates the five
DBs/roles, configures remote access with scram auth (plus a pg_hba rule for
Docker's 172.16.0.0/12 so containers can reach it), then installs RabbitMQ
from the official repos (arch **and noarch** sections — the server rpm is
noarch), pins the node name to `rabbit@localhost` (ACG images don't resolve
the short hostname, which otherwise kills startup with an `epmd_error`),
configures listeners 5672 + 61613 and the management UI on 8082, creates
your admin user, and removes `guest`.

**Expected ending:**

```
    OK: event-service as eventstracker_local
    OK: runsapp_db as runsapp_local
    OK: runs_ai_analyzer_db as runsai_local
    OK: my-github-cleaner as githubcleaner_local
    OK: dbcleaner as dbcleaner_local
 pgvector 0.x.x
    OK: rabbitmq broker up (user: ...)
```

## Step 4 — Test from your laptop

```bash
psql "host=<public-hostname> port=5432 dbname=event-service user=eventstracker_local" -c "SELECT version();"
```

RabbitMQ management UI: `http://<public-hostname>:8082` — log in with
RABBITMQ_USER. AMQP from local Java apps: host `<public-hostname>`,
port `61613` (plain AMQP; only the port number is unusual).

## Step 5 — App connection strings

| What | Value |
|---|---|
| JDBC (laptop) | `jdbc:postgresql://<public-hostname>:5432/<dbname>` |
| JDBC (containers on the box) | `jdbc:postgresql://host.docker.internal:5432/<dbname>` |
| AMQP (laptop) | `<public-hostname>:61613` |
| AMQP (containers on the box) | `host.docker.internal:5672` |

DB names: `event-service`, `runsapp_db`, `runs_ai_analyzer_db`,
`my-github-cleaner`, `dbcleaner`. Users/passwords per `acg-db.env`.

## Step 6 — App stack via Docker/Portainer (docker-compose.acg.yml)

Install Docker (Rocky/Alma/RHEL use Docker's CE repo — unlike AL2023):

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker cloud_user
```

**⚠️ REQUIRED before any `docker` command:** the group change above does NOT
apply to your current shell. Log out and ssh back in (or run `newgrp docker`).
Skipping this gives `permission denied ... /var/run/docker.sock` on every
docker command. Verify with:

```bash
docker ps    # must work WITHOUT sudo before continuing
```

Portainer — published on **8443** (9443 is not ACG-allowlisted):

```bash
docker volume create portainer_data
docker run -d --name portainer --restart=always \
  -p 8443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data portainer/portainer-ce:latest
```

Open `https://<public-hostname>:8443` (self-signed cert — accept), set the
admin password **within 5 minutes** (else `docker restart portainer`).

Deploy the stack: **Stacks → Add stack → Web editor**, paste
`docker-compose.acg.yml`, then under **Environment variables** add:

```
DOCKERHUB_TOKEN, GIT_URI, ENCRYPT_KEY,
CONFIG_SERVER_USERNAME, CONFIG_SERVER_PASSWORD,
EVENTS_TRACKER_DB_NAME/_USER/_PASSWORD,
RUNS_APP_DB_NAME/_USER/_PASSWORD,
RUNS_AI_ANALYZER_DB_NAME/_USER/_PASSWORD,
DBCLEANER_DB_NAME/_USER/_PASSWORD,
RABBITMQ_DEFAULT_USER, RABBITMQ_DEFAULT_PASS,   # = RABBITMQ_USER/PASSWORD from acg-db.env
EVENT_DOMAIN_USER, EVENT_DOMAIN_USER_PASSWORD
```

The compose has **no database or rabbitmq containers** — apps reach the
native services via `host.docker.internal`. (CLI alternative: put the vars
in a `.env` next to the compose and `docker compose -f docker-compose.acg.yml up -d`.)

## Step 7 — (Optional) migrate existing data from the old VM

Dump per DB on the VM (`docker exec <db-container> pg_dump -U <user> <db> > x.sql`),
copy over, restore on the ACG box (`psql -h 127.0.0.1 -U <user> -d <db> < x.sql`).
Run the setup script FIRST — `runs_ai_analyzer_db` needs the vector extension
in place before restore.

## Step 8 — Daily reality: the 4-hour auto-stop

Each work session: ACG page → **Start Server** (also resets the 14-day
expiry). PostgreSQL, RabbitMQ, Docker + containers all come back on boot.
Hostname is stable, so no config changes. Spring/Hikari pools on your laptop
reconnect once the box is up.

## Step 9 — Before Aug 2: get everything off the box

```bash
ssh cloud_user@<public-hostname>
sudo -u postgres pg_dumpall > all-dbs-$(date +%F).sql
sudo rabbitmqctl export_definitions ~/rabbit-definitions.json
exit
scp "cloud_user@<public-hostname>:~/all-dbs-*.sql" .
scp cloud_user@<public-hostname>:rabbit-definitions.json .
```

Do this a day early, and mind the 4-hour window mid-transfer.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Script: "Edit the passwords" / "Set RABBITMQ_USER..." | `acg-db.env` missing or still has CHANGE_ME |
| `Unable to find a match: rabbitmq-server` | Old script version — rabbitmq-server is noarch and needs the noarch repo sections. Rerun the current script (it rewrites `rabbitmq.repo`); if it persists: `sudo dnf clean all` and rerun |
| rabbitmq-server fails: `{epmd_error,"<shortname>",timeout}` | ACG's /etc/hosts maps only the FQDN, so the short hostname doesn't resolve. Rerun the current script (writes `NODENAME=rabbit@localhost` to `/etc/rabbitmq/rabbitmq-env.conf`), or add that line manually and `sudo systemctl restart rabbitmq-server` |
| `connection timed out` from laptop | Server auto-stopped (4h) — start it from the ACG page |
| Hostname resolves to wrong IP after restart | Stale DNS — `dig <public-hostname>`, compare with panel; restart server if mismatched |
| `FATAL: no pg_hba.conf entry` | Your IP isn't in `ALLOWED_CIDR` — edit `/var/lib/pgsql/17/data/pg_hba.conf`, `sudo systemctl reload postgresql-17` |
| Containers can't reach PG/RabbitMQ | `extra_hosts` missing, or pg_hba lacks the 172.16.0.0/12 rule (rerun script) |
| RabbitMQ mgmt UI unreachable | It's on **8082**, not 15672; check `sudo ss -ltn \| grep 8082` and `sudo rabbitmqctl status` |
| `permission denied ... /var/run/docker.sock` | docker group membership not active in this shell — log out/in or `newgrp docker` (one-off: prefix the command with `sudo`) |
| Portainer UI unreachable | Must be published as `-p 8443:9443`; 9443 is not ACG-allowlisted |
| Portainer "timed out for security" | `docker restart portainer`, set admin password immediately |
