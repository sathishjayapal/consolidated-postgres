# runs-server host config and backups

runs-server (192.168.4.101, Ubuntu bare metal, user `skminfotech`) has a few settings that live
outside Docker. This repo is the source of truth for them; the server copies were captured on 2026-11-18.

| Repo file | On the server | Why |
|---|---|---|
| `host/netplan/50-cloud-init.yaml` | `/etc/netplan/50-cloud-init.yaml` (root, 600) | `dhcp-identifier: mac` keeps the DHCP lease (and SSH) on 192.168.4.101 — the lockout fix |
| `host/cloud-init/99-disable-network-config.cfg` | `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` | stops cloud-init regenerating netplan without `dhcp-identifier: mac` |
| `host/systemd/getty@tty1.service.d/autologin.conf` | `/etc/systemd/system/getty@tty1.service.d/autologin.conf` | console auto-login; the box has no keyboard |
| `systemd/litellm.service` | `/etc/systemd/system/litellm.service` | LiteLLM proxy; secrets in `/home/skminfotech/.config/litellm/litellm.env` (600, not in git) |
| `scripts/vm/runs-server-backup.sh` + `systemd/runs-server-backup.{service,timer}` | `/usr/local/sbin/runs-server-backup`, `/etc/systemd/system/` | nightly backups |

## Netplan — install safely

The file is named `50-cloud-init.yaml` because the installer wrote it. Two things keep cloud-init
from rewriting it (checked 2026-11-18): `/etc/cloud/cloud-init.disabled` exists, and
`host/cloud-init/99-disable-network-config.cfg` is installed. The second matters if the first is ever
removed, because `/etc/cloud/cloud.cfg.d/90-installer-network.cfg` holds the installer's config
without `dhcp-identifier: mac`.

```bash
sudo install -m 644 host/cloud-init/99-disable-network-config.cfg /etc/cloud/cloud.cfg.d/
```

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
sudo systemctl daemon-reload
sudo systemctl start runs-server-backup && journalctl -u runs-server-backup -n 30 --no-pager   # local only for now
sudo systemctl enable --now runs-server-backup.timer
```

### Offsite copy → mac-mini server (sats13mini-server, 192.168.4.236)

The whole `/var/backups/runs-server` tree is mirrored to `/srv/backups/runs-server` on the
mac-mini server after every clean run. The job runs as root, so root gets its own key, and that key
is locked with `rrsync` to that one folder (no shell, no other paths).

1. **mac-mini server, read-only check first** (login there is `sjkayap`; checked 2026-11-18: 196 GB free on `/`, `rsync` and `rrsync` present, `/srv` not created yet):

   ```bash
   whoami; df -h /srv 2>/dev/null || df -h /; command -v rsync rrsync
   ```

2. **mac-mini server, create the folder:**

   ```bash
   sudo install -d -m 700 -o sjkayap -g sjkayap /srv/backups/runs-server
   ```

3. **runs-server, create root's key and pin the host key:**

   ```bash
   sudo ssh-keygen -t ed25519 -N '' -C 'runs-server-backup' -f /root/.ssh/runs-server-backup
   sudo sh -c 'ssh-keyscan -t ed25519 192.168.4.236 >> /root/.ssh/known_hosts'
   sudo cat /root/.ssh/runs-server-backup.pub
   ```

4. **mac-mini server, authorize it for rsync into that folder only** — one line in
   `/home/sjkayap/.ssh/authorized_keys`, with the public key from step 3:

   ```
   restrict,command="/usr/bin/rrsync /srv/backups/runs-server" ssh-ed25519 AAAA... runs-server-backup
   ```

5. **runs-server, point the job at it.** With `rrsync` the path is relative to the locked folder, hence `:.`:

   ```bash
   sudo tee /etc/default/runs-server-backup <<'CONF'
   OFFSITE_TARGET=sjkayap@192.168.4.236:.
   OFFSITE_SSH_KEY=/root/.ssh/runs-server-backup
   CONF
   sudo chmod 600 /etc/default/runs-server-backup
   ```

6. **Test it**, then check the files landed on the mac-mini server:

   ```bash
   sudo systemctl start runs-server-backup && journalctl -u runs-server-backup -n 30 --no-pager
   # on the mac-mini server:
   ls -l /srv/backups/runs-server/daily/
   ```

Trade-offs: the mac-mini server is on the same LAN and in the same house, so this protects against
runs-server's disk dying or a bad change, not against fire or theft. The sync mirrors deletes (a run
with failures never syncs), so if runs-server itself were compromised, the key could still empty that
folder; `rrsync -no-del` plus pruning on the mac-mini side would close that, at the cost of a second
retention job. `rclone:remote:path` is still supported if you want a real offsite copy later.

### Restore test (do this once after install, then quarterly)

Backups are root-only (700/600), so every read goes through `sudo cat`. Restores go into scratch
databases named `restore_test`, never over the live ones. Safe to paste as one block:

```bash
B=/var/backups/runs-server/daily/$(date +%F)     # server clock is UTC
sudo cat $B/STATUS && sudo sh -c "cd $B && sha256sum -c SHA256SUMS"

# native Postgres 16
sudo -u postgres createdb restore_test
sudo cat $B/pg16-runsapp_db.dump | sudo -u postgres pg_restore --no-owner -d restore_test
sudo -u postgres psql -d restore_test -c '\dt'
sudo -u postgres dropdb restore_test

# pgvector
docker exec sathish-stack-runs-ai-analyzer-db sh -c 'createdb -U "$POSTGRES_USER" restore_test'
sudo cat $B/pgvector-runs-ai-analyzer.dump | docker exec -i sathish-stack-runs-ai-analyzer-db \
  sh -c 'pg_restore --no-owner -U "$POSTGRES_USER" -d restore_test'
docker exec sathish-stack-runs-ai-analyzer-db sh -c 'psql -U "$POSTGRES_USER" -d restore_test -c "\dt"'
docker exec sathish-stack-runs-ai-analyzer-db sh -c 'dropdb -U "$POSTGRES_USER" restore_test'

# RabbitMQ: check the export only (importing changes the live broker)
sudo python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print({k: len(v) for k, v in d.items() if isinstance(v, list)})" $B/rabbitmq-definitions.json
```

Real RabbitMQ restore, **only on a rebuilt or empty broker** (it applies users, vhosts, queues and
bindings to the running broker):

```bash
sudo cat $B/rabbitmq-definitions.json | docker exec -i sathish-stack-rabbitmq rabbitmqctl import_definitions -
```

For a full rebuild of native Postgres: restore `pg16-globals.sql` first (`psql -f`), then each
`pg16-<db>.dump` with `pg_restore -C -d postgres`.
