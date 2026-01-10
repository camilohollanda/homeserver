#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
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
