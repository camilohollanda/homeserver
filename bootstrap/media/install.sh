#!/usr/bin/env bash
# Runs on the media VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.40 ./install.sh
#
# Required env vars:
#   MEDIA_TIMEZONE         - e.g. America/Sao_Paulo
#   MEDIA_UID              - UID for media processes (e.g. 1000)
#   MEDIA_GID              - GID for media processes (e.g. 1000)
#   MEDIA_LIBRARY_PATH     - Path to media library (e.g. /srv/media)
#   MEDIA_DOWNLOAD_PATH    - Path for downloads (e.g. /srv/downloads)
#   CF_API_TOKEN           - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL      - Email for Let's Encrypt notifications
#   DOMAIN_JELLYFIN        - e.g. jellyfin.internal.prakash.com.br
#   DOMAIN_QBITTORRENT     - e.g. torrent.internal.prakash.com.br
#   DOMAIN_RADARR          - e.g. radarr.internal.prakash.com.br
#   DOMAIN_SONARR          - e.g. sonarr.internal.prakash.com.br
#   DOMAIN_PROWLARR        - e.g. prowlarr.internal.prakash.com.br
#   DOMAIN_BAZARR          - e.g. bazarr.internal.prakash.com.br
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      MEDIA_TIMEZONE      "${MEDIA_TIMEZONE:-America/Sao_Paulo}" \
      MEDIA_UID           "${MEDIA_UID:-1000}" \
      MEDIA_GID           "${MEDIA_GID:-1000}" \
      MEDIA_LIBRARY_PATH  "${MEDIA_LIBRARY_PATH:-/srv/media}" \
      MEDIA_DOWNLOAD_PATH "${MEDIA_DOWNLOAD_PATH:-/srv/downloads}" \
      CF_API_TOKEN        "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL   "${LETSENCRYPT_EMAIL:-}" \
      CERTBOT_DNS_WAIT    "${CERTBOT_DNS_WAIT:-}" \
      DOMAIN_JELLYFIN     "${DOMAIN_JELLYFIN:-}" \
      DOMAIN_QBITTORRENT  "${DOMAIN_QBITTORRENT:-}" \
      DOMAIN_RADARR       "${DOMAIN_RADARR:-}" \
      DOMAIN_SONARR       "${DOMAIN_SONARR:-}" \
      DOMAIN_PROWLARR     "${DOMAIN_PROWLARR:-}" \
      DOMAIN_BAZARR       "${DOMAIN_BAZARR:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

MEDIA_TIMEZONE="${MEDIA_TIMEZONE:-UTC}"
MEDIA_UID="${MEDIA_UID:-1000}"
MEDIA_GID="${MEDIA_GID:-1000}"
MEDIA_LIBRARY_PATH="${MEDIA_LIBRARY_PATH:-/srv/media}"
MEDIA_DOWNLOAD_PATH="${MEDIA_DOWNLOAD_PATH:-/srv/downloads}"

# TLS is mandatory: certs are issued via Let's Encrypt DNS-01 (Cloudflare) and
# every vhost is served over HTTPS, so all domains + CF creds must be present.
: "${CF_API_TOKEN:?must be set}"
: "${LETSENCRYPT_EMAIL:?must be set}"
: "${DOMAIN_JELLYFIN:?must be set}"
: "${DOMAIN_QBITTORRENT:?must be set}"
: "${DOMAIN_RADARR:?must be set}"
: "${DOMAIN_SONARR:?must be set}"
: "${DOMAIN_PROWLARR:?must be set}"
: "${DOMAIN_BAZARR:?must be set}"

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
# Storage directories
# ---------------------------------------------------------------------------
echo ""
echo "==> Creating storage directories..."
mkdir -p "${MEDIA_LIBRARY_PATH}/movies" "${MEDIA_LIBRARY_PATH}/tv"
mkdir -p "${MEDIA_DOWNLOAD_PATH}/incomplete" "${MEDIA_DOWNLOAD_PATH}/complete"
chown -R "${MEDIA_UID}:${MEDIA_GID}" "${MEDIA_LIBRARY_PATH}" "${MEDIA_DOWNLOAD_PATH}"
chmod -R 775 "${MEDIA_LIBRARY_PATH}" "${MEDIA_DOWNLOAD_PATH}"

# ---------------------------------------------------------------------------
# TLS: one Let's Encrypt SAN cert for every media domain (DNS-01 via Cloudflare)
# ---------------------------------------------------------------------------
# These domains resolve to this VM (terraform/cloudflare-dns.tf), but DNS-01
# only needs the CF token to write the _acme-challenge TXT records, so no
# public HTTP exposure is required. A single cert (lineage "media-stack")
# covers all vhosts; nginx mounts /etc/letsencrypt read-only.
echo ""
echo "==> Obtaining Let's Encrypt certificate for media domains..."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/cloudflare.ini <<INI
dns_cloudflare_api_token = ${CF_API_TOKEN}
INI
chmod 600 /etc/letsencrypt/cloudflare.ini

# --keep-until-expiring is a no-op when the cert is still valid; --expand picks
# up any domain added to the list on a later run, so this stays idempotent.
# Cloudflare can take longer than the plugin's 10s default to publish the TXT
# records across its authoritative servers; with several SAN names created at
# once the slower ones return NXDOMAIN to Let's Encrypt and validation fails.
# Wait long enough for all of them to propagate (override with CERTBOT_DNS_WAIT).
CERTBOT_DNS_WAIT="${CERTBOT_DNS_WAIT:-60}"
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --dns-cloudflare-propagation-seconds "${CERTBOT_DNS_WAIT}" \
  --cert-name media-stack \
  -d "${DOMAIN_JELLYFIN}" \
  -d "${DOMAIN_QBITTORRENT}" \
  -d "${DOMAIN_RADARR}" \
  -d "${DOMAIN_SONARR}" \
  -d "${DOMAIN_PROWLARR}" \
  -d "${DOMAIN_BAZARR}" \
  --keep-until-expiring --expand \
  --non-interactive --agree-tos \
  -m "${LETSENCRYPT_EMAIL}"

# Reload the media nginx whenever the cert renews (certbot.timer runs renew).
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-media-nginx.sh <<'HOOK'
#!/bin/bash
docker exec media-nginx nginx -s reload 2>/dev/null || true
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-media-nginx.sh

systemctl enable --now certbot.timer 2>/dev/null || true

# ---------------------------------------------------------------------------
# Stack configuration
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing media stack configuration..."
mkdir -p /opt/media-stack

cat > /opt/media-stack/.env <<ENV
TIMEZONE=${MEDIA_TIMEZONE}
PUID=${MEDIA_UID}
PGID=${MEDIA_GID}
ENV

cat > /opt/media-stack/docker-compose.yml <<COMPOSE
services:
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
    volumes:
      - prowlarr-config:/config
    expose:
      - "9696"

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
    volumes:
      - bazarr-config:/config
      - ${MEDIA_LIBRARY_PATH}:/media
    expose:
      - "6767"

  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
      - WEBUI_PORT=8080
    volumes:
      - qbittorrent-config:/config
      - ${MEDIA_DOWNLOAD_PATH}:/downloads
      - ${MEDIA_LIBRARY_PATH}:/media
    expose:
      - "8080"

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
    volumes:
      - radarr-config:/config
      - ${MEDIA_LIBRARY_PATH}:/media
      - ${MEDIA_DOWNLOAD_PATH}:/downloads
    expose:
      - "7878"

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
    volumes:
      - sonarr-config:/config
      - ${MEDIA_LIBRARY_PATH}:/media
      - ${MEDIA_DOWNLOAD_PATH}:/downloads
    expose:
      - "8989"

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
    volumes:
      - jellyfin-config:/config
      - ${MEDIA_LIBRARY_PATH}/movies:/media/movies
      - ${MEDIA_LIBRARY_PATH}/tv:/media/tv
    expose:
      - "8096"

  nginx:
    image: nginx:alpine
    container_name: media-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/media-stack/nginx.conf:/etc/nginx/nginx.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - jellyfin
      - qbittorrent
      - radarr
      - sonarr
      - prowlarr
      - bazarr

volumes:
  prowlarr-config:
  bazarr-config:
  qbittorrent-config:
  radarr-config:
  sonarr-config:
  jellyfin-config:
COMPOSE

cat > /opt/media-stack/nginx.conf <<NGINX
events { worker_connections 1024; }

http {
  server_tokens off;
  client_max_body_size 0;

  # Jellyfin (and the *arr apps) stream over WebSockets; map the Connection
  # header so upgrades pass through the proxy.
  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }

  # Every media domain shares one Let's Encrypt SAN cert (lineage media-stack).
  ssl_certificate     /etc/letsencrypt/live/media-stack/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/media-stack/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers   HIGH:!aNULL:!MD5;

$(for svc_domain_port in \
    "${DOMAIN_JELLYFIN}:jellyfin:8096" \
    "${DOMAIN_QBITTORRENT}:qbittorrent:8080" \
    "${DOMAIN_RADARR}:radarr:7878" \
    "${DOMAIN_SONARR}:sonarr:8989" \
    "${DOMAIN_PROWLARR}:prowlarr:9696" \
    "${DOMAIN_BAZARR}:bazarr:6767"; do
    IFS=: read -r dom svc port <<< "$svc_domain_port"
    cat <<SRV
  server {
    listen 80;
    server_name ${dom};
    location / { return 301 https://\$host\$request_uri; }
  }

  server {
    listen 443 ssl;
    server_name ${dom};
    location / {
      proxy_pass http://${svc}:${port};
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_http_version 1.1;
      proxy_set_header Upgrade    \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
    }
  }
SRV
done)
}
NGINX

cat > /opt/media-stack/restart-stack.sh <<'RESTART'
#!/usr/bin/env bash
set -euo pipefail
cd /opt/media-stack
/usr/bin/docker compose pull
/usr/bin/docker compose up -d
RESTART
chmod 755 /opt/media-stack/restart-stack.sh

cat > /etc/systemd/system/media-stack.service <<'SVC'
[Unit]
Description=Media stack (Jellyfin + qBittorrent + Radarr + Sonarr)
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=/opt/media-stack
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start media stack
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting media stack..."
systemctl daemon-reload
systemctl enable media-stack

/opt/media-stack/restart-stack.sh

systemctl start media-stack 2>/dev/null || true

echo ""
echo "✓ Media stack running (HTTPS via Let's Encrypt, HTTP redirects to HTTPS)."
echo "  Jellyfin    : https://${DOMAIN_JELLYFIN}"
echo "  qBittorrent : https://${DOMAIN_QBITTORRENT}"
echo "  Radarr      : https://${DOMAIN_RADARR}"
echo "  Sonarr      : https://${DOMAIN_SONARR}"
echo "  Prowlarr    : https://${DOMAIN_PROWLARR}"
echo "  Bazarr      : https://${DOMAIN_BAZARR}"
