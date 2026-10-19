#!/usr/bin/env bash
# Adds Docker log rotation (json-file, 10m x 5 files per container) on runs-server, and
# enables live-restore so a later daemon restart does not bounce every container.
# Prerequisite for shipping container logs to Loki: without rotation each container's
# JSON log file grows without bound.
#
# Run ON THE VM as root:
#   scp scripts/vm/vm-setup-docker-log-rotation.sh vm:/tmp/
#   ssh -t vm 'sudo bash /tmp/vm-setup-docker-log-rotation.sh'            # config + reload only
#   ssh -t vm 'sudo RESTART=1 bash /tmp/vm-setup-docker-log-rotation.sh'  # also restart dockerd
#
# Idempotent. Merges into the existing /etc/docker/daemon.json (keeps metrics-addr) and backs
# it up as daemon.json.bak.<timestamp>.
#
# IMPORTANT: log-driver options in daemon.json are NOT retroactive. They apply only to
# containers created AFTER the daemon picks them up. Existing containers keep their old
# (unrotated) log config until they are recreated: Watchtower does this on the next image
# update, or redeploy the stack in Portainer. The final step lists which are still unrotated.
set -euo pipefail

DAEMON_JSON=/etc/docker/daemon.json
MAX_SIZE="${MAX_SIZE:-10m}"
MAX_FILE="${MAX_FILE:-5}"
STAMP=$(date +%Y%m%d%H%M%S)

[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

echo "==> 1/5 current config"
[ -f "$DAEMON_JSON" ] || echo '{}' > "$DAEMON_JSON"
cat "$DAEMON_JSON"
jq empty "$DAEMON_JSON" || { echo "existing $DAEMON_JSON is not valid JSON; fix by hand"; exit 1; }

echo "==> 2/5 merge log rotation + live-restore (backup first)"
cp -p "$DAEMON_JSON" "$DAEMON_JSON.bak.$STAMP"
TMP=$(mktemp)
jq --arg size "$MAX_SIZE" --arg file "$MAX_FILE" '
  . + {"log-driver": "json-file",
       "log-opts": ((.["log-opts"] // {}) + {"max-size": $size, "max-file": $file}),
       "live-restore": true}' "$DAEMON_JSON" > "$TMP"
install -m 644 "$TMP" "$DAEMON_JSON"; rm -f "$TMP"
cat "$DAEMON_JSON"

echo "==> 3/5 validate"
dockerd --validate --config-file="$DAEMON_JSON" \
  || { echo "validation failed; restoring backup"; cp -p "$DAEMON_JSON.bak.$STAMP" "$DAEMON_JSON"; exit 1; }

echo "==> 4/5 apply"
# live-restore is reloadable (SIGHUP) and does NOT touch running containers. Reloading it
# first means the restart below leaves containers running.
systemctl reload docker
sleep 2
if [ "$(docker info --format '{{.LiveRestoreEnabled}}')" != "true" ]; then
  echo "live-restore not active after reload; NOT restarting dockerd (it would bounce every container)"
  [ "${RESTART:-0}" = "1" ] && exit 1
fi
if [ "${RESTART:-0}" = "1" ]; then
  echo "restarting dockerd to apply log-opts (containers should stay up under live-restore)"
  systemctl restart docker
  sleep 5
  docker ps --format '{{.Names}}\t{{.Status}}'
else
  echo "skipped dockerd restart (log-opts take effect only after it). Re-run with RESTART=1."
fi

echo "==> 5/5 which running containers are still unrotated"
for c in $(docker ps --format '{{.Names}}'); do
  opts=$(docker inspect "$c" --format '{{json .HostConfig.LogConfig.Config}}')
  [ "$opts" = "{}" ] && echo "UNROTATED  $c" || echo "ok         $c $opts"
done
echo "done. Unrotated containers pick this up when recreated (Watchtower update or Portainer redeploy)."
