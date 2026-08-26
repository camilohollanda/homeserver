#!/usr/bin/env bash
# Runs on the k3s VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.11 ./argocd-image-updater-install.sh
if [[ -n "${REMOTE_HOST:-}" ]]; then
  cat "$0" | ssh "$REMOTE_HOST" "sudo bash -s"; exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
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

# Create values file for both registries. Keeping both active makes a per-app
# cutover reversible: applications that remain on GHCR continue to update while
# migrated applications are resolved against Forgejo.
cat > /tmp/image-updater-values.yaml << 'EOF'
config:
  registries:
    - name: ghcr
      api_url: https://ghcr.io
      prefix: ghcr.io
      credentials: "secret:argocd/ghcr-image-updater#creds"
    - name: forgejo
      api_url: https://forgejo.internal.prakash.com.br
      prefix: forgejo.internal.prakash.com.br
      credentials: "secret:argocd/forgejo-image-updater#creds"
extraArgs:
  - --interval=30s
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
echo "  1. Create GHCR and Forgejo credentials (via ExternalSecret or manually)"
echo "  2. Apply ImageUpdater CR from gitops/argocd-image-updater/"
