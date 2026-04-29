#!/usr/bin/env bash
# Provisions the postgres VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/postgres/setup.sh
#
# Required env vars:
#   CF_API_TOKEN       - Cloudflare API token (Zone.DNS Edit)
#   PG_DOMAIN          - FQDN for the VM (e.g. pg.internal.prakash.com.br)
#   LETSENCRYPT_EMAIL  - Email for Let's Encrypt notifications
#
# Optional env vars:
#   POSTGRES_SSH       - SSH target (default: deployer@192.168.20.21)
#   PG_VERSION         - PostgreSQL major version (default: 17)
#   ALLOWED_NETWORK    - CIDR allowed to connect (default: 192.168.20.0/24)
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

POSTGRES_SSH="${POSTGRES_SSH:-deployer@192.168.20.21}"

check_env CF_API_TOKEN PG_DOMAIN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  PostgreSQL Setup"
echo "  Target: ${POSTGRES_SSH}"
echo "=============================================="
echo ""

wait_ssh "$POSTGRES_SSH"

REMOTE_HOST="$POSTGRES_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  PostgreSQL setup complete!"
echo "=============================================="
echo ""
echo "To provision a database for an app, run locally:"
echo "  POSTGRES_SSH=${POSTGRES_SSH} ./bootstrap/postgres/pg-provision.sh <app> --env prod"
echo ""
