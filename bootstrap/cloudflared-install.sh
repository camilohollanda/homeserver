#!/bin/bash
set -euo pipefail

CLOUDFLARED_VERSION="2024.12.0"
ARCH="amd64"

echo "Installing cloudflared..."

wget -q "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}.deb" -O /tmp/cloudflared.deb
dpkg -i /tmp/cloudflared.deb || apt-get install -f -y
rm /tmp/cloudflared.deb

echo "cloudflared installed successfully"
