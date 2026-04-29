#!/usr/bin/env bash
# Runs on the media VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.40 ./install.sh
#
# Required env vars:
#   MEDIA_TIMEZONE         - e.g. America/Sao_Paulo
#   MEDIA_UID              - UID for media processes (e.g. 1000)
#   MEDIA_GID              - GID for media processes (e.g. 1000)
#   MEDIA_LIBRARY_PATH     - Path to media library (e.g. /mnt/media)
#   MEDIA_DOWNLOAD_PATH    - Path for downloads (e.g. /mnt/downloads)
#   DOMAIN_JELLYFIN        - e.g. jellyfin.internal.prakash.com.br
#   DOMAIN_QBITTORRENT     - e.g. qbittorrent.internal.prakash.com.br
#   DOMAIN_RADARR          - e.g. radarr.internal.prakash.com.br
#   DOMAIN_SONARR          - e.g. sonarr.internal.prakash.com.br
#   DOMAIN_PROWLARR        - e.g. prowlarr.internal.prakash.com.br
#   DOMAIN_BAZARR          - e.g. bazarr.internal.prakash.com.br
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      MEDIA_TIMEZONE      "${MEDIA_TIMEZONE:-America/Sao_Paulo}" \
      MEDIA_UID           "${MEDIA_UID:-1000}" \
      MEDIA_GID           "${MEDIA_GID:-1000}" \
      MEDIA_LIBRARY_PATH  "${MEDIA_LIBRARY_PATH:-/mnt/media}" \
      MEDIA_DOWNLOAD_PATH "${MEDIA_DOWNLOAD_PATH:-/mnt/downloads}" \
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
MEDIA_LIBRARY_PATH="${MEDIA_LIBRARY_PATH:-/mnt/media}"
MEDIA_DOWNLOAD_PATH="${MEDIA_DOWNLOAD_PATH:-/mnt/downloads}"

echo "==> Installing base dependencies..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

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
    volumes:
      - /opt/media-stack/nginx.conf:/etc/nginx/nginx.conf:ro
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
    location / {
      proxy_pass http://${svc}:${port};
      proxy_set_header Host              \$host;
      proxy_set_header X-Real-IP         \$remote_addr;
      proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
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
echo "✓ Media stack running."
echo "  Jellyfin    : http://$(hostname -I | awk '{print $1}'):8096"
echo "  qBittorrent : http://$(hostname -I | awk '{print $1}'):8080"
echo "  Radarr      : http://$(hostname -I | awk '{print $1}'):7878"
echo "  Sonarr      : http://$(hostname -I | awk '{print $1}'):8989"
