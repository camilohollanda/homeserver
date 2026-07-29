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
#   DOMAIN_HOMEPAGE        - e.g. home.internal.prakash.com.br
#
# Optional env vars (Homepage dashboard widgets):
#   All optional. After the stack is up the installer discovers what it can on
#   its own — it reads the *arr keys out of their config files and asks Jellyfin
#   to mint one — so a normal run needs none of these. Set one to override
#   discovery for that service.
#   RADARR_API_KEY         - auto-read from radarr:/config/config.xml
#   SONARR_API_KEY         - auto-read from sonarr:/config/config.xml
#   PROWLARR_API_KEY       - auto-read from prowlarr:/config/config.xml
#   BAZARR_API_KEY         - auto-read from bazarr:/config/config/config.yaml
#   JELLYFIN_API_KEY       - auto-minted via the Jellyfin API (needs the two below)
#   JELLYFIN_USERNAME      - Jellyfin admin user, used to mint the API key
#   JELLYFIN_PASSWORD      - Jellyfin admin password
#   QBITTORRENT_USERNAME   - qBittorrent WebUI user. Not discoverable: the widget
#   QBITTORRENT_PASSWORD   - authenticates with the login, and the password is
#                            stored as a PBKDF2 hash. Supply both or no tile.
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      MEDIA_TIMEZONE       "${MEDIA_TIMEZONE:-America/Sao_Paulo}" \
      MEDIA_UID            "${MEDIA_UID:-1000}" \
      MEDIA_GID            "${MEDIA_GID:-1000}" \
      MEDIA_LIBRARY_PATH   "${MEDIA_LIBRARY_PATH:-/srv/media}" \
      MEDIA_DOWNLOAD_PATH  "${MEDIA_DOWNLOAD_PATH:-/srv/downloads}" \
      CF_API_TOKEN         "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL    "${LETSENCRYPT_EMAIL:-}" \
      CERTBOT_DNS_WAIT     "${CERTBOT_DNS_WAIT:-}" \
      DOMAIN_JELLYFIN      "${DOMAIN_JELLYFIN:-}" \
      DOMAIN_QBITTORRENT   "${DOMAIN_QBITTORRENT:-}" \
      DOMAIN_RADARR        "${DOMAIN_RADARR:-}" \
      DOMAIN_SONARR        "${DOMAIN_SONARR:-}" \
      DOMAIN_PROWLARR      "${DOMAIN_PROWLARR:-}" \
      DOMAIN_BAZARR        "${DOMAIN_BAZARR:-}" \
      DOMAIN_HOMEPAGE      "${DOMAIN_HOMEPAGE:-}" \
      JELLYFIN_API_KEY     "${JELLYFIN_API_KEY:-}" \
      JELLYFIN_USERNAME    "${JELLYFIN_USERNAME:-}" \
      JELLYFIN_PASSWORD    "${JELLYFIN_PASSWORD:-}" \
      SONARR_API_KEY       "${SONARR_API_KEY:-}" \
      RADARR_API_KEY       "${RADARR_API_KEY:-}" \
      PROWLARR_API_KEY     "${PROWLARR_API_KEY:-}" \
      BAZARR_API_KEY       "${BAZARR_API_KEY:-}" \
      QBITTORRENT_USERNAME "${QBITTORRENT_USERNAME:-}" \
      QBITTORRENT_PASSWORD "${QBITTORRENT_PASSWORD:-}"
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
: "${DOMAIN_HOMEPAGE:?must be set}"

# Homepage widget credentials are all optional — see the header comment. Any
# left empty here get filled in by the discovery step after the stack starts.
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"
JELLYFIN_USERNAME="${JELLYFIN_USERNAME:-}"
JELLYFIN_PASSWORD="${JELLYFIN_PASSWORD:-}"
SONARR_API_KEY="${SONARR_API_KEY:-}"
RADARR_API_KEY="${RADARR_API_KEY:-}"
PROWLARR_API_KEY="${PROWLARR_API_KEY:-}"
BAZARR_API_KEY="${BAZARR_API_KEY:-}"
QBITTORRENT_USERNAME="${QBITTORRENT_USERNAME:-}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-}"

