#!/usr/bin/env bash
# Provisions the AI/GPU VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/ai/setup.sh
#
# Required env vars:
#   CF_API_TOKEN      - Cloudflare API token (Zone.DNS Edit)
#   AI_DOMAIN         - FQDN (e.g. ai.internal.prakash.com.br)
#   LETSENCRYPT_EMAIL - Email for Let's Encrypt notifications
#   GITHUB_OWNER      - GitHub username owning the whisper-api image
#   GHCR_USERNAME     - GitHub username for GHCR auth
#   GHCR_TOKEN        - GitHub PAT with packages:read scope
#
# Optional env vars:
#   AI_SSH            - SSH target (default: deployer@192.168.20.30)
#   OLLAMA_MODEL      - Ollama model to pre-pull (default: qwen2.5:3b)
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

AI_SSH="${AI_SSH:-deployer@192.168.20.30}"

check_env CF_API_TOKEN AI_DOMAIN LETSENCRYPT_EMAIL \
          GITHUB_OWNER GHCR_USERNAME GHCR_TOKEN

echo "=============================================="
echo "  AI/GPU Services Setup"
echo "  Target: ${AI_SSH}"
echo "=============================================="
echo ""

wait_ssh "$AI_SSH"

REMOTE_HOST="$AI_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  AI setup complete!"
echo "=============================================="
echo ""
echo "  Container pull + model download runs in the background."
echo "  Follow progress:"
echo "  ssh ${AI_SSH} 'journalctl -u ai-setup.service -f'"
echo ""
echo "  URL: https://${AI_DOMAIN}"
echo ""
