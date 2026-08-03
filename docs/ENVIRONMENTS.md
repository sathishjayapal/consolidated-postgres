# Environment & Deployment Map

This repo orchestrates the same set of project databases across four named
profiles: **local**, **vm**, **acg**, **prod**. This doc explains which one to
use when, and what env file / script drives each.

## 1. Decision tree

```
Where do I need the databases?
│
├─► On my Mac, no persistence needed         →  local (multi-dev-up.sh)
│
├─► On my local VirtualBox VM, persisted      →  vm (vm-db-up.sh)
│   with web UI + auto-redeploy via Watchtower
│
├─► On a temporary ACG cloud sandbox          →  acg
│   ├─ Azure ACG  → scripts/acg/acg-start.sh / scripts/acg/acg-stop.sh
│   └─ AWS ACG    → scripts/acg/acg-aws-start.sh / scripts/acg/acg-aws-stop.sh
│
└─► Persistent, real infrastructure           →  prod (scripts/prod/prod-start.sh)
```

| Profile | Use | Persistent? | Cost |
|------|-----|-------------|------|
| local | `scripts/local/multi-dev-up.sh` | Optional Docker volumes | Free |
| vm | `scripts/vm/vm-db-up.sh` + Portainer | Named volumes on VM | Free |
| acg (Azure) | `scripts/acg/acg-start.sh` / `scripts/acg/acg-stop.sh` | Until sandbox expires | ACG included |
| acg (AWS) | `scripts/acg/acg-aws-start.sh` / `scripts/acg/acg-aws-stop.sh` | Until sandbox expires | ACG included |
| prod (DigitalOcean) | `scripts/prod/prod-start.sh` / `scripts/prod/prod-stop.sh` | Persistent — **not** torn down unless you pass `--destroy` | ~$0.67/day while running |

## 2. File map

| File | What it controls | Who consumes it |
|------|------------------|-----------------|
| `env/.env.local` | Golden local-dev credentials (DB users/passwords + RabbitMQ) — moved here from `jubilant-memory/config/.env` | `compose/docker-compose-local.yml`, each project's `dev-up.sh`, `scripts/local/*` |
| `env/.env.local.example` | Template for `env/.env.local` | Human reference / copy source |
| `compose/docker-compose-local.yml` | Shared local infra: eventstracker/runs-app/runs-ai-analyzer/mytracker DBs + RabbitMQ (+ optional gotoaws-sathish mongodb) | Local dev — `dev-up.sh` per project, `scripts/local/*` |
| `env/vm.env` | How `vm-db-up.sh` talks to Portainer: URL, API key, endpoint ID, stack name | `scripts/vm/vm-db-up.sh` only |
| `env/.env.vm` | The **stack environment variables** pushed into Portainer for `compose/docker-compose-vm.yml` | `scripts/vm/vm-db-up.sh` → Portainer stack |
| `env/.env.vm.example` | Complete template for `env/.env.vm` with every required key | Human reference / copy source |
| `env/.env.acg` | Generated DB connection strings after an ACG sandbox (Azure or AWS) comes up | Local Spring Boot apps in `--acg` mode |
| `env/.env.acg.example` | Template for `env/.env.acg` | Human reference |
| `env/.env.prod` | Generated DB connection strings for the persistent DigitalOcean prod instance | Local Spring Boot apps in `--prod` mode |
| `env/.env.prod.example` | Template for `env/.env.prod` | Human reference |
| `compose/docker-compose-vm.yml` | The Portainer stack definition (DBs + RabbitMQ + apps + Watchtower) | Portainer (never run directly with `docker compose up`) |
| `scripts/acg/db-server/docker-compose.acg.yml` | ACG AWS variant: native PG/RabbitMQ + app containers | Docker Compose on the ACG EC2 host |
| `acg.tfvars` | Azure ACG sandbox credentials | `scripts/acg/acg-start.sh` |
| `terraform.tfvars` | DigitalOcean API token | `scripts/prod/prod-start.sh` / `scripts/prod/prod-stop.sh` |

