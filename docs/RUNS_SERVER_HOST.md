# runs-server host config and backups

runs-server (192.168.4.101, Ubuntu bare metal, user `skminfotech`) has a few settings that live
outside Docker. This repo is the source of truth for them; the server copies were captured on 2026-11-18.

| Repo file | On the server | Why |
|---|---|---|
| `host/netplan/50-cloud-init.yaml` | `/etc/netplan/50-cloud-init.yaml` (root, 600) | `dhcp-identifier: mac` keeps the DHCP lease (and SSH) on 192.168.4.101 — the lockout fix |
| `host/systemd/getty@tty1.service.d/autologin.conf` | `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | console auto-login; the box has no keyboard |
| `systemd/litellm.service` | `/etc/systemd/system/litellm.service` | LiteLLM proxy; secrets in `/home/skminfotech/.config/litellm/litellm.env` (600, not in git) |
| `scripts/vm/runs-server-backup.sh` + `systemd/runs-server-backup.{service,timer}` | `/usr/local/sbin/runs-server-backup`, `/etc/systemd/system/` | nightly backups |

## Netplan — install safely

The file is named `50-cloud-init.yaml` because the installer wrote it. Check that cloud-init won't
rewrite it (read-only):

```bash
ls /etc/cloud/cloud.cfg.d/ | grep -i network; cat /etc/cloud/cloud.cfg.d/*network* 2>/dev/null
```

If nothing says `network: {config: disabled}`, add that file before the next re-image, otherwise a
cloud-init re-run can drop `dhcp-identifier: mac` and cause the same lockout.

Over SSH, never use `netplan apply`. `netplan try` rolls back after 120 s unless you confirm:

```bash
sudo install -m 600 -o root -g root host/netplan/50-cloud-init.yaml /etc/netplan/50-cloud-init.yaml
sudo netplan generate && sudo netplan try
```

## Console auto-login

```bash
sudo install -D -m 644 "host/systemd/getty@tty1.service.d/autologin.conf" \
  "/etc/systemd/system/getty@tty1.service.d/autologin.conf"
sudo systemctl daemon-reload && sudo systemctl restart getty@tty1
```

## Backups

What's covered: every database on native Postgres 16 (found at run time) plus roles, the pgvector
database in `sathish-stack-runs-ai-analyzer-db`, and RabbitMQ definitions. Not covered: Loki logs,
in-flight RabbitMQ messages, Docker images. Local copies: 7 daily + 4 weekly under
`/var/backups/runs-server` (root only — the RabbitMQ export contains password hashes).

```bash
sudo install -m 750 scripts/vm/runs-server-backup.sh /usr/local/sbin/runs-server-backup
sudo cp systemd/runs-server-backup.service systemd/runs-server-backup.timer /etc/systemd/system/
# optional offsite: echo 'OFFSITE_TARGET=user@host:/path' | sudo tee /etc/default/runs-server-backup
sudo systemctl daemon-reload
sudo systemctl start runs-server-backup && journalctl -u runs-server-backup -n 30 --no-pager
sudo systemctl enable --now runs-server-backup.timer
```

Offsite: `OFFSITE_TARGET` takes `user@host:/path` (rsync over SSH, root needs a key for that host) or
`rclone:remote:path`. Empty means local only, and the job logs a warning every night. A run with
failures never syncs offsite, because the sync deletes files the local side no longer has.

### Restore test (do this once after install, then quarterly)

Restore into scratch databases, never over the live ones:

```bash
B=/var/backups/runs-server/daily/$(date +%F)
cat $B/STATUS && (cd $B && sha256sum -c SHA256SUMS)

# native Postgres 16
sudo -u postgres createdb restore_test
sudo -u postgres pg_restore --no-owner -d restore_test $B/pg16-runsapp_db.dump
sudo -u postgres psql -d restore_test -c '\dt' && sudo -u postgres dropdb restore_test

# pgvector
docker exec sathish-stack-runs-ai-analyzer-db sh -c 'createdb -U "$POSTGRES_USER" restore_test'
docker exec -i sathish-stack-runs-ai-analyzer-db sh -c 'pg_restore --no-owner -U "$POSTGRES_USER" -d restore_test' \
  < $B/pgvector-runs-ai-analyzer.dump
docker exec sathish-stack-runs-ai-analyzer-db sh -c 'dropdb -U "$POSTGRES_USER" restore_test'

# RabbitMQ (real restore, only on a rebuilt broker)
docker cp $B/rabbitmq-definitions.json sathish-stack-rabbitmq:/tmp/defs.json
docker exec sathish-stack-rabbitmq rabbitmqctl import_definitions /tmp/defs.json
```

For a full rebuild of native Postgres: restore `pg16-globals.sql` first (`psql -f`), then each
`pg16-<db>.dump` with `pg_restore -C -d postgres`.
