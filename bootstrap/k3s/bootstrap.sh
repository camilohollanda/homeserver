#!/bin/bash
set -euo pipefail

# =============================================================================
# K3s Cluster Bootstrap
# =============================================================================
# This script orchestrates the complete cluster setup in the correct order.
# Run this once after Terraform provisions the k3s-apps VM.
#
# Usage: sudo ./bootstrap.sh
# =============================================================================

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================="
echo "  K3s Cluster Bootstrap"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# Phase 1: Core Infrastructure
# -----------------------------------------------------------------------------
echo "[1/6] Installing K3s..."
"${SCRIPT_DIR}/k3s-install.sh"

echo ""
echo "[2/6] Installing ingress-nginx..."
"${SCRIPT_DIR}/ingress-nginx-install.sh"

echo ""
echo "[3/6] Installing ArgoCD..."
"${SCRIPT_DIR}/argocd-install.sh"

# -----------------------------------------------------------------------------
# Phase 2: Operators (Helm-based infrastructure)
# -----------------------------------------------------------------------------
echo ""
echo "[4/6] Installing External Secrets Operator..."
"${SCRIPT_DIR}/external-secrets-install.sh"

echo ""
echo "[5/6] Installing ArgoCD Image Updater..."
"${SCRIPT_DIR}/argocd-image-updater-install.sh"

# -----------------------------------------------------------------------------
# Phase 3: Networking
# -----------------------------------------------------------------------------
echo ""
echo "[6/6] Setting up Cloudflare Tunnel..."
"${SCRIPT_DIR}/cloudflared-install.sh"
"${SCRIPT_DIR}/cloudflared-config.sh"

# -----------------------------------------------------------------------------
# Done!
# -----------------------------------------------------------------------------
echo ""
echo "=============================================="
echo "  Bootstrap Complete!"
echo "=============================================="
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Verify services are running:"
echo "   kubectl get pods -A"
echo ""
echo "2. Create Infisical credentials for External Secrets:"
echo "   kubectl create secret generic infisical-credentials \\"
echo "     --namespace external-secrets \\"
echo "     --from-literal=clientId=\"\$INFISICAL_CLIENT_ID\" \\"
echo "     --from-literal=clientSecret=\"\$INFISICAL_CLIENT_SECRET\""
echo ""
echo "3. Configure GitHub repository access for ArgoCD:"
echo "   sudo ./argocd-github-setup.sh"
echo ""
echo "4. Access ArgoCD:"
echo "   Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo "   URL: https://192.168.20.11:30443"
echo ""
echo "5. Apply GitOps manifests via ArgoCD"
echo ""