**`env/.env.acg` and `env/.env.prod` used to be one shared file (`env/.env.cloud`)** —
whichever of the three writer scripts (Azure ACG, AWS ACG, or DigitalOcean prod)
ran most recently silently clobbered the others' credentials, and `--cloud` mode
in each project's `dev-up.sh` only ever matched one of the three writers' key
naming. They're now separate files with one shared naming authority — see
[project-config.sh](../scripts/lib/project-config.sh)'s `get_project_db_url_key`
/ `get_project_db_user_env_key` / `get_project_env_password_key`, which every
writer (ACG, prod) and every project's `dev-up.sh --acg`/`--prod` now use.

**Naming rule of thumb:**
- `*.env` (no leading dot) = connection config for a **script**.
- `.*.env` or `.env.*` (leading dot) = **runtime environment** passed to apps/containers.

## 3. Local Docker

```bash
cd consolidated-postgres
./scripts/local/multi-dev-up.sh
./scripts/local/multi-dev-verify.sh
```

- Golden credentials + the shared compose file live in `env/.env.local` and
  `compose/docker-compose-local.yml` — `cp env/.env.local.example env/.env.local`
  once, then each project's `dev-up.sh` reads from it and writes its own local `.env`.
  Rotate with `scripts/local/rotate-creds.sh`.
- No `env/vm.env` or `env/.env.vm` is involved.
- Use `--acg` or `--prod` (on a project's `dev-up.sh`) to point apps at a
  running ACG sandbox or the prod DB instead of local containers.

## 4. VM Portainer

```bash
cp env/vm.env.example env/vm.env          # fill VM_IP, API key, endpoint ID
cp env/.env.vm.example env/.env.vm        # fill secrets and DB credentials
./scripts/vm/vm-db-up.sh runs-app runs-ai-analyzer
```

What happens:
1. `env/vm.env` tells the script where Portainer lives.
2. `env/.env.vm` becomes the **base** stack env in Portainer.
3. DB credentials are merged in from each selected project's local `.env`.
4. The managed block in `compose/docker-compose-vm.yml` is regenerated and pushed to Portainer.

Common mistake: opening `compose/docker-compose-vm.yml` and running `docker compose up` on
your Mac. That file is meant for Portainer inside the VM; it publishes fixed host
ports that conflict with local containers and expects the VM's network.

**Important**: `vm-db-up.sh` only manages the *containers*, never named volumes
(`--prune` removes containers, not volumes — data is safe by design). If a
project's local password is rotated (e.g. `env/.env.local` changes via
`scripts/local/rotate-creds.sh`) and you redeploy, Postgres will happily keep
running under its *old* role — `POSTGRES_USER`/`PASSWORD` only apply the first
time a volume initializes. Run `scripts/vm/check-stack-consistency.sh --roles`
after any credential rotation to catch this before it blocks you.

## 5. ACG temporary cloud

### Azure ACG (`scripts/acg/acg-start.sh`)

- Provisions an Azure PostgreSQL Flexible Server in the sandbox resource group.
- Writes `env/.env.acg` and updates project `.env` files with ACG JDBC URLs.
- No Portainer or VM is involved; apps run locally against the ACG DB.

### AWS ACG (`scripts/acg/acg-aws-start.sh`)

- Provisions an EC2 instance in the sandbox.
- `scripts/acg/db-server/setup-pg-server.sh` installs native PostgreSQL 17 + pgvector + RabbitMQ.
- `scripts/acg/db-server/docker-compose.acg.yml` runs app containers on the host.
- Apps on your laptop connect via the SSM tunnel.
- Also writes `env/.env.acg` — same file as Azure ACG, since both are the
  same "acg" profile (you use one or the other, not both at once).

### Optional: auto-provision Portainer on ACG AWS

The AWS ACG host already runs Docker. To also get a Portainer UI on the ACG box,
you can extend `scripts/acg/acg-aws-start.sh` to deploy Portainer after the EC2 is ready:

```bash
# On the ACG host (run via the SSM tunnel / ssh)
docker volume create portainer_data
docker run -d --name portainer --restart=always \
  -p 8443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
```

Then `vm-db-up.sh` can target `https://<acg-host>:8443` by overriding the values
in `env/vm.env`. This makes one workflow drive both the local VM and the temporary
ACG server.

## 6. Prod (DigitalOcean, persistent)

```bash
# terraform.tfvars must exist with your DigitalOcean token
./scripts/prod/prod-start.sh              # creates managed Postgres cluster
# ... code ...
./scripts/prod/prod-stop.sh               # backs up only — infra keeps running
./scripts/prod/prod-stop.sh --destroy     # backs up AND tears down infrastructure
```

- Persistent by design — unlike ACG, `prod-stop.sh` does **not** destroy the
  infrastructure unless you explicitly pass `--destroy`. Running it plain is
  a safe, backup-only operation.
- Writes `env/.env.prod`, separate from `env/.env.acg`.
- Each project's `dev-up.sh --prod` reads from this file.

## 7. Required env var checklist

### For `compose/docker-compose-vm.yml` / `env/.env.vm`

Shared / base (must be in `env/.env.vm`):
- `GIT_URI`
- `ENCRYPT_KEY`
- `CONFIG_SERVER_USERNAME`
- `CONFIG_SERVER_PASSWORD`
- `RABBITMQ_DEFAULT_USER`
- `RABBITMQ_DEFAULT_PASS`
- `DOCKERHUB_TOKEN`
- `EVENT_DOMAIN_USER`
- `EVENT_DOMAIN_USER_PASSWORD`

Per-project DB (overwritten by `vm-db-up.sh` from project `.env`, but must exist
as fallbacks for a manual Portainer deploy):
- `EVENTS_TRACKER_DB_NAME` / `_USER` / `_PASSWORD`
- `RUNS_APP_DB_NAME` / `_USER` / `_PASSWORD`
- `RUNS_AI_ANALYZER_DB_NAME` / `_USER` / `_PASSWORD`
- `GITHUB_CLEANER_DB_NAME` / `_USER` / `_PASSWORD`
- `DBCLEANER_DB_NAME` / `_USER` / `_PASSWORD`

### For `vm-db-up.sh` itself (must be in `env/vm.env`)

- `VM_IP`
- `PORTAINER_URL`
- `PORTAINER_API_KEY`
- `PORTAINER_ENDPOINT_ID`
- `PORTAINER_STACK_NAME`

### For `env/.env.acg` / `env/.env.prod`

Shared connection info: `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`
(plus `SSM_RELAY_INSTANCE_ID` / `SSM_TUNNEL_PORT` / `SECRET_ARN` for AWS ACG only).

Per-project keys use the same names as each project's own local `.env` — see
`get_project_db_url_key` / `get_project_db_user_env_key` /
`get_project_env_password_key` in `scripts/lib/project-config.sh` for the
authoritative list per project.

## 8. Troubleshooting

**`vm-db-up.sh` says a base env var is missing**
→ `cp env/.env.vm.example env/.env.vm` and fill in real values. The script now validates
these before talking to Portainer.

**Portainer stack deploys but apps crash with "cannot resolve env"**
→ Make sure the project `.env` files exist locally (run each project's `dev-up.sh`
once) so `vm-db-up.sh` can push their DB credentials into the stack.

**Local and VM ports collide**
→ Use `--target local` to point project `.env` back at localhost without stopping
the VM stack, or run `./scripts/local/multi-dev-down.sh` first.

**A project's `.env` connects fine locally but fails on VM/ACG/prod with
"password authentication failed" or "role ... does not exist"**
→ Credential drift: the project's local password was rotated but the deployed
target was never re-synced. Run `./scripts/check-all-profiles.sh` (or
`scripts/vm/check-stack-consistency.sh --roles`) to find exactly which
target(s) are stale, then re-sync with `scripts/vm/vm-db-up.sh <project>`
(VM) or re-run the relevant ACG/prod start script.