echo "==> Installing base dependencies..."
apt-get update -qq
# jq parses Jellyfin's API responses during Homepage credential discovery.
apt-get install -y -qq ca-certificates curl gnupg jq certbot python3-certbot-dns-cloudflare

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
  -d "${DOMAIN_HOMEPAGE}" \
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

# Homepage widget credentials live here (0600) and are injected into the
# container as HOMEPAGE_VAR_* env vars, so the config YAML stays free of secrets
# and can be read/diffed safely. Written twice: once now so the stack can start,
# and again after credential discovery has filled in whatever it could find.
write_stack_env() {
  cat > /opt/media-stack/.env <<ENV
TIMEZONE=${MEDIA_TIMEZONE}
PUID=${MEDIA_UID}
PGID=${MEDIA_GID}
HOMEPAGE_VAR_JELLYFIN_API_KEY=${JELLYFIN_API_KEY}
HOMEPAGE_VAR_SONARR_API_KEY=${SONARR_API_KEY}
HOMEPAGE_VAR_RADARR_API_KEY=${RADARR_API_KEY}
HOMEPAGE_VAR_PROWLARR_API_KEY=${PROWLARR_API_KEY}
HOMEPAGE_VAR_BAZARR_API_KEY=${BAZARR_API_KEY}
HOMEPAGE_VAR_QBITTORRENT_USERNAME=${QBITTORRENT_USERNAME}
HOMEPAGE_VAR_QBITTORRENT_PASSWORD=${QBITTORRENT_PASSWORD}
ENV
  chmod 600 /opt/media-stack/.env
}
write_stack_env

# The Homepage config dir is a bind mount — create it with the right ownership
# up front so Docker doesn't make it root-owned when the container starts.
mkdir -p /opt/media-stack/homepage
chown "${MEDIA_UID}:${MEDIA_GID}" /opt/media-stack/homepage

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

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    environment:
      - PUID=${MEDIA_UID}
      - PGID=${MEDIA_GID}
      - TZ=${MEDIA_TIMEZONE}
      # Homepage rejects any request whose Host header isn't allow-listed, and
      # nginx forwards the real host — so this must be the public vhost name.
      - HOMEPAGE_ALLOWED_HOSTS=${DOMAIN_HOMEPAGE}
      # Widget credentials, interpolated by compose from .env at up-time.
      - HOMEPAGE_VAR_JELLYFIN_API_KEY=\${HOMEPAGE_VAR_JELLYFIN_API_KEY:-}
      - HOMEPAGE_VAR_SONARR_API_KEY=\${HOMEPAGE_VAR_SONARR_API_KEY:-}
      - HOMEPAGE_VAR_RADARR_API_KEY=\${HOMEPAGE_VAR_RADARR_API_KEY:-}
      - HOMEPAGE_VAR_PROWLARR_API_KEY=\${HOMEPAGE_VAR_PROWLARR_API_KEY:-}
      - HOMEPAGE_VAR_BAZARR_API_KEY=\${HOMEPAGE_VAR_BAZARR_API_KEY:-}
      - HOMEPAGE_VAR_QBITTORRENT_USERNAME=\${HOMEPAGE_VAR_QBITTORRENT_USERNAME:-}
      - HOMEPAGE_VAR_QBITTORRENT_PASSWORD=\${HOMEPAGE_VAR_QBITTORRENT_PASSWORD:-}
    volumes:
      - /opt/media-stack/homepage:/app/config
      # Read-only, purely so the resources widget can report free space.
      - ${MEDIA_LIBRARY_PATH}:/media:ro
      - ${MEDIA_DOWNLOAD_PATH}:/downloads:ro
    expose:
      - "3000"

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
      - homepage

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
    "${DOMAIN_BAZARR}:bazarr:6767" \
    "${DOMAIN_HOMEPAGE}:homepage:3000"; do
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

