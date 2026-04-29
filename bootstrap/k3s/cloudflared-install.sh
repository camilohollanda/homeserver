#!/usr/bin/env bash
# Runs on the k3s VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.11 ./cloudflared-install.sh
if [[ -n "${REMOTE_HOST:-}" ]]; then
  cat "$0" | ssh "$REMOTE_HOST" "sudo bash -s"; exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

echo "Installing cloudflared from official Cloudflare repository..."

# Add Cloudflare GPG key
echo "Adding Cloudflare GPG key..."
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

# Add Cloudflare repository (using "any" for Debian-based distributions)
echo "Adding Cloudflare repository..."
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

# Update package list and install cloudflared
echo "Updating package list..."
apt-get update

echo "Installing cloudflared..."
apt-get install -y cloudflared

echo "cloudflared installed successfully"
echo "Version:"
cloudflared --version
