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
# Docker daemon log rotation
#
# json-file logs are *unbounded* by default. On 2026-08-04 Infisical's own
# request log reached 22.8 GiB (~294 MiB/day at INFO) and filled this VM's
# 40 GB disk. Redis, unable to write its RDB snapshot, entered MISCONF and
# began rejecting every write; that 500'd Infisical's auth endpoint, which
# took all seven ClusterSecretStores and thirteen ExternalSecrets in the k3s
# cluster down with it. Capping the logs is the fix for the whole class, not
# just for Infisical — every container on this VM had the same exposure.
#
# This is the daemon-wide *default*, so it only applies to containers created
# after it lands; existing stacks need one `docker compose up -d
# --force-recreate` to pick it up. A per-service `logging:` block in a compose
# file still overrides it (see bootstrap/ai, bootstrap/whisper).
#
# 10m x 3 matches the cap already used on the ai/whisper VMs. Local files are
# only a buffer — promtail ships everything to Loki, which is where log history
# actually lives.
# ---------------------------------------------------------------------------
echo "==> Configuring Docker log rotation..."
mkdir -p /etc/docker
_daemon_json_before="$(cat /etc/docker/daemon.json 2>/dev/null || true)"
cat > /etc/docker/daemon.json <<'DAEMONJSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMONJSON
if [[ "$_daemon_json_before" != "$(cat /etc/docker/daemon.json)" ]]; then
  echo "    daemon.json changed — restarting docker"
  systemctl restart docker
else
  echo "    daemon.json already current — no restart needed"
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

# ---------------------------------------------------------------------------
# Daily docker prune
#
# Unlike the gh-runners VM (which churns per-job images and uses --volumes
# + until=24h), this VM hosts long-lived services with one real volume
# (Infisical's Redis). Two deliberate differences:
#   - NO --volumes: docker quirk — `--volumes` ignores --filter, so a
#     transient stop/start during the prune could remove a real volume.
#   - until=168h: image refresh cadence here is days/weeks, not minutes.
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/docker-prune.service <<'PRUNESVC'
[Unit]
Description=Prune dangling Docker containers/images on services VM
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker system prune -af --filter until=168h
PRUNESVC

cat > /etc/systemd/system/docker-prune.timer <<'PRUNETIMER'
[Unit]
Description=Daily Docker cleanup on services VM

[Timer]
OnCalendar=daily
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
PRUNETIMER

systemctl daemon-reload
systemctl enable --now docker-prune.timer

echo ""
echo "✓ Shared services proxy is running on host ports 80 / 443."
echo "  Vhosts directory: /opt/services/conf.d/"
echo "  Reload after editing:  docker exec services nginx -s reload"
echo "  Daily docker prune:    systemctl list-timers docker-prune.timer"
