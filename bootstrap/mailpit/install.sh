#!/usr/bin/env bash
# Runs on the services VM (vmid 114) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt
#   MAILPIT_DOMAIN       - FQDN for the web UI (e.g. mailpit.internal.prakash.com.br)
#   MAILPIT_BASIC_USER   - Username for web UI + SMTP basic auth
#   MAILPIT_BASIC_PASS   - Password for web UI + SMTP basic auth
#
# Optional env vars:
#   MAILPIT_VERSION      - image tag (default: v1.20.7)
#   MAILPIT_SMTP_PORT    - SMTP listener port on the VM (default: 2525)
#   MAILPIT_HTTP_PORT    - Web UI port bound on 127.0.0.1 (default: 5080)
#   MAILPIT_KEEP_MSGS    - Rolling message retention (default: 500)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN        "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL   "${LETSENCRYPT_EMAIL:-}" \
      MAILPIT_DOMAIN      "${MAILPIT_DOMAIN:-}" \
      MAILPIT_BASIC_USER  "${MAILPIT_BASIC_USER:-}" \
      MAILPIT_BASIC_PASS  "${MAILPIT_BASIC_PASS:-}" \
      MAILPIT_VERSION     "${MAILPIT_VERSION:-}" \
      MAILPIT_SMTP_PORT   "${MAILPIT_SMTP_PORT:-}" \
      MAILPIT_HTTP_PORT   "${MAILPIT_HTTP_PORT:-}" \
      MAILPIT_KEEP_MSGS   "${MAILPIT_KEEP_MSGS:-}"
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
: "${MAILPIT_DOMAIN:?must be set}"
: "${MAILPIT_BASIC_USER:?must be set}"
: "${MAILPIT_BASIC_PASS:?must be set}"

MAILPIT_VERSION="${MAILPIT_VERSION:-v1.20.7}"
MAILPIT_SMTP_PORT="${MAILPIT_SMTP_PORT:-2525}"
MAILPIT_HTTP_PORT="${MAILPIT_HTTP_PORT:-5080}"
MAILPIT_KEEP_MSGS="${MAILPIT_KEEP_MSGS:-500}"

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
echo "==> Obtaining Let's Encrypt certificate for ${MAILPIT_DOMAIN}..."

