#!/bin/bash
set -euo pipefail

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
echo "1. Configure Cloudflare Tunnel credentials"
echo "2. Start cloudflared service: systemctl enable --now cloudflared"
echo "3. Access Argo CD and configure GitOps repositories"