# ---------------------------------------------------------------------------
# Homepage credential discovery
# ---------------------------------------------------------------------------
# The apps mint their own credentials, so rather than making you copy six keys
# by hand and re-run, read them back out of the stack we just started. Anything
# passed in via the environment wins; only the gaps get discovered. This is
# best-effort — a service that isn't up yet just ships as a plain link and gets
# picked up on the next run.
#
# qBittorrent is the exception: its widget authenticates with the WebUI login,
# and the password is stored as a PBKDF2 hash, so it can't be read back. Pass
# QBITTORRENT_USERNAME/PASSWORD to enable that one tile.
echo ""
echo "==> Discovering Homepage widget credentials..."

# On a fresh provision an app may still be writing its initial config when we
# get here, so poll rather than checking once.
wait_for_container_file() {
  local container="$1" path="$2" timeout="${3:-60}" elapsed=0
  # Waiting can't conjure a container that isn't running — without this check a
  # stack that failed to start stalls the run for the full timeout per service.
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container"; then
    return 1
  fi
  while (( elapsed < timeout )); do
    if docker exec "$container" test -f "$path" 2>/dev/null; then return 0; fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
  done
  return 1
}

# Radarr / Sonarr / Prowlarr keep <ApiKey> in /config/config.xml.
arr_api_key() {
  local container="$1"
  if ! wait_for_container_file "$container" /config/config.xml; then return 0; fi
  docker exec "$container" cat /config/config.xml 2>/dev/null \
    | sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' | head -1
}

# Bazarr uses config.yaml (>= 1.1), config.ini on older versions.
bazarr_api_key() {
  local key=""
  if wait_for_container_file bazarr /config/config/config.yaml 30; then
    key=$(docker exec bazarr sed -n 's/^[[:space:]]*apikey:[[:space:]]*//p' \
      /config/config/config.yaml 2>/dev/null | head -1 | tr -d "\"' ")
  fi
  if [[ -z "$key" ]]; then
    key=$(docker exec bazarr sed -n 's/^apikey[[:space:]]*=[[:space:]]*//p' \
      /config/config/config.ini 2>/dev/null | head -1 | tr -d "\"' ")
  fi
  printf '%s' "$key"
}

# Jellyfin keeps its keys in a SQLite DB rather than a config file, but its API
# will mint one — the same thing Dashboard > API Keys does in the UI. Needs an
# admin login. Reuses the key named "homepage" so re-runs don't pile up
# duplicates in the dashboard.
jellyfin_api_key() {
  local user="$1" pass="$2" ip token key
  if [[ -z "$user" || -z "$pass" ]]; then return 0; fi

  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
    jellyfin 2>/dev/null | awk '{print $1}')
  if [[ -z "$ip" ]]; then return 0; fi

  token=$(curl -sf -m 15 -X POST "http://${ip}:8096/Users/AuthenticateByName" \
    -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="homeserver-bootstrap", Device="install.sh", DeviceId="homeserver-bootstrap", Version="1.0.0"' \
    -d "$(jq -nc --arg u "$user" --arg p "$pass" '{Username:$u, Pw:$p}')" 2>/dev/null \
    | jq -r '.AccessToken // empty')
  if [[ -z "$token" ]]; then
    echo "  ! Jellyfin login failed — check JELLYFIN_USERNAME/JELLYFIN_PASSWORD" >&2
    return 0
  fi

  key=$(curl -sf -m 15 "http://${ip}:8096/Auth/Keys" -H "X-Emby-Token: ${token}" 2>/dev/null \
    | jq -r '.Items[]? | select(.AppName == "homepage") | .AccessToken' | head -1)
  if [[ -z "$key" ]]; then
    curl -sf -m 15 -X POST "http://${ip}:8096/Auth/Keys?App=homepage" \
      -H "X-Emby-Token: ${token}" >/dev/null 2>&1 || true
    key=$(curl -sf -m 15 "http://${ip}:8096/Auth/Keys" -H "X-Emby-Token: ${token}" 2>/dev/null \
      | jq -r '.Items[]? | select(.AppName == "homepage") | .AccessToken' | head -1)
  fi
  printf '%s' "$key"
}

