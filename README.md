# consolidated-postgres

Shared local & cloud orchestration layer for the `IdeaProjects` workspace. This repo contains **no application code** —
it starts, stops, verifies, and tears down the PostgreSQL databases and RabbitMQ broker that `eventstracker`,
`runs-app`, and
`runs-ai-analyzer` depend on, both locally (Docker) and in temporary cloud sandboxes (DigitalOcean, Azure ACG, AWS ACG).

## Repository layout

| Path                                                                                   | Purpose                                                                                                                                  |
|----------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| `scripts/local/`                                                                       | Local dev orchestration — `multi-dev-up.sh`, `multi-dev-down.sh`, `multi-dev-verify.sh`, `start-all-services.sh`, `stop-all-services.sh` |
| `scripts/lib/project-config.sh`                                                        | Shared project metadata (ports, DB names, containers, env keys)                                                                          |
| `projects.txt`                                                                         | Source of truth for which projects are managed by the orchestration scripts                                                              |
| `scripts/cloud/cloud-start.sh` / `scripts/cloud/cloud-stop.sh`                                                     | DigitalOcean managed Postgres, on-demand                                                                                                 |
| `scripts/acg/acg-start.sh` / `scripts/acg/acg-stop.sh`                                                         | Azure ACG sandbox — Postgres Flexible Server                                                                                             |
| `scripts/acg/acg-aws-start.sh` / `scripts/acg/acg-aws-stop.sh`                                                 | AWS ACG sandbox — Docker `pgvector` on EC2 via SSM tunnel                                                                                |
| `scripts/local/rabbitmq-manager.sh`, `compose/rabbitmq-compose.yml` | RabbitMQ lifecycle                                                                                                                       |
| `tests/`                                                                               | bats test suites — run with `./tests/run-tests.sh`                                                                                       |
| `backups/`                                                                             | `pg_dump` output from cloud teardown (gitignored)                                                                                        |
| `docs/`                                                                                | Workflow and architecture docs                                                                                                           |

## Architecture

