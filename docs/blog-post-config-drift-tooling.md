# One Repo to Wire Them All: Killing Config Drift Across Seven Services and Four Environments

My side-project workspace has grown into roughly seven Spring Boot services, each with its own PostgreSQL database, and each of those databases has to run in four different places: on my laptop in Docker, on a VirtualBox VM under Portainer, in an AWS/Azure "A Cloud Guru" sandbox, and (occasionally) on a real cloud provider. That's a 7×4 grid of "where does this database live and what are its credentials right now," and every cell in that grid is a chance for something to silently disagree with something else.

In my [last post](https://sathishjayapal.com) I wrote about the *hosting* side of this — moving the stack into a VM with Portainer and Watchtower. This post is about the part that turned out to be harder than hosting: keeping the **configuration** consistent across all those services and environments without losing an afternoon every time to a typo in an environment-variable name.

The tooling lives in a single repo, `consolidated-postgres`, that contains **no application code at all**. It only starts, stops, verifies, and tears down databases and message brokers. This month I finally got it to the point where the machine catches my mistakes before a container does. Here's what I built and, more usefully, the specific failure modes that forced me to build each piece.

---

## The problem: config drift is a combinatorial explosion

Here's the trap. Each of my services was written at a different time, so each one uses its own convention for the same idea. The database username for `runs-app` is `JDBC_DATABASE_USERNAME`. For `eventstracker` it's `EVENTS_TRACKER_DB_USER`. For `verbose-barnacle` it's `GITHUB_CLEANER_DB_USER`. Same concept — "what user does this app connect to Postgres as" — three different key names.

Now multiply that by four environments, each of which sets those keys in a different place:

- **local** — each project's own `.env`, read by its own `docker-compose.yml`
- **vm** — environment variables pushed into a Portainer stack via its API
- **acg** — a shared `.env.acg` pointing at one Postgres instance in a sandbox
- **prod** — a shared `.env.prod` pointing at a managed cloud database

The config server (Spring Cloud Config) sits on top of some of these and references values like `${EVENTS_TRACKER_DB_URL}` in YAML — and if the place that's *supposed* to define that exact key doesn't, Spring doesn't crash loudly. It either fails at connection time with an unhelpful error, or worse, substitutes the literal unresolved string and limps along until something downstream breaks.

Two real incidents on the same day, 2026-07-12, are what pushed me over the edge:

- `eventstracker` referenced `EVENTS_TRACKER_DB_URL` in its config YAML, but the deploy target set `SPRING_DATASOURCE_URL`. Nothing tied the two names together, so the app came up pointing at nothing.
- `my-github-cleaner` (the `verbose-barnacle` service) had the same class of mismatch: `JDBC_DATABASE_URL` in one place, `GITHUB_CLEANER_DB_URL` in another.

In both cases the config *looked* internally consistent if you only stared at one file. The bug lived in the **gap between two files** that no single file could reveal. That's the kind of bug you can't fix by being more careful — you fix it by making a machine compare the two sides.

---

## Step 1: one source of truth for every project's metadata

The foundation is a single shell library, `scripts/lib/project-config.sh`, plus a plain-text `projects.txt` list. Every script in the repo sources this library instead of hardcoding ports, container names, or env-var keys. Adding a new managed project is one line in `projects.txt` and a handful of `case` arms in the library.

I deliberately kept this in **portable Bash** rather than reaching for a fancier config format, because it has to run on macOS's ancient bundled Bash 3.2 (no associative arrays) as well as on Linux CI runners. So the metadata is a set of small functions, each a `case` statement:

```bash
get_project_db_url_key() {
  case "$1" in
    eventstracker)    echo "EVENTS_TRACKER_DB_URL" ;;
    runs-app)         echo "JDBC_DATABASE_URL" ;;
    runs-ai-analyzer) echo "RUNS_AI_ANALYZER_DB_URL" ;;
    verbose-barnacle) echo "GITHUB_CLEANER_DB_URL" ;;
    dbcleaner)        echo "JDBC_DATABASE_URL" ;;
    sathish-projects-logger) echo "DATABASE_URL" ;;
    mytracker)        echo "MYTRACKER_DB_URL" ;;
    *)                return 1 ;;
  esac
}
```

The important discipline here — the one that took me two tries to get right — is that there are actually **two different naming domains** and you must not confuse them:

- **Domain A:** the key names as they appear in a *project's own* `.env`, which that project's Spring config reads (`get_project_db_url_key`, `get_project_db_user_env_key`, `get_project_env_password_key`).
- **Domain B:** the key names pushed into the *VM Portainer stack* environment (`get_project_db_user_key`, `get_project_db_name_key`, `get_project_password_env_var`).

For some projects those two happen to coincide; for others they don't. Every writer that populates a project's local `.env` must use the Domain-A keys, and every writer that talks to Portainer must use Domain-B keys. Encoding that distinction *once*, in named functions with a comment explaining the boundary, is what stopped me from re-introducing the July 12 bug by hand. The knowledge moved out of my head and into the code.

---

## Step 2: documentation that literally cannot rot

A README that lists ports and database names is guaranteed to drift from reality — I've never once kept one accurate by hand. So the architecture diagram and the "repository status" table in this repo's README are **generated** from `projects.txt` and the actual scripts present, by `scripts/update_readme.py`, between HTML comment markers:

```
<!-- AUTO-GENERATED:STATUS:START -->
...table of every script, whether it exists, and its description...
<!-- AUTO-GENERATED:ARCHITECTURE:START -->
...PlantUML component diagram of which script provisions what...
```

A pre-commit hook regenerates those sections and re-stages the README if they changed. If I add a project to `projects.txt` and forget to mention it in the docs, the commit itself updates the docs for me. The rule I've settled on: **if a fact can be derived from the source of truth, never write it down by hand.** Hand-written docs are a promise you'll break; generated docs are a build artifact.

---

## Step 3: the drift checker — the piece I'm proudest of

This is the centerpiece: `scripts/vm/check-stack-consistency.sh`. It catches the two failure classes above *before* they reach a running container. You run it with no arguments for both checks, `--config` for the offline name check, or `--roles` for the live database checks.

### Check 1: config references vs. deployment definitions

For each project, the checker extracts every **bare** `${VAR}` placeholder from that project's config-server YAML — bare meaning no `:default` fallback, because those are the hard requirements that will actually break:

```bash
extract_placeholders() {
  # Only bare ${VAR} (no colon) — a missing value here is either a
  # crash or an unresolved literal string. ${VAR:default} has a
  # fallback and isn't worth flagging.
  grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$@" 2>/dev/null \
    | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/\1/' | sort -u
}
```

Then it collects the keys actually **defined** on the other side — either the service's `environment:` block in the VM compose file, or, for projects not yet deployed on the VM, that project's own local `.env`. Any referenced key that isn't defined is a `FAIL`:

```
=== Config <-> deployment name consistency ===
OK   eventstracker  (checked against compose/docker-compose-vm.yml service 'eventstracker')
OK   dbcleaner  (checked against compose/docker-compose-vm.yml service 'dbcleaner')
FAIL verbose-barnacle: referenced via ${...} in config but never set in verbose-barnacle/.env:
       GITHUB_CLEANER_DB_URL
```

That single check would have turned both July 12 incidents from "why is the app pointing at nothing" runtime mysteries into a one-line `FAIL` I'd see before deploying. The whole thing needs no network access — it's pure text comparison across files that normally never get compared.

### Check 2: Postgres role drift — the gotcha that eats hours

The second check is subtler and, to me, more interesting. The official Postgres image honors `POSTGRES_USER` / `POSTGRES_PASSWORD` **only the first time it initializes an empty data volume.** Change those env vars afterward and the running database never finds out. It keeps the old role forever. Your env files can look perfectly consistent on paper while every connection fails with `role "x" does not exist` or `password authentication failed`, because the *volume* was born under different credentials than the ones you're now handing it.

You cannot catch this by comparing config files — both sides can agree and still be wrong, because the truth lives inside a data volume that was initialized weeks ago. The only way to check it is to actually connect. So the checker asks each live database, "does the role I expect actually exist here?"

On the VM it does this through the Portainer Docker API — finding the container, then `exec`-ing a `psql` that connects **as the expected role** against `template1` (a database guaranteed to exist), over the container's local trust socket so no password is needed:

```bash
# Connect AS the expected role via the container's local trust socket
# against template1, which always exists. We don't assume a "postgres"
# superuser exists — the official image only creates one when
# POSTGRES_USER is left at its default, so guessing that name is itself
# a source of false failures.
psql -U "$expected_user" -d template1 -tAc "select 1"
```

If that returns `role "..." does not exist`, it's a hard `FAIL` with the actual remediation printed inline (`CREATE ROLE` / `ALTER DATABASE OWNER`, or wipe the volume and accept the data loss). If it returns `1`, the role is real and reachable.

Two design decisions made this check trustworthy enough that I actually believe its output:

1. **The expected username comes from the live Portainer stack env, not from a local `.env`.** The VM containers were deployed with whatever Portainer had at deploy time — that's the ground truth for what they *should* be. Reading a local `.env` (a different naming domain, remember) would produce confident nonsense.
2. **Unreachable is a skip, not a failure.** ACG sandboxes expire after four hours; a tunnel might be down. A connection timeout means "not up right now," which is a yellow skip. Only an *auth-specific* error — role missing, password rejected — is a red `FAIL`. This distinction is what keeps the check from crying wolf, and a check that cries wolf is a check you learn to ignore.

The ACG and prod targets get a variant of the same idea, except those use a single shared admin role across every project's database, so the check becomes "can this one shared user reach each project's database" via a plain `psql` over the JDBC URL parsed out of the env file.

---

## Step 4: generating the VM stack instead of hand-editing it

The VM's `docker-compose-vm.yml` has a managed block that's regenerated from the project metadata by `scripts/vm/vm-db-up.sh` (backed by a Python generator). You tell it which projects you want databases for:

```bash
./scripts/vm/vm-db-up.sh runs-app runs-ai-analyzer
```

and it rewrites the managed compose block, syncs each selected project's own compose file, rewrites that project's `.env` JDBC URL to point at the VM (or back to localhost with `--target local`), and redeploys the Portainer stack over its API. Because the image tag, data-volume name, mount path, and service name for every project all come from `project-config.sh`, the generated stack can't disagree with the checker — they read the same source. The postgres-18 quirk where the data directory moved up a level (`/var/lib/postgresql` vs `/var/lib/postgresql/data`) is encoded in exactly one place:

```bash
get_project_pg_mount() {
  case "$1" in
    runs-app|dbcleaner) echo "/var/lib/postgresql" ;;        # postgres 18+
    *) echo "/var/lib/postgresql/data" ;;
  esac
}
```

---

## Step 5: when the cloud says no — native Postgres on an ACG sandbox

The cloud layer had its own drift-adjacent lesson. My plan was to use managed RDS in the AWS sandbox, but the sandbox's service control policy (`p-cr6s9vs4`) blocks `rds:CreateDBInstance` outright — every managed-RDS path fails, and Aurora Serverless is either end-of-life (v1) or blocked for the same reason (v2). Verifying availability *before* building on a service, rather than assuming it works, saved me a lot of wasted `terraform apply` cycles.

The workaround is a single provisioning script, `setup-pg-server.sh`, that installs **native** PostgreSQL 17 + pgvector and a **native** RabbitMQ on one sandbox box, with all five databases on one instance. It's idempotent — safe to rerun after a failure — and it bakes in the sandbox's hard constraints: a fixed port allowlist you can't change (so passwords are the real firewall), a public IP that changes on every restart (use the stable hostname), and a four-hour auto-stop.

The RabbitMQ install had a genuinely obscure gotcha worth writing down: the sandbox images don't resolve their own short hostname, so RabbitMQ dies on startup with an `epmd_error` unless you pin the node name explicitly:

```
NODENAME=rabbit@localhost
```

And the server RPM lives in the **noarch** repo section, which the default repo config omits — so the install silently finds no package until you add that section. Both of these are the same shape of bug as the config drift: an assumption ("the host resolves its own name," "the package is in the arch repo") that's true everywhere I'd worked before and false here, with a failure mode that points nowhere near the actual cause.

---

## What I actually learned

1. **Config drift is a *comparison* bug, not a *carefulness* bug.** You can't fix "file A and file B disagree" by reading each file more carefully — the whole problem is that no one reads both at once. The fix is always a tool that compares the two sides mechanically. Once I framed it that way, the drift checker basically designed itself.

2. **Encode the naming domains once, in one file.** The reason I kept re-introducing the same bug is that "the DB username" had three different names depending on which project and which environment you meant. Naming that distinction explicitly — Domain A (project `.env`) vs Domain B (Portainer stack) — and giving each a named function is what finally made it stick.

3. **State that lives in a volume can't be checked from config.** The Postgres role-drift bug is the cleanest example: two config files can perfectly agree and still both be wrong, because the truth was written into a data volume at init time and never updated. Some invariants can only be checked by *connecting to the live thing and asking it.*

4. **A check that cries wolf is worse than no check.** The single most valuable line of design in the whole drift checker is "unreachable is a skip, not a failure." If the tool had failed loudly every time a sandbox happened to be stopped, I'd have stopped running it within a week. Distinguishing "genuinely broken" from "not up right now" is what makes it something I actually trust.

5. **Generated artifacts don't rot; hand-written ones lie.** The README status table, the architecture diagram, the VM compose block — all generated from `projects.txt` + `project-config.sh`. The rule I now hold to: if a fact is derivable from the source of truth, deriving it is the only honest way to keep it true.

6. **Verify service availability before building on it.** The blocked-RDS detour and the RabbitMQ `noarch`/`NODENAME` gotchas are all the same lesson — the assumption that a thing works "because it always has" is exactly where the hours go. In a constrained environment, check first, build second.

---

## What's next

The obvious gap is that the drift checker runs when I remember to run it. The next step is wiring `check-stack-consistency.sh --config` (the offline check, which needs no network) into the pre-commit hook alongside the README generator, so a name mismatch can't even be committed. The live `--roles` check is a better fit for a scheduled job that dumps a status file. I'll write that up when it's real — not before.

---

## References

- [Docker official Postgres image — environment variables & volume init](https://hub.docker.com/_/postgres)
- [Spring Cloud Config Server](https://docs.spring.io/spring-cloud-config/reference/)
- [Portainer API](https://docs.portainer.io/api/access)
- [RabbitMQ — configuration & node names](https://www.rabbitmq.com/configure.html)
- [pgvector](https://github.com/pgvector/pgvector)
