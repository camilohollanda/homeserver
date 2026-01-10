#!/bin/bash
set -euo pipefail

echo "Installing K3s with Traefik disabled..."

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

echo "Waiting for K3s to be ready..."
until kubectl get nodes &>/dev/null; do
  sleep 2
done

echo "K3s installed successfully"
