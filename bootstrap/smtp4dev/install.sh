#!/usr/bin/env bash
# Runs on the services VM (vmid 114) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN          - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL     - Email for Let's Encrypt
#   SMTP4DEV_DOMAIN       - FQDN for the web UI (e.g. smtp4dev.internal.prakash.com.br)
#   SMTP4DEV_BASIC_USER   - Username for web UI basic auth
#   SMTP4DEV_BASIC_PASS   - Password for web UI basic auth
#
# Optional env vars:
#   SMTP4DEV_VERSION      - image tag (default: 3.6.1)
#   SMTP4DEV_SMTP_PORT    - SMTP listener port on the VM (default: 2525)
#   SMTP4DEV_HTTP_PORT    - Web UI port bound on 127.0.0.1 (default: 5080)
#   SMTP4DEV_KEEP_MSGS    - Rolling message retention (default: 500)
#   SMTP4DEV_KEEP_SESSIONS- Rolling session retention (default: 500)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN          "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL     "${LETSENCRYPT_EMAIL:-}" \
      SMTP4DEV_DOMAIN       "${SMTP4DEV_DOMAIN:-}" \
      SMTP4DEV_BASIC_USER   "${SMTP4DEV_BASIC_USER:-}" \
      SMTP4DEV_BASIC_PASS   "${SMTP4DEV_BASIC_PASS:-}" \
      SMTP4DEV_VERSION      "${SMTP4DEV_VERSION:-}" \
      SMTP4DEV_SMTP_PORT    "${SMTP4DEV_SMTP_PORT:-}" \
      SMTP4DEV_HTTP_PORT    "${SMTP4DEV_HTTP_PORT:-}" \
      SMTP4DEV_KEEP_MSGS    "${SMTP4DEV_KEEP_MSGS:-}" \
      SMTP4DEV_KEEP_SESSIONS "${SMTP4DEV_KEEP_SESSIONS:-}"
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
: "${SMTP4DEV_DOMAIN:?must be set}"
: "${SMTP4DEV_BASIC_USER:?must be set}"
: "${SMTP4DEV_BASIC_PASS:?must be set}"

SMTP4DEV_VERSION="${SMTP4DEV_VERSION:-3.6.1}"
SMTP4DEV_SMTP_PORT="${SMTP4DEV_SMTP_PORT:-2525}"
SMTP4DEV_HTTP_PORT="${SMTP4DEV_HTTP_PORT:-5080}"
SMTP4DEV_KEEP_MSGS="${SMTP4DEV_KEEP_MSGS:-500}"
SMTP4DEV_KEEP_SESSIONS="${SMTP4DEV_KEEP_SESSIONS:-500}"

# ---------------------------------------------------------------------------
# Prereqs: shared services proxy must already exist
# ---------------------------------------------------------------------------
if [[ ! -f /opt/services/docker-compose.yml ]]; then
  echo "Error: shared services proxy not installed. Run bootstrap/services/install.sh first." >&2
  exit 1
fi
if ! command -v docker &>/dev/null; then
  echo "Error: docker missing. Run bootstrap/services/install.sh first." >&2
  exit 1
fi
if ! command -v certbot &>/dev/null; then
  echo "Error: certbot missing. Run bootstrap/services/install.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Let's Encrypt certificate for the web UI domain (DNS-01)
# ---------------------------------------------------------------------------
echo ""
echo "==> Obtaining Let's Encrypt certificate for ${SMTP4DEV_DOMAIN}..."

