#!/usr/bin/env bash
# Configure recovery for the observed runs-server applications. Run with sudo.
set -Eeuo pipefail
export SYSTEMD_PAGER=cat SYSTEMD_COLORS=0
if (( EUID != 0 )); then
  printf 'Run with: sudo bash runs-server-recovery.sh\n' >&2
  exit 1
fi
if [[ $(hostname -s) != runs-server ]]; then
  printf 'Wrong host: run this on runs-server, not %s.\n' "$(hostname -s)" >&2
  exit 1
fi
umask 077
backup=$(mktemp -d /var/backups/runs-server-recovery-XXXXXXXX)
exec > >(tee "$backup/report.txt") 2>&1
printf 'Recovery setup on runs-server. Backup and report: %s\n' "$backup"
systemctl list-unit-files --type=service --no-pager > "$backup/services-before.txt"
systemctl list-units --type=service --all --no-pager > "$backup/status-before.txt"
declare -A selected=()
declare -a managed=() issues=() unclassified=()

# Only known server daemons and already-running custom daemons are selected.
# Do not enable every Ubuntu service or restart scheduled/one-shot work.
while read -r unit state _; do
  [[ $unit == *.service && $unit != *@.service ]] || continue
  [[ $state != masked* ]] || continue
  case "$unit" in
    prometheus.service|alertmanager.service|prometheus-alertmanager.service|prometheus-*-exporter*.service|grafana-server.service|grafana.service|node_exporter.service|node-exporter.service|prometheus-node-exporter.service|docker.service|containerd.service|postgresql.service|ssh.service|tailscaled.service|ollama.service|litellm*.service|wazuh-manager.service|wazuh-indexer.service|wazuh-dashboard.service|alloy.service|loki.service)
      selected["$unit"]=1 ;;
    *)
      fragment=$(systemctl show "$unit" -p FragmentPath --value)
      if [[ $fragment == /etc/systemd/system/* ]]; then
        custom_type=$(systemctl show "$unit" -p Type --value)
        custom_remain=$(systemctl show "$unit" -p RemainAfterExit --value)
        if [[ $custom_type == oneshot || $custom_remain == yes ]]; then
          continue
        elif systemctl is-active --quiet "$unit"; then
          selected["$unit"]=1
        else
          unclassified+=("$unit")
        fi
      fi ;;
  esac
done < <(systemctl list-unit-files --type=service --no-legend --no-pager)

# PostgreSQL's parent service is a oneshot; its cluster units own the processes.
if command -v pg_lsclusters >/dev/null 2>&1; then
  pg_lsclusters > "$backup/postgresql-clusters-before.txt"
  while read -r version cluster _; do
    [[ $version =~ ^[0-9]+$ && -n $cluster ]] || continue
    selected["postgresql@${version}-${cluster}.service"]=1
  done < <(pg_lsclusters --no-header)
fi

while IFS= read -r unit; do
  load=$(systemctl show "$unit" -p LoadState --value)
  [[ $load == loaded ]] || { issues+=("$unit: not loaded or masked"); continue; }
  type=$(systemctl show "$unit" -p Type --value)
  remain=$(systemctl show "$unit" -p RemainAfterExit --value)
  systemctl show "$unit" -p FragmentPath -p UnitFileState -p Type -p Restart -p RestartUSec > "$backup/$unit.before.txt"
  # Wrappers such as postgresql.service must not get Restart=always.
  if [[ $type != oneshot && $remain != yes ]]; then
    dropdir="/etc/systemd/system/$unit.d"
    install -d -m 755 "$dropdir"
    dropfile="$dropdir/99-runs-server-recovery.conf"
    if [[ -e $dropfile ]]; then
      cp -a "$dropfile" "$backup/$unit.previous-dropin.conf"
    else
      touch "$backup/$unit.dropin-was-absent"
    fi
    cat > "$dropfile" <<'UNIT'
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=30s
UNIT
    chmod 644 "$dropfile"
  fi
  managed+=("$unit")
done < <(printf '%s\n' "${!selected[@]}" | sort)

systemctl daemon-reload
for unit in "${managed[@]}"; do
  if ! systemctl enable "$unit"; then issues+=("$unit: could not enable at boot"); fi
  systemctl reset-failed "$unit" || true
  # Start stopped services; leave healthy running processes in place.
  if ! systemctl start --no-block "$unit"; then issues+=("$unit: could not queue startup"); fi
done

# Wait briefly for Docker to become available, without restarting the daemon.
docker_ready=no
if command -v docker >/dev/null 2>&1; then
  for (( attempt=0; attempt<15; attempt++ )); do
    if timeout 3s docker info >/dev/null 2>&1; then docker_ready=yes; break; fi
    sleep 2
  done
  if [[ $docker_ready == yes ]]; then
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "$backup/containers-before.txt"
    mapfile -t containers < <(docker ps -aq)
    declare -a selected_containers=()
    for id in "${containers[@]}"; do
      name=$(docker inspect -f '{{.Name}}' "$id"); name=${name#/}
      status=$(docker inspect -f '{{.State.Status}}' "$id")
      policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id")
      retries=$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$id")
      oneoff=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' "$id")
      [[ ${oneoff,,} != true ]] || { printf 'SKIP one-off container: %s\n' "$name"; continue; }
      choose=no
      case "$name" in
        portainer|runs-app|runs-ai-analyzer|eventstracker|dbcleaner|sathishlogger|rabbitmq|runs-ai-analyzer-db|config-server|watchtower|cadvisor|diagram-maker|alloy|loki) choose=yes ;;
      esac
      if [[ $status == running || $status == restarting || $policy == always || $policy == unless-stopped || $policy == on-failure ]]; then choose=yes; fi
      if [[ $choose != yes ]]; then
        printf 'REVIEW stopped container (no existing recovery policy): %s\n' "$name"
        continue
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$policy" "$retries" "$status" >> "$backup/container-policies-before.tsv"
      if ! docker update --restart=always "$id"; then issues+=("$name: restart policy update failed"); continue; fi
      selected_containers+=("$id")
    done
    # Start the database and broker before applications when present.
    for priority in runs-ai-analyzer-db rabbitmq; do
      for id in "${selected_containers[@]}"; do
        name=$(docker inspect -f '{{.Name}}' "$id")
        if [[ $name == "/$priority" ]] && [[ $(docker inspect -f '{{.State.Status}}' "$id") == exited || $(docker inspect -f '{{.State.Status}}' "$id") == created ]]; then
          docker start "$id" || issues+=("$priority: startup failed")
        fi
      done
    done
    for id in "${selected_containers[@]}"; do
      status=$(docker inspect -f '{{.State.Status}}' "$id")
      if [[ $status == exited || $status == created ]]; then
        docker start "$id" || issues+=("$id: startup failed")
      fi
    done
  else
    issues+=("Docker did not become available; container policies were not changed")
  fi
fi

printf '\nSERVICE RECOVERY SETTINGS\n'
for unit in "${managed[@]}"; do
  printf '\n%s\n' "$unit"
  systemctl show "$unit" -p UnitFileState -p ActiveState -p SubState -p Restart -p RestartUSec
done
if [[ $docker_ready == yes ]]; then
  printf '\nCONTAINER RECOVERY SETTINGS\n'
  for id in "${selected_containers[@]}"; do
    docker inspect -f '{{.Name}} status={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}}{{if .State.Health}} health={{.State.Health.Status}}{{end}}' "$id"
  done
fi
if (( ${#unclassified[@]} )); then
  printf '\nREVIEW: stopped custom services whose purpose was not identified (not changed):\n'
  printf '%s\n' "${unclassified[@]}"
fi
printf '\nALL FAILED SERVICES\n'
systemctl --failed --no-pager || true
if (( ${#issues[@]} )); then
  printf '\nSETUP ISSUES\n'
  printf '%s\n' "${issues[@]}"
fi
printf '\nReport and previous settings: %s\n' "$backup"
printf 'Queued services may still be starting. No reboot or crash test was performed.\n'
printf 'For recreated Compose services, also set restart: always in the source compose.yaml.\n'
printf 'Recovery covers boot and process exits, not hangs, power restoration, or corrupt data.\n'
(( ${#issues[@]} == 0 ))
