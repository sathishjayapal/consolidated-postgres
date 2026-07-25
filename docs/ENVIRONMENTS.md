# Environment & Deployment Map

This repo orchestrates the same set of project databases across four different
targets. This doc explains which target to use when, and what env file / script
drives each one.

## 1. Decision tree

```
Where do I need the databases?
│
├─► On my Mac, no persistence needed         →  Local Docker (multi-dev-up.sh)
│
├─► On my local VirtualBox VM, persisted      →  VM Portainer (vm-db-up.sh)
│   with web UI + auto-redeploy via Watchtower
│
├─► On a temporary ACG cloud sandbox          →  ACG scripts
│   ├─ Azure ACG  → scripts/acg/acg-start.sh / scripts/acg/acg-stop.sh
│   └─ AWS ACG    → scripts/acg/acg-aws-start.sh / scripts/acg/acg-aws-stop.sh
│
└─► On a real, billable cloud DB              →  DigitalOcean (scripts/cloud/cloud-start.sh)
```

| Goal | Use | Persistent? | Cost |
|------|-----|-------------|------|
| Local dev / quick test | `scripts/local/multi-dev-up.sh` | Optional Docker volumes | Free |
| Local VM with UI + CI redeploy | `scripts/vm/vm-db-up.sh` + Portainer | Named volumes on VM | Free |
| Azure ACG lab sandbox | `scripts/acg/acg-start.sh` / `scripts/acg/acg-stop.sh` | Until sandbox expires | ACG included |
| AWS ACG lab sandbox | `scripts/acg/acg-aws-start.sh` / `scripts/acg/acg-aws-stop.sh` | Until sandbox expires | ACG included |
| Real cloud (production-like) | `scripts/cloud/cloud-start.sh` / `scripts/cloud/cloud-stop.sh` | Until destroyed | DigitalOcean |

## 2. File map

| File | What it controls | Who consumes it |
|------|------------------|-----------------|
| `env/vm.env` | How `vm-db-up.sh` talks to Portainer: URL, API key, endpoint ID, stack name | `scripts/vm/vm-db-up.sh` only |
| `env/.env.vm` | The **stack environment variables** pushed into Portainer for `compose/docker-compose-vm.yml` | `scripts/vm/vm-db-up.sh` → Portainer stack |
| `env/.env.vm.example` | Complete template for `env/.env.vm` with every required key | Human reference / copy source |
| `env/.env.cloud` | Generated DB connection strings after a cloud sandbox comes up | Local Spring Boot apps in `--cloud` mode |
| `compose/docker-compose-vm.yml` | The Portainer stack definition (DBs + RabbitMQ + apps + Watchtower) | Portainer (never run directly with `docker compose up`) |
| `scripts/acg/db-server/docker-compose.acg.yml` | ACG AWS variant: native PG/RabbitMQ + app containers | Docker Compose on the ACG EC2 host |
| `acg.tfvars` | Azure ACG sandbox credentials | `scripts/acg/acg-start.sh` |
| `terraform.tfvars` | DigitalOcean API token | `scripts/cloud/cloud-start.sh` / `scripts/cloud/cloud-stop.sh` |

**Naming rule of thumb:**
- `*.env` (no leading dot) = connection config for a **script**.
- `.*.env` or `.env.*` (leading dot) = **runtime environment** passed to apps/containers.

## 3. Local Docker

```bash
cd consolidated-postgres
./scripts/local/multi-dev-up.sh
./scripts/local/multi-dev-verify.sh
```

- Credentials live in each project's own `.env` (created by its `dev-up.sh`).
- No `env/vm.env` or `env/.env.vm` is involved.
- Use `--cloud` to point apps at a running ACG/DigitalOcean DB instead of local containers.

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

## 5. ACG temporary cloud

### Azure ACG (`scripts/acg/acg-start.sh`)

- Provisions an Azure PostgreSQL Flexible Server in the sandbox resource group.
- Writes `env/.env.cloud` and updates project `.env` files with cloud JDBC URLs.
- No Portainer or VM is involved; apps run locally against the cloud DB.

### AWS ACG (`scripts/acg/acg-aws-start.sh`)

- Provisions an EC2 instance in the sandbox.
- `scripts/acg/db-server/setup-pg-server.sh` installs native PostgreSQL 17 + pgvector + RabbitMQ.
- `scripts/acg/db-server/docker-compose.acg.yml` runs app containers on the host.
- Apps on your laptop connect via the SSM tunnel.

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

## 6. DigitalOcean real cloud

```bash
# terraform.tfvars must exist with your DigitalOcean token
./scripts/cloud/cloud-start.sh    # creates managed Postgres cluster
# ... code ...
./scripts/cloud/cloud-stop.sh     # pg_dump backup + destroy
```

- More persistent and more expensive than ACG.
- Writes `env/.env.cloud` just like Azure ACG.

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
