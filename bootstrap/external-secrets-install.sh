#!/usr/bin/env bash
#
# Install External Secrets Operator for Kubernetes
# This enables syncing secrets from Infisical to K8s
#
set -euo pipefail

echo "==> Installing External Secrets Operator..."

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
echo "  1. Create secrets for Infisical authentication"
echo "  2. Create a ClusterSecretStore pointing to Infisical"
echo "  3. Create ExternalSecret resources for your apps"
