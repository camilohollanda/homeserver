#!/usr/bin/env bash
# Runs on the services VM (currently vmid 114) as root.
# Sets up the shared nginx reverse proxy + Let's Encrypt cert tooling
# that other apps on this VM (Infisical, Garage, ...) plug their vhosts into.
#
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN       - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL  - Email for Let's Encrypt notifications
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN      "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL "${LETSENCRYPT_EMAIL:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

: "${CF_API_TOKEN:?must be set}"
: "${LETSENCRYPT_EMAIL:?must be set}"

# ---------------------------------------------------------------------------
# System packages: certbot + Cloudflare DNS plugin
# ---------------------------------------------------------------------------
echo "==> Installing certbot + Cloudflare DNS plugin..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl certbot python3-certbot-dns-cloudflare

# ---------------------------------------------------------------------------
# Docker (should already be present from Infisical install; guard anyway)
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker CE..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  usermod -aG docker deployer
  systemctl enable docker
  systemctl start docker
fi

# ---------------------------------------------------------------------------
# Cloudflare credentials for certbot DNS-01
# ---------------------------------------------------------------------------
echo "==> Writing Cloudflare credentials for DNS-01..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/cloudflare.ini <<INI
dns_cloudflare_api_token = ${CF_API_TOKEN}
INI
chmod 600 /etc/letsencrypt/cloudflare.ini

# Renewal hook: reload the shared proxy nginx whenever any cert renews
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh <<'HOOK'
#!/bin/bash
docker exec services nginx -s reload 2>/dev/null || true
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-services.sh

# Remove the legacy Infisical-only renewal hook if it's still around
rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ---------------------------------------------------------------------------
# Shared services stack (the reverse proxy)
# ---------------------------------------------------------------------------
echo "==> Writing shared services configuration..."
mkdir -p /opt/services/conf.d

cat > /opt/services/nginx.conf <<'NGINX'
events { worker_connections 1024; }

http {
  # Sensible defaults for proxied apps
  sendfile on;
  tcp_nopush on;
  types_hash_max_size 2048;
  server_tokens off;
  client_max_body_size 0;

  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  # Per-app vhosts live here
  include /etc/nginx/conf.d/*.conf;
}
NGINX

cat > /opt/services/docker-compose.yml <<'COMPOSE'
services:
  services:
    image: nginx:alpine
    container_name: services
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/services/nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/services/conf.d:/etc/nginx/conf.d:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
COMPOSE

cat > /etc/systemd/system/services.service <<'SVC'
[Unit]
Description=Shared nginx reverse proxy for services VM
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/services
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# If the legacy Infisical nginx is still bound to 80/443, stop it first
# (the Infisical install.sh refactor removes it permanently)
# ---------------------------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -q '^infisical-nginx$'; then
  echo "==> Stopping legacy infisical-nginx container (replaced by shared services)..."
  docker stop infisical-nginx >/dev/null
  docker rm infisical-nginx >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Start shared services proxy
# ---------------------------------------------------------------------------
echo "==> Starting shared services proxy..."
systemctl daemon-reload
systemctl enable services

if systemctl is-active --quiet services; then
  systemctl restart services
else
  systemctl start services
fi

echo ""
echo "✓ Shared services proxy is running on host ports 80 / 443."
echo "  Vhosts directory: /opt/services/conf.d/"
echo "  Reload after editing:  docker exec services nginx -s reload"
