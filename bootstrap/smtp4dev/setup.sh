#!/usr/bin/env bash
# Provisions smtp4dev on the services VM (vmid 114, IP .22).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/smtp4dev/setup.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (Zone.DNS Edit)
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt notifications
#
# Optional env vars (auto-generated if unset):
#   SMTP4DEV_BASIC_USER  - default: admin
#   SMTP4DEV_BASIC_PASS  - generated random 32-char if unset
#
# Optional knobs:
#   SMTP4DEV_DOMAIN      - default: smtp4dev.internal.prakash.com.br
#   SMTP4DEV_SSH         - default: deployer@192.168.20.22
#   SMTP4DEV_VERSION     - default: 3.6.1
#   SMTP4DEV_SMTP_PORT   - default: 2525
#   SMTP4DEV_HTTP_PORT   - default: 5080 (loopback, fronted by shared nginx)
#   SMTP4DEV_VM_IP       - IP to point the domain at (default: 192.168.20.22)
#   SKIP_DNS=1           - Skip Cloudflare DNS automation
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
  # Mirrors bootstrap/garage/setup.sh — longest-suffix match across CF zones.
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

SMTP4DEV_SSH="${SMTP4DEV_SSH:-deployer@192.168.20.22}"
SMTP4DEV_VM_IP="${SMTP4DEV_VM_IP:-192.168.20.22}"
export SMTP4DEV_DOMAIN="${SMTP4DEV_DOMAIN:-smtp4dev.internal.prakash.com.br}"
export SMTP4DEV_VERSION="${SMTP4DEV_VERSION:-3.6.1}"
export SMTP4DEV_SMTP_PORT="${SMTP4DEV_SMTP_PORT:-2525}"
export SMTP4DEV_HTTP_PORT="${SMTP4DEV_HTTP_PORT:-5080}"
export SMTP4DEV_BASIC_USER="${SMTP4DEV_BASIC_USER:-admin}"
export SMTP4DEV_BASIC_PASS="${SMTP4DEV_BASIC_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  smtp4dev Setup"
echo "  Target:   ${SMTP4DEV_SSH}"
echo "  Domain:   ${SMTP4DEV_DOMAIN}"
echo "  Version:  ${SMTP4DEV_VERSION}"
echo "  SMTP:     ${SMTP4DEV_VM_IP}:${SMTP4DEV_SMTP_PORT}"
echo "=============================================="
echo ""

wait_ssh "$SMTP4DEV_SSH"

# DNS record — auto-created via Cloudflare
if [[ "${SKIP_DNS:-0}" == "1" ]]; then
  echo "==> SKIP_DNS=1 — skipping Cloudflare A-record step"
  echo "    Manually ensure: ${SMTP4DEV_DOMAIN} -> ${SMTP4DEV_VM_IP}"
else
  command -v jq >/dev/null || { echo "Error: 'jq' is required for DNS automation"; exit 1; }
  echo "==> Resolving Cloudflare zone for ${SMTP4DEV_DOMAIN}..."
  ZONE_ID="$(get_zone_id "$SMTP4DEV_DOMAIN")"
  if [[ -z "$ZONE_ID" ]]; then
    echo "Error: no Cloudflare zone found for ${SMTP4DEV_DOMAIN}." >&2
    echo "  The CF_API_TOKEN must have Zone.Read for the parent zone, and the" >&2
    echo "  zone must already exist in your Cloudflare account." >&2
    echo "  Set SKIP_DNS=1 to bypass and create the record manually." >&2
    exit 1
  fi
  echo "  Zone: ${ZONE_ID}"
  echo "==> Ensuring A record ${SMTP4DEV_DOMAIN} -> ${SMTP4DEV_VM_IP}..."
  ensure_a_record "$ZONE_ID" "$SMTP4DEV_DOMAIN" "$SMTP4DEV_VM_IP"
fi

echo ""
echo "==> Running smtp4dev install on VM..."
REMOTE_HOST="$SMTP4DEV_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  smtp4dev setup complete!"
echo "=============================================="
echo ""
echo "  Web UI:        https://${SMTP4DEV_DOMAIN}"
echo "    user:        ${SMTP4DEV_BASIC_USER}"
echo "    pass:        ${SMTP4DEV_BASIC_PASS}"
echo ""
echo "  SMTP endpoint: ${SMTP4DEV_VM_IP}:${SMTP4DEV_SMTP_PORT}  (and ${SMTP4DEV_VM_IP}:587)"
echo "    No auth, no TLS. Reachable on the 192.168.20.0/24 LAN — point any"
echo "    app's SMTP_HOST/PORT at this for dev email capture."
echo ""
echo "  Store credentials in Infisical (project homeserver, path /smtp4dev/):"
echo "    SMTP4DEV_BASIC_USER=${SMTP4DEV_BASIC_USER}"
echo "    SMTP4DEV_BASIC_PASS=${SMTP4DEV_BASIC_PASS}"
echo ""
