#!/usr/bin/env bash
# Provisions prometheus-postgres-exporter on the database VM.
#
# Usage:
#   ./bootstrap/postgres-exporter/setup.sh
#
# Required env vars: (none -- a password is generated if you don't supply one)
#
# Optional knobs:
#   PG_EXPORTER_TARGET   - ssh target (default: deployer@192.168.20.23)
#   PG_EXPORTER_PORT     - listen port (default: 9187)
#   PG_EXPORTER_PASSWORD - reuse an existing password instead of generating one
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wait_ssh() {
  local host="$1" timeout="${2:-120}" elapsed=0
  echo "Waiting for SSH on ${host}..."
  while ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" true 2>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then echo "Error: SSH not available on ${host} after ${timeout}s"; exit 1; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "✓ SSH ready"
}

PG_EXPORTER_TARGET="${PG_EXPORTER_TARGET:-deployer@192.168.20.23}"
export PG_EXPORTER_PORT="${PG_EXPORTER_PORT:-9187}"

# Re-running with no password generates a new one and rotates the role, which
# is harmless: the exporter is the only thing that authenticates with it.
GENERATED=0
if [[ -z "${PG_EXPORTER_PASSWORD:-}" ]]; then
  PG_EXPORTER_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)"
  GENERATED=1
fi
export PG_EXPORTER_PASSWORD

echo "=============================================="
echo "  postgres_exporter Setup"
echo "  Target: ${PG_EXPORTER_TARGET}"
echo "  Port:   ${PG_EXPORTER_PORT}"
echo "=============================================="
echo ""

wait_ssh "$PG_EXPORTER_TARGET"
REMOTE_HOST="$PG_EXPORTER_TARGET" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  postgres_exporter setup complete"
echo "=============================================="
echo ""
echo "  Add the scrape target if it isn't there yet:"
echo "    gitops/victoria-metrics/scrape-config.yaml  ->  job postgres-exporter"
echo ""
if [[ $GENERATED -eq 1 ]]; then
  echo "  Store in Infisical under /postgres-exporter/:"
  echo "    PG_EXPORTER_PASSWORD=${PG_EXPORTER_PASSWORD}"
  echo ""
  echo "  This is printed once. The role owns nothing and can read only the"
  echo "  statistics views, so losing it costs a re-run of this script and"
  echo "  nothing else."
else
  echo "  Reused the password you supplied; nothing new to store."
fi
echo ""
