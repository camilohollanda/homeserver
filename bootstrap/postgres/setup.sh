#!/usr/bin/env bash
# Provisions the postgres VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/postgres/setup.sh
#
# Optional env vars:
#   POSTGRES_SSH       - SSH target (default: deployer@192.168.20.23 — VM 118)
#   PG_VERSION         - PostgreSQL major version (default: 18)
#   ALLOWED_NETWORK    - CIDR allowed to connect (default: 192.168.20.0/24)
#   RESERVED_ROLES     - roles granted pg_use_reserved_connections (default: infisical)
#
# TLS is deliberately not provisioned — the cluster is LAN-only. See install.sh.
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

POSTGRES_SSH="${POSTGRES_SSH:-deployer@192.168.20.23}"

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
echo "  POSTGRES_SSH=${POSTGRES_SSH} POSTGRES_HOST=192.168.20.23 ./bootstrap/postgres/pg-provision.sh <app> --env prod"
echo ""