if [ ! -d "/etc/letsencrypt/live/${MAILPIT_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${MAILPIT_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# Mailpit stack files
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing Mailpit configuration..."
mkdir -p /opt/mailpit/data /opt/mailpit/certs

# Mailpit wants the cert and key as separate files. Copy them out of the LE
# live dir so the non-root mailpit container can read them.
cat > /usr/local/sbin/mailpit-rebuild-cert <<REBUILD
#!/bin/bash
set -euo pipefail
DOMAIN="${MAILPIT_DOMAIN}"
SRC=/etc/letsencrypt/live/\${DOMAIN}
DST=/opt/mailpit/certs
[[ -f "\${SRC}/fullchain.pem" && -f "\${SRC}/privkey.pem" ]] || { echo "LE cert for \${DOMAIN} not present" >&2; exit 1; }
umask 022
cp "\${SRC}/fullchain.pem" "\${DST}/cert.pem.tmp"
cp "\${SRC}/privkey.pem"   "\${DST}/key.pem.tmp"
mv "\${DST}/cert.pem.tmp" "\${DST}/cert.pem"
mv "\${DST}/key.pem.tmp"  "\${DST}/key.pem"
# Single-tenant dev VM, mailpit container runs non-root and needs to read these.
chmod 644 "\${DST}/cert.pem" "\${DST}/key.pem"
REBUILD
chmod 755 /usr/local/sbin/mailpit-rebuild-cert
/usr/local/sbin/mailpit-rebuild-cert

cat > /opt/mailpit/.env <<ENV
MAILPIT_VERSION=${MAILPIT_VERSION}
MAILPIT_SMTP_PORT=${MAILPIT_SMTP_PORT}
MAILPIT_HTTP_PORT=${MAILPIT_HTTP_PORT}
MAILPIT_BASIC_USER=${MAILPIT_BASIC_USER}
MAILPIT_BASIC_PASS=${MAILPIT_BASIC_PASS}
MAILPIT_KEEP_MSGS=${MAILPIT_KEEP_MSGS}
MAILPIT_DOMAIN=${MAILPIT_DOMAIN}
ENV
chmod 600 /opt/mailpit/.env

# Mailpit binds:
#   - SMTP submission on 0.0.0.0:${MAILPIT_SMTP_PORT} and :587 (reachable from k3s + other VMs)
#   - Web UI on 127.0.0.1:${MAILPIT_HTTP_PORT} (fronted by shared nginx + TLS)
#
# STARTTLS + SMTP AUTH are required. Clients MUST connect using ${MAILPIT_DOMAIN}
# (not the IP) because the Let's Encrypt cert is bound to that name.
cat > /opt/mailpit/docker-compose.yml <<'COMPOSE'
services:
  mailpit:
    image: axllent/mailpit:${MAILPIT_VERSION}
    container_name: mailpit
    restart: unless-stopped
    ports:
      - "0.0.0.0:${MAILPIT_SMTP_PORT}:1025"
      - "0.0.0.0:587:1025"
      - "127.0.0.1:${MAILPIT_HTTP_PORT}:8025"
    environment:
      MP_MAX_MESSAGES: ${MAILPIT_KEEP_MSGS}
      MP_DATABASE: /data/mailpit.db
      MP_UI_AUTH: "${MAILPIT_BASIC_USER}:${MAILPIT_BASIC_PASS}"
      MP_SMTP_AUTH: "${MAILPIT_BASIC_USER}:${MAILPIT_BASIC_PASS}"
      MP_SMTP_TLS_CERT: /certs/cert.pem
      MP_SMTP_TLS_KEY: /certs/key.pem
      MP_SMTP_REQUIRE_STARTTLS: "true"
    volumes:
      - /opt/mailpit/data:/data
      - /opt/mailpit/certs:/certs:ro
COMPOSE

# vhost served by the shared services proxy (/opt/services)
cat > /opt/services/conf.d/mailpit.conf <<NGINX
upstream mailpit_upstream { server 127.0.0.1:${MAILPIT_HTTP_PORT}; }

server {
  listen 80;
  server_name ${MAILPIT_DOMAIN};
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${MAILPIT_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${MAILPIT_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${MAILPIT_DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers   HIGH:!aNULL:!MD5;

  # Mailpit streams new messages over a WebSocket on /api/events
  location / {
    proxy_pass http://mailpit_upstream;
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

# Mailpit loads the TLS cert/key at startup, so on renewal we rebuild the
# copies in /opt/mailpit/certs and restart the container. The shared services
# deploy hook only reloads nginx.
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-mailpit.sh <<HOOK
#!/bin/bash
# Only act when *our* cert renews.
if [[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${MAILPIT_DOMAIN}" ]]; then
  /usr/local/sbin/mailpit-rebuild-cert
  docker restart mailpit >/dev/null 2>&1 || true
fi
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/restart-mailpit.sh

cat > /etc/systemd/system/mailpit.service <<'SVC'
[Unit]
Description=Mailpit — fake SMTP + web UI for development email capture
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/mailpit
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start Mailpit
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Mailpit..."
systemctl daemon-reload
systemctl enable mailpit

if systemctl is-active --quiet mailpit; then
  systemctl restart mailpit
else
  systemctl start mailpit
fi

# Wait for the web UI to respond locally
echo -n "  Waiting for web UI"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MAILPIT_HTTP_PORT}/" || true)"
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
echo "✓ Mailpit is running."
echo "  Web UI:        https://${MAILPIT_DOMAIN}  (user: ${MAILPIT_BASIC_USER})"
echo "  SMTP listener: ${MAILPIT_DOMAIN}:${MAILPIT_SMTP_PORT} and ${MAILPIT_DOMAIN}:587"
echo "                 STARTTLS required, AUTH PLAIN/LOGIN required."
echo "                 Connect by hostname (not IP) so cert verification passes."
echo "                 SMTP user/pass = the web UI user/pass."
