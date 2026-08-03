#!/usr/bin/env bash
set -euo pipefail

#################################################################
# set-vm-ip.sh — single source of truth for the VM IP
#
# Changes the VM IP in env/vm.env (VM_IP=...) and propagates it to
# every project .env in the workspace by replacing the OLD VM IP
# with the NEW one. Use this whenever the VirtualBox VM's IP changes.
#
# Because the IntelliJ EnvFile plugin loads .env files LITERALLY (no
# ${VAR} interpolation), you cannot reference a shared variable inside
# a JDBC/AMQP URL. This script is the propagation mechanism instead:
# one command re-points DB URLs, RABBITMQ_HOST, CONFIG_SERVER_URL,
# OLLAMA_BASE_URL, *_URL, etc. across all projects at once.
#
# It only swaps the CURRENT VM_IP token — clean up any other stale
# IPs/hostnames first (they won't be matched by an old->new swap).
#
# Usage:
#   ./set-vm-ip.sh <new-ip>        Change VM IP and propagate
#   ./set-vm-ip.sh --dry-run <ip>  Show what would change; write nothing
#   ./set-vm-ip.sh --help
#
# Every modified .env gets a .env.bak backup (same convention as
# vm-db-up.sh). Re-run is safe/idempotent.
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
VM_ENV_FILE="$REPO_ROOT/env/vm.env"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_status() { echo -e "${GREEN}✓${NC} $1"; }
print_error()  { echo -e "${RED}✗${NC} $1" >&2; }
print_info()   { echo -e "${YELLOW}ℹ${NC} $1"; }
die()          { print_error "$1"; exit 1; }

DRY_RUN=false
NEW_IP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --help)    sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)       die "Unknown option: $1" ;;
    *)         NEW_IP="$1"; shift ;;
  esac
done

[ -n "$NEW_IP" ] || die "No IP given. Usage: ./set-vm-ip.sh [--dry-run] <new-ip>  (see --help)"
[[ "$NEW_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Not a valid IPv4 address: $NEW_IP"

[ -f "$VM_ENV_FILE" ] || die "env/vm.env not found at $VM_ENV_FILE"
OLD_IP="$(grep -E '^VM_IP=' "$VM_ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '[:space:]')"
[ -n "$OLD_IP" ] || die "VM_IP not set in $VM_ENV_FILE — set it first, then re-run"

if [ "$OLD_IP" = "$NEW_IP" ]; then
  print_info "VM_IP is already $NEW_IP — nothing to do."
  exit 0
fi

print_info "Propagating VM IP:  $OLD_IP  →  $NEW_IP"
$DRY_RUN && print_info "(--dry-run: no files will be written)"
echo ""

changed=0
# All project .env files in the workspace (skip build/dependency dirs)
while IFS= read -r f; do
  # count occurrences of the old IP in this file
  hits=$(grep -c -F "$OLD_IP" "$f" 2>/dev/null || true)
  [ "${hits:-0}" -gt 0 ] || continue
  changed=$((changed + 1))
  rel="${f#"$WORKSPACE_ROOT"/}"
  if $DRY_RUN; then
    printf "  would update %-55s (%s line(s))\n" "$rel" "$hits"
    grep -nF "$OLD_IP" "$f" | sed 's/^/      /'
  else
    cp "$f" "$f.bak"
    # portable in-place edit (BSD/GNU sed): write to temp, move back
    tmp=$(mktemp)
    sed "s/$OLD_IP/$NEW_IP/g" "$f" > "$tmp" && mv "$tmp" "$f"
    print_status "$rel  ($hits line(s) updated, backup: $(basename "$f").bak)"
  fi
done < <(find "$WORKSPACE_ROOT" -maxdepth 3 -name ".env" \
           -not -path "*/node_modules/*" -not -path "*/target/*" -not -path "*/.git/*" 2>/dev/null | sort)

echo ""
if [ "$changed" -eq 0 ]; then
  print_info "No project .env files contained $OLD_IP. (Are they already updated, or using localhost/other hosts?)"
fi

# Update the source of truth last
if $DRY_RUN; then
  print_info "would set VM_IP=$NEW_IP in env/vm.env"
else
  cp "$VM_ENV_FILE" "$VM_ENV_FILE.bak"
  tmp=$(mktemp)
  sed "s/^VM_IP=.*/VM_IP=$NEW_IP/" "$VM_ENV_FILE" > "$tmp" && mv "$tmp" "$VM_ENV_FILE"
  print_status "env/vm.env → VM_IP=$NEW_IP (backup: vm.env.bak)"
  echo ""
  print_info "Done. $changed project .env file(s) re-pointed to $NEW_IP."
  print_info "Next: redeploy the VM stack if the VM itself moved — ./vm-db-up.sh --prune <projects...>"
fi
