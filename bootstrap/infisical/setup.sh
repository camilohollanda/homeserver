#!/usr/bin/env bash
# Provisions the Infisical VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/infisical/setup.sh
#
# Required env vars:
#   CF_API_TOKEN             - Cloudflare API token (Zone.DNS Edit)
#   INFISICAL_DOMAIN         - FQDN (e.g. infisical.internal.prakash.com.br)
#   LETSENCRYPT_EMAIL        - Email for Let's Encrypt notifications
#   INFISICAL_ENCRYPTION_KEY - 16-byte hex encryption key (generate: openssl rand -hex 16)
#   INFISICAL_AUTH_SECRET    - JWT secret (generate: openssl rand -base64 32)
#   INFISICAL_DB_URI         - postgres://user:pass@host:5432/infisical
#
# Optional env vars:
#   INFISICAL_SSH            - SSH target (default: deployer@192.168.20.22)
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

INFISICAL_SSH="${INFISICAL_SSH:-deployer@192.168.20.22}"

check_env CF_API_TOKEN INFISICAL_DOMAIN LETSENCRYPT_EMAIL \
          INFISICAL_ENCRYPTION_KEY INFISICAL_AUTH_SECRET INFISICAL_DB_URI

echo "=============================================="
echo "  Infisical Setup"
echo "  Target: ${INFISICAL_SSH}"
echo "=============================================="
echo ""

wait_ssh "$INFISICAL_SSH"

echo "==> Provisioning Infisical database on postgres VM..."
echo "    (requires POSTGRES_SSH and the postgres VM to be running)"
POSTGRES_SSH="${POSTGRES_SSH:-deployer@192.168.20.21}"
DB_NAME=infisical DB_USER=infisical \
  DB_PASSWORD="$(echo "$INFISICAL_DB_URI" | grep -oP '(?<=:)[^@]+(?=@)')" \
  REMOTE_HOST="$POSTGRES_SSH" bash "${SCRIPT_DIR}/db-setup.sh"

echo ""
echo "==> Running Infisical install on VM..."
REMOTE_HOST="$INFISICAL_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Infisical setup complete!"
echo "=============================================="
echo ""
echo "  URL: https://${INFISICAL_DOMAIN}"
echo ""
echo "  On first visit, create your admin account at the URL above."
echo ""