if [ ! -d "/etc/letsencrypt/live/${SMTP4DEV_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${SMTP4DEV_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# smtp4dev stack files
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing smtp4dev configuration..."
mkdir -p /opt/smtp4dev/data

cat > /opt/smtp4dev/.env <<ENV
SMTP4DEV_VERSION=${SMTP4DEV_VERSION}
SMTP4DEV_SMTP_PORT=${SMTP4DEV_SMTP_PORT}
SMTP4DEV_HTTP_PORT=${SMTP4DEV_HTTP_PORT}
SMTP4DEV_BASIC_USER=${SMTP4DEV_BASIC_USER}
SMTP4DEV_BASIC_PASS=${SMTP4DEV_BASIC_PASS}
SMTP4DEV_KEEP_MSGS=${SMTP4DEV_KEEP_MSGS}
SMTP4DEV_KEEP_SESSIONS=${SMTP4DEV_KEEP_SESSIONS}
SMTP4DEV_DOMAIN=${SMTP4DEV_DOMAIN}
ENV
chmod 600 /opt/smtp4dev/.env

# smtp4dev binds:
#   - SMTP submission on 0.0.0.0:${SMTP4DEV_SMTP_PORT} (reachable from k3s + other VMs)
#   - Web UI on 127.0.0.1:${SMTP4DEV_HTTP_PORT} (fronted by shared nginx + TLS)
cat > /opt/smtp4dev/docker-compose.yml <<'COMPOSE'
services:
  smtp4dev:
    image: rnwood/smtp4dev:${SMTP4DEV_VERSION}
    container_name: smtp4dev
    restart: unless-stopped
    ports:
      - "0.0.0.0:${SMTP4DEV_SMTP_PORT}:25"
      - "0.0.0.0:587:25"
      - "127.0.0.1:${SMTP4DEV_HTTP_PORT}:80"
    environment:
      ServerOptions__HostName: ${SMTP4DEV_DOMAIN}
      ServerOptions__Urls: http://*:80
      ServerOptions__WebAuthenticationRequired: "true"
      ServerOptions__Users__0__Username: ${SMTP4DEV_BASIC_USER}
      ServerOptions__Users__0__Password: ${SMTP4DEV_BASIC_PASS}
      ServerOptions__NumberOfMessagesToKeep: ${SMTP4DEV_KEEP_MSGS}
      ServerOptions__NumberOfSessionsToKeep: ${SMTP4DEV_KEEP_SESSIONS}
      ServerOptions__Database: /smtp4dev/database.db
    volumes:
      - /opt/smtp4dev/data:/smtp4dev
COMPOSE

# vhost served by the shared services proxy (/opt/services)
cat > /opt/services/conf.d/smtp4dev.conf <<NGINX
upstream smtp4dev_upstream { server 127.0.0.1:${SMTP4DEV_HTTP_PORT}; }

server {
  listen 80;
  server_name ${SMTP4DEV_DOMAIN};
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${SMTP4DEV_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${SMTP4DEV_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${SMTP4DEV_DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers   HIGH:!aNULL:!MD5;

  # smtp4dev streams messages over SignalR (WebSocket)
  location / {
    proxy_pass http://smtp4dev_upstream;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
  }
}
NGINX

cat > /etc/systemd/system/smtp4dev.service <<'SVC'
[Unit]
Description=smtp4dev — fake SMTP + web UI for development email capture
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/smtp4dev
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start smtp4dev
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting smtp4dev..."
systemctl daemon-reload
systemctl enable smtp4dev

if systemctl is-active --quiet smtp4dev; then
  systemctl restart smtp4dev
else
  systemctl start smtp4dev
fi

# Wait for the web UI to respond locally
echo -n "  Waiting for web UI"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${SMTP4DEV_HTTP_PORT}/" || true)"
  if [[ "$code" =~ ^(200|401|302)$ ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

# Reload the shared services proxy so the new vhost takes effect
docker exec services nginx -s reload 2>/dev/null || systemctl restart services

echo ""
echo "✓ smtp4dev is running."
echo "  Web UI:        https://${SMTP4DEV_DOMAIN}  (user: ${SMTP4DEV_BASIC_USER})"
echo "  SMTP listener: 192.168.20.22:${SMTP4DEV_SMTP_PORT} and 192.168.20.22:587"
echo "                 (no auth, no TLS — dev only)"
