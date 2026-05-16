#!/usr/bin/env bash
# Provisions Mailpit on the services VM (vmid 114, IP .22).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/mailpit/setup.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (Zone.DNS Edit)
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt notifications
#
# Optional env vars (auto-generated if unset):
#   MAILPIT_BASIC_USER   - default: admin
#   MAILPIT_BASIC_PASS   - generated random 32-char if unset
#
# Optional knobs:
#   MAILPIT_DOMAIN       - default: mailpit.internal.prakash.com.br
#   MAILPIT_SSH          - default: deployer@192.168.20.22
#   MAILPIT_VERSION      - default: v1.20.7
#   MAILPIT_SMTP_PORT    - default: 2525
#   MAILPIT_HTTP_PORT    - default: 5080 (loopback, fronted by shared nginx)
#   MAILPIT_VM_IP        - IP to point the domain at (default: 192.168.20.22)
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

MAILPIT_SSH="${MAILPIT_SSH:-deployer@192.168.20.22}"
MAILPIT_VM_IP="${MAILPIT_VM_IP:-192.168.20.22}"
export MAILPIT_DOMAIN="${MAILPIT_DOMAIN:-mailpit.internal.prakash.com.br}"
export MAILPIT_VERSION="${MAILPIT_VERSION:-v1.20.7}"
export MAILPIT_SMTP_PORT="${MAILPIT_SMTP_PORT:-2525}"
export MAILPIT_HTTP_PORT="${MAILPIT_HTTP_PORT:-5080}"
export MAILPIT_BASIC_USER="${MAILPIT_BASIC_USER:-admin}"
export MAILPIT_BASIC_PASS="${MAILPIT_BASIC_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  Mailpit Setup"
echo "  Target:   ${MAILPIT_SSH}"
echo "  Domain:   ${MAILPIT_DOMAIN}"
echo "  Version:  ${MAILPIT_VERSION}"
echo "  SMTP:     ${MAILPIT_VM_IP}:${MAILPIT_SMTP_PORT}"
echo "=============================================="
echo ""

wait_ssh "$MAILPIT_SSH"

# DNS record — auto-created via Cloudflare
if [[ "${SKIP_DNS:-0}" == "1" ]]; then
  echo "==> SKIP_DNS=1 — skipping Cloudflare A-record step"
  echo "    Manually ensure: ${MAILPIT_DOMAIN} -> ${MAILPIT_VM_IP}"
else
  command -v jq >/dev/null || { echo "Error: 'jq' is required for DNS automation"; exit 1; }
  echo "==> Resolving Cloudflare zone for ${MAILPIT_DOMAIN}..."
  ZONE_ID="$(get_zone_id "$MAILPIT_DOMAIN")"
  if [[ -z "$ZONE_ID" ]]; then
    echo "Error: no Cloudflare zone found for ${MAILPIT_DOMAIN}." >&2
    echo "  The CF_API_TOKEN must have Zone.Read for the parent zone, and the" >&2
    echo "  zone must already exist in your Cloudflare account." >&2
    echo "  Set SKIP_DNS=1 to bypass and create the record manually." >&2
    exit 1
  fi
  echo "  Zone: ${ZONE_ID}"
  echo "==> Ensuring A record ${MAILPIT_DOMAIN} -> ${MAILPIT_VM_IP}..."
  ensure_a_record "$ZONE_ID" "$MAILPIT_DOMAIN" "$MAILPIT_VM_IP"
fi

echo ""
echo "==> Running Mailpit install on VM..."
REMOTE_HOST="$MAILPIT_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Mailpit setup complete!"
echo "=============================================="
echo ""
echo "  Web UI:        https://${MAILPIT_DOMAIN}"
echo "    user:        ${MAILPIT_BASIC_USER}"
echo "    pass:        ${MAILPIT_BASIC_PASS}"
echo ""
echo "  SMTP endpoint: ${MAILPIT_DOMAIN}:${MAILPIT_SMTP_PORT}  (and ${MAILPIT_DOMAIN}:587)"
echo "    STARTTLS + AUTH PLAIN/LOGIN required. Connect by hostname, not IP."
echo "    SMTP user/pass = the web UI user/pass."
echo ""
echo "  Store credentials in Infisical (project homeserver, path /mailpit/):"
echo "    MAILPIT_BASIC_USER=${MAILPIT_BASIC_USER}"
echo "    MAILPIT_BASIC_PASS=${MAILPIT_BASIC_PASS}"
echo ""
