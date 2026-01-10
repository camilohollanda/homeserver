#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

INGRESS_NGINX_IP="127.0.0.1"
INGRESS_NGINX_PORT="80"
TUNNEL_NAME="${TUNNEL_NAME:-homeserver}"

echo "Configuring cloudflared tunnel with local configuration files..."

# Check if cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
  echo "Error: cloudflared is not installed. Please run cloudflared-install.sh first."
  exit 1
fi

# Create config directory
mkdir -p /etc/cloudflared

echo ""
echo "Step 1: Login to Cloudflare (this will open a browser)"
echo "Executing: cloudflared tunnel login"
cloudflared tunnel login

# Check if login was successful
if [ ! -f /root/.cloudflared/cert.pem ]; then
  echo "Error: Login failed. Please check the browser authentication."
  exit 1
fi

echo "Login successful!"

echo ""
echo "Step 2: Creating tunnel '${TUNNEL_NAME}'..."
cloudflared tunnel create "${TUNNEL_NAME}" || {
  echo "Note: Tunnel might already exist. Continuing..."
}

# Get tunnel ID from text output
# Format: ID                                   NAME       CREATED              CONNECTIONS
TUNNEL_ID=$(cloudflared tunnel list | grep -E "^\S+\s+${TUNNEL_NAME}\s+" | awk '{print $1}' || echo "")

if [ -z "$TUNNEL_ID" ]; then
  echo "Error: Could not find tunnel ID. Please check tunnel name or create it manually."
  echo "Run: cloudflared tunnel list"
  exit 1
fi

echo "Tunnel ID: ${TUNNEL_ID}"

# Create config.yml with ingress rules
echo ""
echo "Step 3: Creating configuration file..."
cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: "*.werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "*.prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - service: http_status:404
EOF

echo "Configuration file created at /etc/cloudflared/config.yml"

# Configure DNS routes
# Note: The config.yml defines ingress rules, but DNS records need to be created separately
# These commands create CNAME records pointing domains to the tunnel
echo ""
echo "Step 4: Configuring DNS routes..."
cloudflared tunnel route dns "${TUNNEL_NAME}" "*.werify.app" || echo "Note: DNS route might already exist"
cloudflared tunnel route dns "${TUNNEL_NAME}" "werify.app" || echo "Note: DNS route might already exist"
cloudflared tunnel route dns "${TUNNEL_NAME}" "*.prakash.com.br" || echo "Note: DNS route might already exist"
cloudflared tunnel route dns "${TUNNEL_NAME}" "prakash.com.br" || echo "Note: DNS route might already exist"
echo "DNS routes configured."

# Install as systemd service
echo ""
echo "Step 5: Installing cloudflared as systemd service..."
cloudflared service install

# Enable and start service
echo ""
echo "Step 6: Starting cloudflared service..."
systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

echo ""
echo "✓ Cloudflared tunnel configured and started!"
echo ""
echo "Configuration files:"
echo "  - /etc/cloudflared/config.yml (tunnel configuration)"
echo "  - /root/.cloudflared/${TUNNEL_ID}.json (tunnel credentials)"
echo "  - /root/.cloudflared/cert.pem (Cloudflare account certificate)"
echo ""
echo "Service status:"
systemctl status cloudflared --no-pager -l | head -10 || true
