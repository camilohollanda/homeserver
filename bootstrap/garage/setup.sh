#!/usr/bin/env bash
# Provisions Garage on the services VM (vmid 114, IP .22).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/garage/setup.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (Zone.DNS Edit)
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt notifications
#
# Optional env vars (auto-generated if unset):
#   GARAGE_RPC_SECRET    - 64-char hex
#   GARAGE_ADMIN_TOKEN   - random token
#
# Optional knobs:
#   GARAGE_DOMAIN        - default: garage.internal.prakash.com.br
#   GARAGE_SSH           - default: deployer@192.168.20.22
#   GARAGE_VERSION       - default: v1.0.1
#   GARAGE_DATA_DEVICE   - default: /dev/sdb
#   GARAGE_VM_IP         - IP to point garage.internal at (default: 192.168.20.22)
#   SKIP_DNS=1           - Skip Cloudflare DNS automation (default: auto-created)
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
get_zone_id() {
  # Look up the Cloudflare zone whose name is the longest suffix of $1.
  # Mirrors the helper in bootstrap/k3s/cloudflared-config.sh.
  local domain="$1"
  domain="${domain#\*.}"

  local zones
  zones=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  if [ "$(echo "$zones" | jq -r '.success')" != "true" ]; then
    echo "Error: Cloudflare zones lookup failed." >&2
    echo "$zones" | jq -r '.errors[]? | "  - \(.message)"' >&2
    return 1
  fi

  local best_id="" best_name=""
  while IFS=$'\t' read -r id name; do
    if [[ "$domain" == "$name" ]] || [[ "$domain" == *".$name" ]]; then
      if [ ${#name} -gt ${#best_name} ]; then
        best_id="$id"; best_name="$name"
      fi
    fi
  done < <(echo "$zones" | jq -r '.result[] | "\(.id)\t\(.name)"')

  echo "$best_id"
}
ensure_a_record() {
  local zone_id="$1" hostname="$2" ip="$3" existing record_id
  existing=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${hostname}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")
  if [ "$(echo "$existing" | jq -r '.success')" != "true" ]; then
    echo "Error: Cloudflare DNS query failed for ${hostname}." >&2
    echo "$existing" | jq -r '.errors[]? | "  - \(.message)"' >&2
    return 1
  fi
  record_id=$(echo "$existing" | jq -r '.result[0].id // empty')
  if [ -n "$record_id" ]; then
    echo "  Updating A record: ${hostname} -> ${ip}"
    curl -s -X PUT \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${hostname}\",\"content\":\"${ip}\",\"ttl\":1}" \
      | jq -e '.success' >/dev/null
  else
    echo "  Creating A record: ${hostname} -> ${ip}"
    curl -s -X POST \
      "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${hostname}\",\"content\":\"${ip}\",\"ttl\":1}" \
      | jq -e '.success' >/dev/null
  fi
}

GARAGE_SSH="${GARAGE_SSH:-deployer@192.168.20.22}"
GARAGE_VM_IP="${GARAGE_VM_IP:-192.168.20.22}"
export GARAGE_DOMAIN="${GARAGE_DOMAIN:-garage.internal.prakash.com.br}"
export GARAGE_VERSION="${GARAGE_VERSION:-v1.0.1}"
export GARAGE_DATA_DEVICE="${GARAGE_DATA_DEVICE:-/dev/sdb}"
export GARAGE_RPC_SECRET="${GARAGE_RPC_SECRET:-$(openssl rand -hex 32)}"
export GARAGE_ADMIN_TOKEN="${GARAGE_ADMIN_TOKEN:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  Garage Setup"
echo "  Target:  ${GARAGE_SSH}"
echo "  Domain:  ${GARAGE_DOMAIN}"
echo "  Version: ${GARAGE_VERSION}"
echo "  Data:    ${GARAGE_DATA_DEVICE} (in VM)"
echo "=============================================="
echo ""

wait_ssh "$GARAGE_SSH"

# DNS record — auto-created via Cloudflare (zone resolved from GARAGE_DOMAIN)
if [[ "${SKIP_DNS:-0}" == "1" ]]; then
  echo "==> SKIP_DNS=1 — skipping Cloudflare A-record step"
  echo "    Manually ensure: ${GARAGE_DOMAIN} -> ${GARAGE_VM_IP}"
else
  command -v jq >/dev/null || { echo "Error: 'jq' is required for DNS automation"; exit 1; }
  echo "==> Resolving Cloudflare zone for ${GARAGE_DOMAIN}..."
  ZONE_ID="$(get_zone_id "$GARAGE_DOMAIN")"
  if [[ -z "$ZONE_ID" ]]; then
    echo "Error: no Cloudflare zone found for ${GARAGE_DOMAIN}." >&2
    echo "  The CF_API_TOKEN must have Zone.Read for the parent zone, and the" >&2
    echo "  zone must already exist in your Cloudflare account." >&2
    echo "  Set SKIP_DNS=1 to bypass and create the record manually." >&2
    exit 1
  fi
  echo "  Zone: ${ZONE_ID}"
  echo "==> Ensuring A record ${GARAGE_DOMAIN} -> ${GARAGE_VM_IP}..."
  ensure_a_record "$ZONE_ID" "$GARAGE_DOMAIN" "$GARAGE_VM_IP"
fi

echo ""
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
echo "==> Running Garage install on VM..."
REMOTE_HOST="$GARAGE_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Garage setup complete!"
echo "=============================================="
echo ""
echo "  S3 endpoint: https://${GARAGE_DOMAIN}"
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
