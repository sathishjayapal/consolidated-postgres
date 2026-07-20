# VM Database Workflow (VirtualBox + Portainer)

Run persisted PostgreSQL databases for your projects on the VirtualBox VM, managed from your Mac with one command.

```
Your Mac                                    VirtualBox VM (bridged, own LAN IP)
────────                                    ───────────────────────────────────
scripts/vm/vm-db-up.sh <projects...>        Portainer :9000
  1. regenerates the managed block in         └── sathish-stack
     docker-compose-vm.yml         ├── postgres            :6433  (eventstracker, always on)
  2. syncs each project's own compose port          ├── runs-app-db         :5443  (when selected)
  3. points project .env at the VM                  ├── runs-ai-analyzer-db :5444  (when selected, pgvector)
  4. PUTs the stack via the Portainer API           └── … config-server, rabbitmq, apps, watchtower
                                              Data in named volumes → survives restarts/redeploys
```

## One-time setup

```bash
cd consolidated-postgres
cp vm.env.example vm.env    # fill in VM_IP, Portainer API key, endpoint ID
```

Create the API key in Portainer: user icon → My account → Access tokens.

Each project you select must have a local `.env` (run its `dev-up.sh` once) — the script reads DB user/password from
there and pushes them into the Portainer stack environment, so credentials stay identical between local and VM.

## Usage

```bash
# Bring up runs-app + runs-ai-analyzer DBs on the VM (eventstracker DB is always included)
./scripts/vm/vm-db-up.sh runs-app runs-ai-analyzer

# Preview without deploying (also skips Portainer, works without vm.env)
./scripts/vm/vm-db-up.sh --dry-run runs-app

# Update stack but leave project .env files alone
./scripts/vm/vm-db-up.sh --no-env runs-app

# Point project .env back at localhost (local dev) while still syncing the stack
./scripts/vm/vm-db-up.sh --target local runs-app

# Remove DB services you deselected from the VM (data volumes are kept)
./scripts/vm/vm-db-up.sh --prune runs-app
```

## Port / database map (VM and local use the same ports)

| Project          | Port | Database              | VM volume                  |
|------------------|------|-----------------------|----------------------------|
| eventstracker    | 6433 | `event-service`       | `pg_data_eventstracker`    |
| runs-app         | 5443 | `runsapp_db`          | `pg_data_runs_app`         |
| runs-ai-analyzer | 5444 | `runs_ai_analyzer_db` | `pg_data_runs_ai_analyzer` |
| verbose-barnacle | 5439 | `my-github-cleaner`   | `pg_data_github_cleaner`   |
| dbcleaner        | 5433 | `dbcleaner`           | `pg_data_dbcleaner`        |

verbose-barnacle and dbcleaner have no `dev-up.sh`, so the local multi-dev scripts skip them; their credentials fall
back to the defaults hardcoded in their own docker-compose files (add a `.env` to override). Both are also provisioned
by the ACG scripts (`acg-start.sh`, `acg-aws-start.sh`) with dumps taken on teardown.

Connect from the Mac: `psql -h <VM_IP> -p <port> -U <user> -d <database>`

## What gets edited where

| File                                                                                | What changes                                                                                                                          |
|-------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `docker-compose-vm.yml`                                            | Only the text between `# >>> PROJECT-DBS:START/END` and `# >>> PROJECT-DB-VOLUMES:START/END` markers — never edit inside them by hand |
| Selected project's `docker-compose.yml` (eventstracker → `jubilant-memory/config/`) | Host-port mapping kept in sync with `project-config.sh`                                                                               |
| Selected project's `.env`                                                           | The JDBC URL key is rewritten to `jdbc:postgresql://<VM_IP or localhost>:<port>/<db>`; a `.env.bak` backup is made first              |

## Notes & gotchas

- **eventstracker DB service is named `postgres`** in the VM stack — the eventstracker app container there resolves its
  DB at hostname `postgres`. Don't rename it.
- **Persistence**: each DB has its own named volume mounted at the image's real data dir (`/var/lib/postgresql` for
  postgres 18+, `/var/lib/postgresql/data`
  otherwise). `--prune` removes containers, never volumes.
- **Migration from the old stack**: the old shared `postgres_data` volume (db
  `eventstracker`, user `eventstracker`) is left untouched. The new eventstracker DB initializes fresh as
  `event-service` on `pg_data_eventstracker`. To carry data over: `pg_dump` from the old container before redeploying,
  restore with
  `psql -h <VM_IP> -p 6433`.
- **Adding a project**: add it to `projects.txt` and add its metadata cases to
  `scripts/lib/project-config.sh` (`get_project_db_image`, `get_project_pg_mount`,
  `get_project_db_service`, `get_project_vm_volume`, `get_project_db_name_key`,
  `get_project_db_user_key`, `get_project_db_url_key` plus the existing ones).
- **Stack env vars**: the script merges DB credentials into the existing Portainer stack env — `GIT_URI`, `RABBITMQ_*`,
  etc. are preserved. If the stack doesn't exist yet, create it once via the Portainer UI (see
  `docs/PORTAINER-SETUP.md`)
  so those base vars get set.