<!-- AUTO-GENERATED:ARCHITECTURE:START -->
![Architecture diagram](https://www.plantuml.com/plantuml/svg/XLMnRjim4Dtr5OTCoK1dxr0aI84i2UBKGuQY4CxIHMP3aGn9EKsA_dkFb6JBDfKEDiHxxnxrdddqbG_eGjUg8iYW22gZlL6ona2riCQ7nf478S2uQaC-E0pIQ6ZHmZbsmOY6DBd8lYZyYzGM7RQiqbgZIOTLU6THHrL0tIWg53q720QSR3O1QXaHrYiAYzKBDWHdTwP21G_JtSxWJm7me-rKaAAchUZimcz-0df8jP9hPMTBlpcarUPDdn9ZzOIw9IUVtq_9VNsWfwW4AYKykQsio8yD2IaPAKTarsBiJ8Un9mr_9pdSADFLsHo-oKO6L0yLeOPpNpbfWx-i8h__5kbrU2UuX3niOe0NwKMcQb7z-gDp1DStjtjfh9huoSdkeObaaYXP8kazhV9g-EO_K-pXgUhJAcbEG_gEwxKCzuzmZveBBP-u8IINaFPLj0bnO-vZlHpgnx7tGZKidVd5PzF3kHsU5k5tk1ZKQSixnP-bUY6NT0ygwGKwxGLQs-_AYv8NUq0AtaYzVmpjFK6MOp4I-UojZIUnHgUnKfI8Gx4SYv5Oh_a1zI2rMqLVFCUuHi_6bkJ4O0MM_Lol7k_EOiVojdZjg9lacShtZqLnD5zy4NmziffZxEpEWnEhETA9pHnfxpI7igjScLrbfpLZRPwtC_W_oiJcFFN4x3nrRtcUmyRdGRP_S7_q3V05-6nifUTRnXUx-SsZ_HnciSnqZRiUH0kBnT3i26j_-UPa86uVOlqKtaSwGpkESuQsYt86lo9Tn__5Vm00)

<details>
<summary>PlantUML source (also at <code>docs/architecture.puml</code>)</summary>

```plantuml
@startuml
title consolidated-postgres -- orchestration map (auto-generated)
skinparam componentStyle rectangle
left to right direction

package "Local Orchestration" {
  [multi-dev-up.sh] as multi_dev_up_sh
  [multi-dev-down.sh] as multi_dev_down_sh
  [multi-dev-verify.sh] as multi_dev_verify_sh
  [start-all-services.sh] as start_all_services_sh
  [stop-all-services.sh] as stop_all_services_sh
}

package "Cloud Orchestration" {
  [DigitalOcean (scripts/cloud/cloud-start.sh / scripts/cloud/cloud-stop.sh)] as DigitalOcean
  [Azure ACG (scripts/acg/acg-start.sh / scripts/acg/acg-stop.sh)] as Azure_ACG
  [AWS ACG (scripts/acg/acg-aws-start.sh / scripts/acg/acg-aws-stop.sh)] as AWS_ACG
}

package "RabbitMQ Management" {
  [rabbitmq-manager.sh] as rabbitmq_manager_sh
}

package "Managed Projects (projects.txt)" {
  [eventstracker] as eventstracker
  [runs-app] as runs_app
  [runs-ai-analyzer] as runs_ai_analyzer
  [verbose-barnacle] as verbose_barnacle
  [dbcleaner] as dbcleaner
}

database "Per-project PostgreSQL" as PG
queue "RabbitMQ" as MQ

multi_dev_up_sh --> eventstracker
multi_dev_up_sh --> runs_app
multi_dev_up_sh --> runs_ai_analyzer
multi_dev_up_sh --> verbose_barnacle
multi_dev_up_sh --> dbcleaner
multi_dev_up_sh --> PG
multi_dev_up_sh --> MQ
start_all_services_sh --> eventstracker
start_all_services_sh --> runs_app
start_all_services_sh --> runs_ai_analyzer
start_all_services_sh --> verbose_barnacle
start_all_services_sh --> dbcleaner
start_all_services_sh --> PG
start_all_services_sh --> MQ
DigitalOcean --> PG : provisions
Azure_ACG --> PG : provisions
AWS_ACG --> PG : provisions
rabbitmq_manager_sh --> MQ
eventstracker ..> PG : reads/writes
runs_app ..> PG : reads/writes
runs_ai_analyzer ..> PG : reads/writes
verbose_barnacle ..> PG : reads/writes
dbcleaner ..> PG : reads/writes
@enduml
```
</details>
<!-- AUTO-GENERATED:ARCHITECTURE:END -->

## Quick start — local dev

```bash
cd consolidated-postgres
./scripts/local/multi-dev-up.sh        # start Postgres containers + RabbitMQ
./scripts/local/multi-dev-verify.sh    # guardrail checks
./scripts/local/start-all-services.sh  # start eventstracker -> runs-app -> runs-ai-analyzer in order
```

Reset to a clean slate: `./scripts/local/multi-dev-up.sh --reset`

| Project          | App port | DB port | DB name               | Container             |
|------------------|----------|---------|-----------------------|-----------------------|
| eventstracker    | 9081     | 6433    | `event-service`       | `event-service-db`    |
| runs-app         | 8080     | 5443    | `runsapp_db`          | `runs-app-postgres`   |
| runs-ai-analyzer | 8081     | 5444    | `runs_ai_analyzer_db` | `runs-ai-analyzer-db` |

## VM databases (VirtualBox + Portainer)

Run persisted project databases on the VirtualBox VM instead of (or alongside) local Docker:

```bash
cp env/vm.env.example env/vm.env                          # one-time: VM IP + Portainer API key
cp env/.env.vm.example env/.env.vm                       # one-time: stack env vars (secrets)
./scripts/vm/vm-db-up.sh runs-app runs-ai-analyzer  # DBs for the projects you pass
```

Regenerates the managed block in `compose/docker-compose-vm.yml`, syncs each selected project's own compose
file, rewrites its `.env` JDBC URL to the VM (or back to localhost with `--target local`), and redeploys the Portainer
stack via API. Data lives in named volumes on the VM.

- `env/vm.env` — how `vm-db-up.sh` talks to Portainer.
- `env/.env.vm` — the environment variables pushed **into** the Portainer stack.

See [docs/VM_WORKFLOW.md](docs/VM_WORKFLOW.md) and the new [docs/ENVIRONMENTS.md](docs/ENVIRONMENTS.md) for the full environment map.

## Cloud database options

| Scripts                                | Provider          | Notes                                                                                                                                      |
|----------------------------------------|-------------------|--------------------------------------------------------------------------------------------------------------------------------------------|
| `scripts/cloud/cloud-start.sh` / `scripts/cloud/cloud-stop.sh`     | DigitalOcean      | Managed Postgres cluster, ~$0.50/day while running                                                                                         |
| `scripts/acg/acg-start.sh` / `scripts/acg/acg-stop.sh`         | Azure ACG sandbox | Postgres Flexible Server via targeted `terraform apply` against `../iAC-NikeRuns`                                                          |
| `scripts/acg/acg-aws-start.sh` / `scripts/acg/acg-aws-stop.sh` | AWS ACG sandbox   | `pgvector/pgvector:pg16` in Docker on an EC2 t3.micro, reached via SSM port-forwarding tunnel (managed RDS is blocked by SCP `p-cr6s9vs4`) |

All three `*-stop.sh` scripts `pg_dump` every database to `backups/` before tearing down infrastructure.

## RabbitMQ

```bash
./scripts/local/rabbitmq-manager.sh start|stop|restart|status|logs|clean
```

See [RABBITMQ-README.md](RABBITMQ-README.md) for details.

## Testing

```bash
./tests/run-tests.sh            # all bats suites (auto-installs bats-core if needed)
./tests/run-tests.sh unit        # unit tests only
./tests/run-tests.sh integration # integration tests only
```

## Documentation index

- [START_HERE.md](START_HERE.md) — prerequisites & new-machine setup
- [docs/ENVIRONMENTS.md](docs/ENVIRONMENTS.md) — environment decision tree & file map (local / VM / ACG / cloud)
- [docs/LOCAL_ENV_WORKFLOW.md](docs/LOCAL_ENV_WORKFLOW.md) — local/cloud toggle & guardrails
- [EVENT_DRIVEN_STARTUP.md](EVENT_DRIVEN_STARTUP.md) — correct service startup order
- [RABBITMQ-README.md](RABBITMQ-README.md) — RabbitMQ management utilities

## Repository status

<!-- AUTO-GENERATED:STATUS:START -->
_Generated from `projects.txt` and the scripts present in the repo as of `36cf298`._

| Script | Present | Description |
|---|---|---|
| `scripts/local/multi-dev-up.sh` | yes | Multi-project Development Environment Startup |
| `scripts/local/multi-dev-down.sh` | yes | Multi-project Development Environment Shutdown |
| `scripts/local/multi-dev-verify.sh` | yes | Guardrail verification script to ensure our multi-service local environment |
| `scripts/local/start-all-services.sh` | yes | Automated Service Startup with Correct Ordering |
| `scripts/local/stop-all-services.sh` | yes | Stop All Spring Boot Services |
| `scripts/cloud/cloud-start.sh` | yes | On-Demand Cloud Database Startup |
| `scripts/cloud/cloud-stop.sh` | yes | On-Demand Cloud Database Shutdown |
| `scripts/acg/acg-start.sh` | yes | ACG Azure Sandbox — Shared PostgreSQL Startup |
| `scripts/acg/acg-stop.sh` | yes | ACG Azure Sandbox — PostgreSQL Teardown |
| `scripts/acg/acg-aws-start.sh` | yes | ACG AWS Sandbox — PostgreSQL via SSM (Docker on EC2) |
| `scripts/acg/acg-aws-stop.sh` | yes | ACG AWS Sandbox — PostgreSQL Teardown |
| `scripts/local/rabbitmq-manager.sh` | yes | RabbitMQ Manager - Comprehensive utility for managing RabbitMQ containers |

| Managed project | DB port | DB name |
|---|---|---|
| `eventstracker` | 6433 | `event-service` |
| `runs-app` | 5443 | `runsapp_db` |
| `runs-ai-analyzer` | 5444 | `runs_ai_analyzer_db` |
| `verbose-barnacle` | 5439 | `my-github-cleaner` |
| `dbcleaner` | 5433 | `dbcleaner` |
<!-- AUTO-GENERATED:STATUS:END -->

## Keeping this README in sync

The **Architecture** and **Repository status** sections above are generated by
[`scripts/update_readme.py`](scripts/update_readme.py) from the actual contents of
`projects.txt` and the orchestration scripts — not hand-maintained.

A pre-commit hook regenerates these sections (and re-stages `README.md` if they changed) on every commit. Enable it once
per clone:

```bash
./scripts/install-git-hooks.sh
```

To regenerate manually:

```bash
python3 scripts/update_readme.py
```