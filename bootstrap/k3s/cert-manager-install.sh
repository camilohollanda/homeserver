#!/bin/bash
set -euo pipefail

# cert-manager installation script for k3s
# Uses Cloudflare DNS-01 challenge for Let's Encrypt certificates
# This enables valid TLS for internal services without exposing them to the internet

echo "Installing cert-manager..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
  echo "Error: kubectl is not installed or not in PATH"
  exit 1
fi

# Check if helm is available
if ! command -v helm &> /dev/null; then
  echo "Error: helm is not installed. Installing..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Add jetstack helm repo
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update

# Install cert-manager with CRDs
echo "Installing cert-manager via Helm..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait

echo ""
echo "✓ cert-manager installed successfully!"
echo ""
echo "Next steps:"
echo "1. Create a Cloudflare API token with Zone:DNS:Edit permissions"
echo "2. Store the token in Infisical (or create a k8s secret manually)"
echo "3. Push the gitops changes to create the ClusterIssuer and Certificate"
echo ""
echo "The gitops configuration will automatically create:"
echo "  - ClusterIssuer for Let's Encrypt (DNS-01 via Cloudflare)"
echo "  - Wildcard certificate for *.internal.prakash.com.br"
echo ""
