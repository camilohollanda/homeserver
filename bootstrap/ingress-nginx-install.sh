#!/bin/bash
set -euo pipefail

echo "Installing ingress-nginx..."

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/cloud/deploy.yaml

echo "Waiting for ingress-nginx to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s

echo "ingress-nginx installed successfully"
