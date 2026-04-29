#!/usr/bin/env bash
# Provisions the k3s VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/k3s/setup.sh
#
# Required env vars (for cloudflared step):
#   CF_API_TOKEN  - Cloudflare API token with Zone.DNS Edit permissions
#
# Optional env vars:
#   K3S_SSH       - SSH target (default: deployer@192.168.20.11)
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

K3S_SSH="${K3S_SSH:-deployer@192.168.20.11}"

echo "=============================================="
echo "  K3s Cluster Setup"
echo "  Target: ${K3S_SSH}"
echo "=============================================="
echo ""

wait_ssh "$K3S_SSH"

# -----------------------------------------------------------------------------
# Phase 1: Core infrastructure
# -----------------------------------------------------------------------------
echo "[1/6] Installing K3s + Helm..."
REMOTE_HOST="$K3S_SSH" bash "${SCRIPT_DIR}/k3s-install.sh"

echo ""
echo "[2/6] Installing ingress-nginx..."
REMOTE_HOST="$K3S_SSH" bash "${SCRIPT_DIR}/ingress-nginx-install.sh"

echo ""
echo "[3/6] Installing Argo CD..."
REMOTE_HOST="$K3S_SSH" bash "${SCRIPT_DIR}/argocd-install.sh"

# -----------------------------------------------------------------------------
# Phase 2: Operators
# -----------------------------------------------------------------------------
echo ""
echo "[4/6] Installing External Secrets Operator..."
REMOTE_HOST="$K3S_SSH" bash "${SCRIPT_DIR}/external-secrets-install.sh"

echo ""
echo "[5/6] Installing Argo CD Image Updater..."
REMOTE_HOST="$K3S_SSH" bash "${SCRIPT_DIR}/argocd-image-updater-install.sh"

# -----------------------------------------------------------------------------
# Phase 3: Networking
# -----------------------------------------------------------------------------
echo ""
echo "[6/6] Installing + configuring Cloudflare Tunnel..."
REMOTE_HOST="$K3S_SSH" bash "${SCRIPT_DIR}/cloudflared-install.sh"

# cloudflared-config.sh already runs locally (it SSHes in itself)
CF_API_TOKEN="${CF_API_TOKEN:-}" K3S_SSH="$K3S_SSH" \
  bash "${SCRIPT_DIR}/cloudflared-config.sh"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  K3s setup complete!"
echo "=============================================="
echo ""
echo "Manual post-steps:"
echo ""
echo "  1. Create Infisical credentials secret:"
echo "     (set INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET first)"
echo "     ssh ${K3S_SSH} \\"
echo "       'sudo kubectl create secret generic infisical-credentials \\"
echo "         --namespace external-secrets \\"
echo "         --from-literal=clientId=\$INFISICAL_CLIENT_ID \\"
echo "         --from-literal=clientSecret=\$INFISICAL_CLIENT_SECRET'"
echo ""
echo "  2. Configure Argo CD GitHub repository access (interactive):"
echo "     REMOTE_HOST=${K3S_SSH} bash ${SCRIPT_DIR}/argocd-github-setup.sh"
echo ""
echo "  3. Set up persistent storage (if not already done):"
echo "     bash ${SCRIPT_DIR}/persistent-storage-setup.sh"
echo ""
echo "  4. Argo CD admin password:"
echo "     ssh ${K3S_SSH} \"sudo kubectl -n argocd get secret argocd-initial-admin-secret \\"
echo "       -o jsonpath='{.data.password}' | base64 -d && echo\""
echo "     URL: https://192.168.20.11:30443"
echo ""
