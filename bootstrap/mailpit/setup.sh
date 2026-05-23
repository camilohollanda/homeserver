#!/usr/bin/env bash
# Provisions Mailpit on the services VM (vmid 114, IP .22).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/mailpit/setup.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (used on the VM by certbot for the
#                          DNS-01 challenge; no DNS records are created by this script —
#                          A records are managed in terraform/cloudflare-dns.tf)
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
MAILPIT_SSH="${MAILPIT_SSH:-deployer@192.168.20.22}"
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

# DNS for ${MAILPIT_DOMAIN} is managed by terraform/cloudflare-dns.tf
# (resource cloudflare_dns_record.internal_a["mailpit"]).

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
