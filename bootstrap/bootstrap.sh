#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting bootstrap process..."

"${SCRIPT_DIR}/k3s-install.sh"
"${SCRIPT_DIR}/ingress-nginx-install.sh"
"${SCRIPT_DIR}/argocd-install.sh"
"${SCRIPT_DIR}/cloudflared-install.sh"
"${SCRIPT_DIR}/cloudflared-config.sh"

echo "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "1. Cloudflare Tunnel: The cloudflared service should be running automatically."
echo "   Check status: systemctl status cloudflared"
echo "   View logs: journalctl -u cloudflared -f"
echo ""
echo "2. Access Argo CD:"
echo "   Get admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo "   Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443 --address=0.0.0.0"
echo "   Access: https://localhost:8080 (username: admin)"
echo ""
echo "3. Configure GitOps repositories in Argo CD"
