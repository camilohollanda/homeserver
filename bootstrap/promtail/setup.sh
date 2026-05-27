#!/usr/bin/env bash
# Provisions Promtail on the services VM (vmid 114, IP .22).
# Tails Docker container logs and ships them to the Loki NodePort in k3s.
#
# Usage:
#   ./bootstrap/promtail/setup.sh
#
# Required env vars: (none)
#
# Optional knobs:
#   PROMTAIL_SSH       - default: deployer@192.168.20.22
#   PROMTAIL_VERSION   - default: 3.6.3 (matches gitops/loki-stack/promtail.yaml)
#   LOKI_URL           - default: http://192.168.20.11:31100/loki/api/v1/push
#   PROMTAIL_HOSTNAME  - 'host' label in Loki (default: services)
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

PROMTAIL_SSH="${PROMTAIL_SSH:-deployer@192.168.20.22}"
export PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.6.3}"
export LOKI_URL="${LOKI_URL:-http://192.168.20.11:31100/loki/api/v1/push}"
export PROMTAIL_HOSTNAME="${PROMTAIL_HOSTNAME:-services}"

echo "=============================================="
echo "  Promtail Setup"
echo "  Target:    ${PROMTAIL_SSH}"
echo "  Version:   ${PROMTAIL_VERSION}"
echo "  Loki URL:  ${LOKI_URL}"
echo "  Host tag:  ${PROMTAIL_HOSTNAME}"
echo "=============================================="
echo ""

wait_ssh "$PROMTAIL_SSH"

echo "==> Running Promtail install on VM..."
REMOTE_HOST="$PROMTAIL_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Promtail setup complete!"
echo "=============================================="
echo ""
echo "  Query in Grafana (Explore → Loki datasource):"
echo "    {host=\"${PROMTAIL_HOSTNAME}\"}                       # everything on this VM"
echo "    {host=\"${PROMTAIL_HOSTNAME}\", container=\"garage\"}  # just Garage"
echo ""
echo "  Nothing to store in Infisical — this stack has no secrets."
echo ""