if [[ -z "${RADARR_API_KEY}" ]];   then RADARR_API_KEY=$(arr_api_key radarr     || true); fi
if [[ -z "${SONARR_API_KEY}" ]];   then SONARR_API_KEY=$(arr_api_key sonarr     || true); fi
if [[ -z "${PROWLARR_API_KEY}" ]]; then PROWLARR_API_KEY=$(arr_api_key prowlarr || true); fi
if [[ -z "${BAZARR_API_KEY}" ]];   then BAZARR_API_KEY=$(bazarr_api_key         || true); fi
if [[ -z "${JELLYFIN_API_KEY}" ]]; then
  JELLYFIN_API_KEY=$(jellyfin_api_key "${JELLYFIN_USERNAME}" "${JELLYFIN_PASSWORD}" || true)
fi

for pair in "Radarr:${RADARR_API_KEY}" "Sonarr:${SONARR_API_KEY}" \
            "Prowlarr:${PROWLARR_API_KEY}" "Bazarr:${BAZARR_API_KEY}" \
            "Jellyfin:${JELLYFIN_API_KEY}" "qBittorrent:${QBITTORRENT_PASSWORD}"; do
  name="${pair%%:*}"
  if [[ -n "${pair#*:}" ]]; then echo "  ✓ ${name}"; else echo "  – ${name} (no credential — link only)"; fi
done

# Re-write .env now that discovery has filled in what it could.
write_stack_env

# ---------------------------------------------------------------------------
# Homepage dashboard config
# ---------------------------------------------------------------------------
# Homepage is entirely config-file driven — these four YAML files *are* the
# dashboard. They're rewritten on every run, so this installer is the source of
# truth; don't hand-edit /opt/media-stack/homepage on the VM.
echo ""
echo "==> Writing Homepage dashboard configuration..."
mkdir -p /opt/media-stack/homepage

# A widget whose credential is empty renders as a permanent "API Error" tile, so
# only emit the widget block once its key is actually set. Discovery above fills
# most of these in; anything it couldn't find ships as a plain link (still with
# an up/down siteMonitor) rather than a broken tile.
emit_widget() {
  local type="$1" url="$2" var="$3"
  if [[ -z "${!var:-}" ]]; then return 0; fi
  # Placeholders are quoted: Homepage substitutes them as raw text before
  # parsing, so unquoted braces would be a YAML flow mapping until it does.
  cat <<WIDGET
        widget:
          type: ${type}
          url: ${url}
          key: "{{HOMEPAGE_VAR_${var}}}"
WIDGET
}

# qBittorrent's widget authenticates with the WebUI login rather than an API key.
emit_qbittorrent_widget() {
  if [[ -z "${QBITTORRENT_USERNAME}" || -z "${QBITTORRENT_PASSWORD}" ]]; then return 0; fi
  cat <<WIDGET
        widget:
          type: qbittorrent
          url: http://qbittorrent:8080
          username: "{{HOMEPAGE_VAR_QBITTORRENT_USERNAME}}"
          password: "{{HOMEPAGE_VAR_QBITTORRENT_PASSWORD}}"
WIDGET
}

cat > /opt/media-stack/homepage/settings.yaml <<SETTINGS
title: Homelab
description: Media server dashboard
headerStyle: clean
theme: dark
color: slate
disableCollapse: true
layout:
  Media:
    style: row
    columns: 2
  Automation:
    style: row
    columns: 4
SETTINGS

# Widget URLs use the compose service names, not the public vhosts: Homepage
# talks to its neighbours directly over the stack network, so widgets keep
# working even if DNS or the cert is having a bad day.
cat > /opt/media-stack/homepage/services.yaml <<SERVICES
- Media:
    - Jellyfin:
        href: https://${DOMAIN_JELLYFIN}
        description: Movies & TV streaming
        icon: jellyfin.png
        siteMonitor: http://jellyfin:8096
