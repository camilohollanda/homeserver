#!/bin/bash
set -euo pipefail

INGRESS_NGINX_IP="127.0.0.1"
INGRESS_NGINX_PORT="80"

echo "Configuring cloudflared systemd service..."

mkdir -p /etc/cloudflared

cat > /etc/cloudflared/config.yml <<EOF
tunnel: \${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials.json

ingress:
  - hostname: "werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "*.prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - service: http_status:404
EOF

cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=cloudflared
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "NOTE: You need to:"
echo "1. Create a Cloudflare Tunnel and get the tunnel ID"
echo "2. Place credentials.json at /etc/cloudflared/credentials.json"
echo "3. Update TUNNEL_ID in /etc/cloudflared/config.yml"
echo "4. Run: systemctl daemon-reload && systemctl enable --now cloudflared"
