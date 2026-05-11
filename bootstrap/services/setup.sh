#!/usr/bin/env bash
# Provisions the shared services proxy (shared nginx + cert tooling) on the
# services VM. Runs from your local machine.
#
# Usage:
#   ./bootstrap/services/setup.sh
#
# Required env vars:
#   CF_API_TOKEN       - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL  - Email for Let's Encrypt notifications
#
# Optional:
#   SERVICES_SSH       - SSH target (default: deployer@192.168.20.22)
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

SERVICES_SSH="${SERVICES_SSH:-deployer@192.168.20.22}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  Shared services proxy setup"
echo "  Target: ${SERVICES_SSH}"
echo "=============================================="
echo ""

wait_ssh "$SERVICES_SSH"

echo ""
echo "==> Running services install on VM..."
REMOTE_HOST="$SERVICES_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Shared services proxy ready."
echo "=============================================="
echo ""
echo "  Next: re-run app installs (bootstrap/infisical, bootstrap/garage, ...)"
echo "  to register their vhosts in /opt/services/conf.d/."