$(emit_widget jellyfin http://jellyfin:8096 JELLYFIN_API_KEY)
    - qBittorrent:
        href: https://${DOMAIN_QBITTORRENT}
        description: Download client
        icon: qbittorrent.png
        siteMonitor: http://qbittorrent:8080
$(emit_qbittorrent_widget)

- Automation:
    - Radarr:
        href: https://${DOMAIN_RADARR}
        description: Movies
        icon: radarr.png
        siteMonitor: http://radarr:7878
$(emit_widget radarr http://radarr:7878 RADARR_API_KEY)
    - Sonarr:
        href: https://${DOMAIN_SONARR}
        description: TV shows
        icon: sonarr.png
        siteMonitor: http://sonarr:8989
$(emit_widget sonarr http://sonarr:8989 SONARR_API_KEY)
    - Prowlarr:
        href: https://${DOMAIN_PROWLARR}
        description: Indexers
        icon: prowlarr.png
        siteMonitor: http://prowlarr:9696
$(emit_widget prowlarr http://prowlarr:9696 PROWLARR_API_KEY)
    - Bazarr:
        href: https://${DOMAIN_BAZARR}
        description: Subtitles
        icon: bazarr.png
        siteMonitor: http://bazarr:6767
$(emit_widget bazarr http://bazarr:6767 BAZARR_API_KEY)
SERVICES

# /media and /downloads are the read-only mounts declared in the compose file.
cat > /opt/media-stack/homepage/widgets.yaml <<'WIDGETS'
- resources:
    label: Media VM
    cpu: true
    memory: true
    disk:
      - /media
      - /downloads
- search:
    provider: duckduckgo
    target: _blank
WIDGETS

# The rest of the homelab lives on other VMs, so it's plain links — this box has
# no credentials for any of it.
cat > /opt/media-stack/homepage/bookmarks.yaml <<'BOOKMARKS'
- Infrastructure:
    - Proxmox:
        - abbr: PVE
          href: https://192.168.20.10:8006
    - Argo CD:
        - abbr: CD
          href: https://argocd.internal.prakash.com.br
    - Infisical:
        - abbr: IN
          href: https://infisical.internal.prakash.com.br

- Services:
    - Garage:
        - abbr: S3
          href: https://garage-ui.internal.prakash.com.br
    - Mailpit:
        - abbr: MP
          href: https://mailpit.internal.prakash.com.br
BOOKMARKS

chown -R "${MEDIA_UID}:${MEDIA_GID}" /opt/media-stack/homepage


# Recreate homepage so it picks up the discovered HOMEPAGE_VAR_* values. nginx
# resolves `proxy_pass http://homepage:3000` once when it loads its config, so
# it must be reloaded afterwards or it keeps routing to the old container IP.
echo ""
echo "==> Applying Homepage configuration..."
/usr/bin/docker compose --project-directory /opt/media-stack up -d homepage
docker exec media-nginx nginx -s reload 2>/dev/null || true

echo ""
echo "✓ Media stack running (HTTPS via Let's Encrypt, HTTP redirects to HTTPS)."
echo "  Homepage    : https://${DOMAIN_HOMEPAGE}   <- start here"
echo "  Jellyfin    : https://${DOMAIN_JELLYFIN}"
echo "  qBittorrent : https://${DOMAIN_QBITTORRENT}"
echo "  Radarr      : https://${DOMAIN_RADARR}"
echo "  Sonarr      : https://${DOMAIN_SONARR}"
echo "  Prowlarr    : https://${DOMAIN_PROWLARR}"
echo "  Bazarr      : https://${DOMAIN_BAZARR}"

missing_widgets=()
for var in JELLYFIN_API_KEY RADARR_API_KEY SONARR_API_KEY \
           PROWLARR_API_KEY BAZARR_API_KEY QBITTORRENT_USERNAME; do
  if [[ -z "${!var:-}" ]]; then missing_widgets+=("$var"); fi
done
if [[ ${#missing_widgets[@]} -gt 0 ]]; then
  echo ""
  echo "! Homepage is showing links only for: ${missing_widgets[*]}"
  echo "  qBittorrent needs its WebUI login supplied; Jellyfin needs"
  echo "  JELLYFIN_USERNAME/JELLYFIN_PASSWORD so a key can be minted. The *arr"
  echo "  apps are read automatically once they've finished first-run setup."
fi
