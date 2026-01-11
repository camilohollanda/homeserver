#!/usr/bin/env bash
#
# Install ArgoCD Image Updater
# This enables automatic image updates for ArgoCD Applications
#
# NOTE: This is infrastructure-level installation done once during bootstrap.
# The operator is installed via Helm, but app-level configs (ImageUpdater CRs)
# are managed in gitops/argocd-image-updater/
#
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

echo "==> Installing ArgoCD Image Updater..."

# Set up kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Install Helm if not available
if ! command -v helm &> /dev/null; then
  echo "==> Helm not found, installing..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Create values file for GHCR registry configuration
cat > /tmp/image-updater-values.yaml << 'EOF'
config:
  registries:
    - name: ghcr
      api_url: https://ghcr.io
      prefix: ghcr.io
      credentials: "secret:argocd/ghcr-image-updater#creds"
EOF

# Install via Helm
helm upgrade --install argocd-image-updater \
  oci://ghcr.io/argoproj/argo-helm/argocd-image-updater \
  --version 1.0.4 \
  --namespace argocd \
  -f /tmp/image-updater-values.yaml \
  --wait

rm /tmp/image-updater-values.yaml

echo "==> ArgoCD Image Updater installed!"
echo ""
echo "Next steps:"
echo "  1. Create GHCR credentials secret (via ExternalSecret or manually)"
echo "  2. Apply ImageUpdater CR from gitops/argocd-image-updater/"
