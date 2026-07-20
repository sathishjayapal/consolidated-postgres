# VirtualBox Stack — Setup Guide

## Architecture Overview

```
Your Mac (Apple Silicon / ARM64)
  │
  │  (git push to GitHub)
  ▼
GitHub Actions ──builds linux/amd64──▶ Docker Hub  (travelhelper0h/*)
                                                │
                                                │  (Watchtower polls every 5 min)
                                                ▼
                          VirtualBox VM — Bridged Adapter (linux/amd64)
                            ├── Portainer       :9000
                            ├── config-server   :8888
                            ├── sathishlogger   :8090
                            ├── eventstracker   :9081
                            ├── dbcleaner       :8085
                            ├── postgres
                            ├── rabbitmq        :15672
                            └── watchtower
```

**Networking:** VM uses a Bridged Adapter — it gets its own LAN IP. No port forwarding needed.

**Deployment:** Watchtower polls Docker Hub from inside the VM every 5 minutes and auto-restarts containers when a new
`:latest` is pushed. No webhook or open inbound port required.

**Architecture:** Your Mac is ARM64 (Apple Silicon). The VM is linux/amd64. Always build images with
`--platform linux/amd64` on your Mac, or let GitHub Actions (ubuntu-latest = amd64) handle it.

---

## Step 1 — Find Your VM's IP

SSH into the VM or open its terminal:

```bash
hostname -I
# or
ip addr show eth0
```

You'll get something like `192.168.1.45`. Use that for all service URLs.

---

## Step 2 — Docker Hub Secrets (all 3 GitHub repos)

In each repo → **Settings → Secrets and variables → Actions**, add:

| Secret name          | Value                                |
|----------------------|--------------------------------------|
| `DOCKERHUB_USERNAME` | `travelhelper0h`                     |
| `DOCKERHUB_TOKEN`    | Docker Hub access token (read/write) |

Generate a token at: https://hub.docker.com/settings/security

All three Docker Hub repos are **public** — no `docker login` needed on the VM to pull images.

---

## Step 3 — Bootstrap: Build & Push Images to Docker Hub

Do this once from your Mac. **Must use `--platform linux/amd64`** because your Mac is ARM64 and the VM is amd64 —
mismatched images cause `no matching manifest` errors in Portainer.

```bash
# Log in to Docker Hub
docker login -u travelhelper0h

# ── Config server ──────────────────────────────────────────────────────────
cd ~/IdeaProjects/sathishproject-config-server
./mvnw package -DskipTests -B
docker buildx build --platform linux/amd64 \
  -t travelhelper0h/sathishproject-config-server:latest --push .

# ── Sathishlogger ──────────────────────────────────────────────────────────
# Run `mvn install` (not just package) so eventstracker can find it as a dependency
cd ~/IdeaProjects/sathishlogger
mvn install -DskipTests -B
docker buildx build --platform linux/amd64 \
  -t travelhelper0h/sathishlogger:latest --push .

# ── Eventstracker ──────────────────────────────────────────────────────────
# sathishlogger must be installed first (local SNAPSHOT dependency)
# mvnw needs chmod+x when cross-building — handled in Dockerfile
cd ~/IdeaProjects/eventstracker
./mvnw package -DskipTests -B
mv target/*.jar target/app.jar
docker buildx build --platform linux/amd64 \
  -t travelhelper0h/eventstracker:latest --push .

# ── Dbcleaner ──────────────────────────────────────────────────────────────
# Fully self-contained multi-stage Dockerfile: it compiles the webpack frontend
# AND the Spring Boot jar inside the build — no host `mvnw package` needed.
cd ~/IdeaProjects/dbcleaner
docker buildx build --platform linux/amd64 \
  -t travelhelper0h/dbcleaner:latest --push .
```

> **Why `--push` instead of separate `docker push`?**
> `buildx` builds in a remote builder context and the image doesn't land in your local Docker daemon, so `--push` sends
> it directly to Docker Hub.

---

## Step 4 — Create the Portainer Stack

1. Open Portainer at `http://<vm-ip>:9000`
2. Go to **Stacks → + Add stack**
3. Name it `sathish-stack`
4. Select **Web editor** and paste the contents of `docker-compose-vm.yml` (at the repo root)
5. Scroll to **Environment variables** and add:

