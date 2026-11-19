#!/usr/bin/env bash
# Host firewall (ufw) rules on runs-server, as applied 2026-11-18. Re-running is safe: ufw skips
# rules that already exist. Covers services running on the host itself (native Postgres 5432,
# Ollama, LiteLLM, Prometheus/Alertmanager, exporters, Wazuh, iperf3); Docker-published ports are
# handled by host/ufw/docker-lan.rules instead.
#
# Policy: Tailscale and Docker networks get everything; the LAN gets SSH, Grafana and the Wazuh
# dashboard only. Enabling arms a 10-minute auto-disable first; cancel it only after testing.
set -euo pipefail
[[ $(hostname -s) == runs-server ]] || { echo "Run on runs-server" >&2; exit 1; }
(( EUID == 0 )) || { echo "Run with sudo" >&2; exit 1; }

ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'tailnet: full access'
ufw allow 41641/udp comment 'tailscale direct connections'
ufw allow from 172.16.0.0/12 comment 'docker networks -> host services'
ufw allow from 192.168.4.0/22 to any port 22   proto tcp comment 'LAN ssh'
ufw allow from 192.168.4.0/22 to any port 3000 proto tcp comment 'LAN grafana'
ufw allow from 192.168.4.0/22 to any port 443  proto tcp comment 'LAN wazuh dashboard'

if ufw status | grep -q '^Status: active'; then
  ufw reload
else
  systemd-run --unit=ufw-safety --on-active=10m /usr/sbin/ufw disable
  ufw --force enable
  echo "ufw enabled. Auto-disable in 10 min unless you test and run: systemctl stop ufw-safety.timer"
fi
ufw status numbered
