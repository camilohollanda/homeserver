#!/usr/bin/env bash
#
# Install External Secrets Operator for Kubernetes
# This enables syncing secrets from Infisical to K8s
#
# NOTE: This is infrastructure-level installation done once during bootstrap.
# The operator is installed via Helm, but app-level configs (ClusterSecretStore,
# ExternalSecrets) are managed in gitops/external-secrets/
#
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

echo "==> Installing External Secrets Operator..."

# Set up kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Install Helm if not available
if ! command -v helm &> /dev/null; then
  echo "==> Helm not found, installing..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Add Helm repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install ESO
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait

echo "==> External Secrets Operator installed!"
echo ""
echo "Next steps:"
echo "  1. Create secrets for Infisical authentication:"
echo "     kubectl create secret generic infisical-credentials \\"
echo "       --namespace external-secrets \\"
echo "       --from-literal=clientId=\"\$INFISICAL_CLIENT_ID\" \\"
echo "       --from-literal=clientSecret=\"\$INFISICAL_CLIENT_SECRET\""
echo ""
echo "  2. Apply ClusterSecretStore (via ArgoCD or manually):"
echo "     kubectl apply -f gitops/external-secrets/werify-cluster-secret-store.yaml"