| Variable                 | Value                                          |
|--------------------------|------------------------------------------------|
| `GIT_URI`                | HTTPS URL of your Spring Cloud Config git repo |
| `ENCRYPT_KEY`            | your `encrypt.key` value                       |
| `CONFIG_SERVER_USERNAME` | basic-auth username for config server          |
| `CONFIG_SERVER_PASSWORD` | basic-auth password for config server          |
| `POSTGRES_PASSWORD`      | strong password for the eventstracker DB       |
| `RABBITMQ_DEFAULT_USER`  | e.g. `sathish`                                 |
| `RABBITMQ_DEFAULT_PASS`  | strong RabbitMQ password                       |
| `DOCKERHUB_TOKEN`        | Docker Hub token (used by Watchtower)          |

6. Click **Deploy the stack**

Startup order (enforced by `depends_on` + healthchecks):

1. `postgres` + `rabbitmq` start immediately
2. `config-server` starts and waits to become healthy (~40 s)
3. `eventstracker` starts only after config-server is healthy
4. `dbcleaner` starts after `dbcleaner-db` is healthy; it also opens read pools to `runs-app-db`, `runs-ai-analyzer-db`
   and `postgres` (eventstracker), so enable those DB blocks in the PROJECT-DBS section (pass `runs-app`,
   `runs-ai-analyzer`, `eventstracker` to `vm-db-up.sh`). Until they're up it restarts automatically.

> **dbcleaner DB env vars** — `DBCLEANER_DB_NAME` / `_USER` / `_PASSWORD` (plus
> `RUNS_APP_DB_*`, `RUNS_AI_ANALYZER_DB_*`, `EVENTS_TRACKER_DB_*`) are pushed
> into the Portainer stack env automatically by `vm-db-up.sh` from each
> project's local `.env`; you don't add them by hand.

---

## Step 5 — Ongoing CI/CD Flow

After the bootstrap, every `git push` to `main` on any of the three repos:

1. GitHub Actions builds the Maven JAR on `ubuntu-latest` (amd64 — correct architecture)
2. Builds and pushes `:<sha>` + `:latest` to Docker Hub
3. Watchtower detects the new `:latest` digest within 5 minutes
4. Watchtower pulls the new image and does a rolling restart

Watch it in Portainer → **Containers → watchtower → Logs**.

**Note for eventstracker CI:** The workflow clones `sathishlogger` and runs `mvn install` before building
`eventstracker`, because `sathish-projects-logger` is a local SNAPSHOT not published to Maven Central.

---

## Service Endpoints

| Service       | URL                                              |
|---------------|--------------------------------------------------|
| Portainer     | `http://<vm-ip>:9000`                            |
| Config server | `http://<vm-ip>:8888/sathishconfigserver/health` |
| SathishLogger | `http://<vm-ip>:8090/api/logs/health`            |
| EventsTracker | `http://<vm-ip>:9081`                            |
| RabbitMQ UI   | `http://<vm-ip>:15672`                           |

---

## Troubleshooting

**`no matching manifest for linux/amd64`**
→ Image was built on Mac without `--platform linux/amd64`. Rebuild using the bootstrap commands in Step 3.

**`pull access denied` / repo does not exist**
→ That image was never pushed. Run the bootstrap command for that specific service.

**`mvnw: Permission denied` during Docker build**
→ Fixed in Dockerfile with `RUN chmod +x mvnw`. If you see this, pull the latest Dockerfile.

**`target/app.jar not found` when building eventstracker**
→ Run `mvn install -DskipTests -B` in `sathishlogger` first, then in `eventstracker`:
`./mvnw package -DskipTests -B && mv target/*.jar target/app.jar`.

**`cannot resolve com.sathish:sathish-projects-logger` during eventstracker build**
→ `sathishlogger` hasn't been installed to the local Maven repo. Run `cd sathishlogger && mvn install -DskipTests -B`
first.

**eventstracker keeps restarting in Portainer**
→ Config server not healthy yet. Check Portainer → Containers → config-server → Logs. → Verify `GIT_URI` is an HTTPS URL
accessible from inside the VM.

**Watchtower not picking up new images**
→ Check watchtower logs for auth errors. Verify `DOCKERHUB_TOKEN` is set in the stack env and hasn't expired. NALi