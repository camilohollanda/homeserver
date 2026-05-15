#!/usr/bin/env bash
# Runs on the k3s VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.11 ./argocd-install.sh
if [[ -n "${REMOTE_HOST:-}" ]]; then
  cat "$0" | ssh "$REMOTE_HOST" "sudo bash -s"; exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

echo "Installing Argo CD..."

# Set up kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.12/manifests/install.yaml

echo "Waiting for Argo CD to be ready..."
kubectl wait --namespace argocd \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=600s

# Patch service to NodePort with fixed ports
echo "Patching ArgoCD server service to NodePort with fixed ports..."
kubectl patch svc argocd-server -n argocd --type='json' -p='[
  {"op": "replace", "path": "/spec/type", "value": "NodePort"},
  {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 30080},
  {"op": "replace", "path": "/spec/ports/1/nodePort", "value": 30443}
]'

echo ""
echo "Argo CD installed successfully!"
echo ""
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
echo ""
echo "Access ArgoCD at: https://192.168.20.11:30443"
