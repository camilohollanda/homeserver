#!/usr/bin/env bash
# Runs on the Infisical VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN          - Cloudflare API token (Zone.DNS Edit)
#   INFISICAL_DOMAIN      - FQDN for Infisical (e.g. infisical.internal.prakash.com.br)
#   LETSENCRYPT_EMAIL     - Email for Let's Encrypt
#   INFISICAL_ENCRYPTION_KEY
#   INFISICAL_AUTH_SECRET
#   INFISICAL_DB_URI      - Full postgres connection URI for Infisical
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN             "${CF_API_TOKEN:-}" \
      INFISICAL_DOMAIN         "${INFISICAL_DOMAIN:-}" \
      LETSENCRYPT_EMAIL        "${LETSENCRYPT_EMAIL:-}" \
      INFISICAL_ENCRYPTION_KEY "${INFISICAL_ENCRYPTION_KEY:-}" \
      INFISICAL_AUTH_SECRET    "${INFISICAL_AUTH_SECRET:-}" \
      INFISICAL_DB_URI         "${INFISICAL_DB_URI:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

echo "==> Installing base dependencies..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg certbot python3-certbot-dns-cloudflare

# ---------------------------------------------------------------------------
# Docker CE
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing Docker CE..."

if ! command -v docker &>/dev/null; then
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
else
  echo "  Docker already installed — skipping."
fi

# ---------------------------------------------------------------------------
# Let's Encrypt certificate
# ---------------------------------------------------------------------------
echo ""
echo "==> Obtaining Let's Encrypt certificate for ${INFISICAL_DOMAIN}..."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/cloudflare.ini <<INI
dns_cloudflare_api_token = ${CF_API_TOKEN}
INI
chmod 600 /etc/letsencrypt/cloudflare.ini

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
docker exec infisical-nginx nginx -s reload
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if [ ! -d "/etc/letsencrypt/live/${INFISICAL_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${INFISICAL_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# Infisical stack files
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing Infisical configuration..."
mkdir -p /opt/infisical

cat > /opt/infisical/.env <<ENV
NODE_ENV=production
ENCRYPTION_KEY=${INFISICAL_ENCRYPTION_KEY}
AUTH_SECRET=${INFISICAL_AUTH_SECRET}
DB_CONNECTION_URI=${INFISICAL_DB_URI}
REDIS_URL=redis://redis:6379
SITE_URL=https://${INFISICAL_DOMAIN}
TELEMETRY_ENABLED=false
ENV
chmod 600 /opt/infisical/.env

cat > /opt/infisical/docker-compose.yml <<'COMPOSE'
version: "3.9"

services:
  redis:
    image: redis:7-alpine
    container_name: infisical-redis
    restart: unless-stopped
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  infisical:
    image: infisical/infisical:latest
    container_name: infisical
    restart: unless-stopped
    ports:
      - "8080:8080"
    env_file:
      - .env
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/status"]
      interval: 30s
      timeout: 10s
      retries: 5

  nginx:
    image: nginx:alpine
    container_name: infisical-nginx
    restart: unless-stopped
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - infisical

volumes:
  redis_data:

networks:
  default:
    name: infisical-network
COMPOSE

# nginx.conf references the domain — substitute it
cat > /opt/infisical/nginx.conf <<NGINX
events { worker_connections 1024; }

http {
  upstream infisical { server infisical:8080; }

  server {
    listen 80;
    server_name ${INFISICAL_DOMAIN};
    location / { return 301 https://\$host\$request_uri; }
  }

  server {
    listen 443 ssl;
    server_name ${INFISICAL_DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${INFISICAL_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${INFISICAL_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers   HIGH:!aNULL:!MD5;

    location / {
      proxy_pass http://infisical;
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_http_version 1.1;
      proxy_set_header Upgrade    \$http_upgrade;
      proxy_set_header Connection "upgrade";
    }
  }
}
NGINX

cat > /etc/systemd/system/infisical.service <<'SVC'
[Unit]
Description=Infisical Secret Management
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/infisical
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start Infisical
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Infisical..."
systemctl daemon-reload
systemctl enable infisical

if systemctl is-active --quiet infisical; then
  systemctl restart infisical
else
  systemctl start infisical
fi

echo ""
echo "✓ Infisical is running at https://${INFISICAL_DOMAIN}"
