#!/usr/bin/env bash
# Provisions Garage + garage-ui on the services VM (vmid 114, IP .22).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/garage/setup.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (used on the VM by certbot for the
#                          DNS-01 challenge; no DNS records are created by this script —
#                          A records are managed in terraform/cloudflare-dns.tf)
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt notifications
#
# Optional env vars (auto-generated if unset):
#   GARAGE_RPC_SECRET    - 64-char hex
#   GARAGE_ADMIN_TOKEN   - random token (also used as the garage-ui login token)
#
# Optional knobs:
#   GARAGE_DOMAIN        - default: garage.internal.prakash.com.br
#   GARAGE_UI_DOMAIN     - default: garage-ui.internal.prakash.com.br
#   GARAGE_SSH           - default: deployer@192.168.20.22
#   GARAGE_VERSION       - default: v2.3.0 (must be v2.1.0+ for the UI)
#   GARAGE_UI_VERSION    - default: latest
#   GARAGE_DATA_DEVICE   - default: /dev/sdb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_env() {
  local missing=()
  for var in "$@"; do [[ -z "${!var:-}" ]] && missing+=("$var"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required environment variables: ${missing[*]}"; exit 1
  fi
}
wait_ssh() {
  local host="$1" timeout="${2:-120}" elapsed=0
  echo "Waiting for SSH on ${host}..."
  while ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" true 2>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then echo "Error: SSH not available on ${host} after ${timeout}s"; exit 1; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "✓ SSH ready"
}
GARAGE_SSH="${GARAGE_SSH:-deployer@192.168.20.22}"
export GARAGE_DOMAIN="${GARAGE_DOMAIN:-garage.internal.prakash.com.br}"
export GARAGE_UI_DOMAIN="${GARAGE_UI_DOMAIN:-garage-ui.internal.prakash.com.br}"
export GARAGE_VERSION="${GARAGE_VERSION:-v2.3.0}"
# Default to the camilohollanda fork (adds object-level delete on top of
# Noooste's UI). Override both to switch back to upstream:
#   GARAGE_UI_IMAGE=noooste/garage-ui GARAGE_UI_VERSION=latest
export GARAGE_UI_IMAGE="${GARAGE_UI_IMAGE:-ghcr.io/camilohollanda/garage-ui}"
export GARAGE_UI_VERSION="${GARAGE_UI_VERSION:-bulk-delete}"
export GARAGE_DATA_DEVICE="${GARAGE_DATA_DEVICE:-/dev/sdb}"
export GARAGE_RPC_SECRET="${GARAGE_RPC_SECRET:-$(openssl rand -hex 32)}"
export GARAGE_ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  Garage + garage-ui Setup"
echo "  Target:    ${GARAGE_SSH}"
echo "  S3:        ${GARAGE_DOMAIN}        (Garage ${GARAGE_VERSION})"
echo "  Web UI:    ${GARAGE_UI_DOMAIN}     (garage-ui ${GARAGE_UI_VERSION})"
echo "  Data:      ${GARAGE_DATA_DEVICE} (in VM)"
echo "=============================================="
echo ""

wait_ssh "$GARAGE_SSH"

# DNS for both FQDNs is managed by terraform/cloudflare-dns.tf
# (resource cloudflare_dns_record.internal_a["garage"] and ["garage_ui"]).
# Make sure both records exist before running this script — otherwise
# certbot's DNS-01 challenge will still work but the services won't be
# reachable by name on the LAN.

echo "==> Sanity check: data disk attached to VM?"
if ! ssh "$GARAGE_SSH" "test -b ${GARAGE_DATA_DEVICE}"; then
  cat <<EOF >&2
Error: ${GARAGE_DATA_DEVICE} not present on ${GARAGE_SSH}.

Attach a virtio disk to VM 114 in Proxmox first:
  - Storage: tank (ZFS pool on the host's 4TB HDD)
  - Size:    500G
  - Bus:     virtio-blk

After attach, the VM should see it without reboot. If not, hot-rescan with:
  echo 1 > /sys/class/block/sdX/device/rescan
EOF
  exit 1
fi
echo "  ✓ ${GARAGE_DATA_DEVICE} present"

echo ""
echo "==> Running Garage + garage-ui install on VM..."
REMOTE_HOST="$GARAGE_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Garage + garage-ui setup complete!"
echo "=============================================="
echo ""
echo "  S3 endpoint: https://${GARAGE_DOMAIN}"
echo "  Web UI:      https://${GARAGE_UI_DOMAIN}"
echo "               Log in with the Garage admin token below."
echo "  Region:      garage"
echo ""
echo "  Generated secrets — store in Infisical (project homeserver, path /Garage/):"
echo "    GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET}"
echo "    GARAGE_ADMIN_TOKEN=${GARAGE_ADMIN_TOKEN}"
echo ""
echo "  Per-app credentials:"
echo "    ssh ${GARAGE_SSH} sudo docker exec garage /garage bucket create <app>"
echo "    ssh ${GARAGE_SSH} sudo docker exec garage /garage key create <app>-key"
echo "    ssh ${GARAGE_SSH} sudo docker exec garage /garage bucket allow --read --write --owner <app> --key <app>-key"
echo ""
