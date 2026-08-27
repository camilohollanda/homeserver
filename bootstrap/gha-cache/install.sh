#!/usr/bin/env bash
# Runs on the services VM (vmid 114) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Self-hosted GitHub Actions cache server (falcondev-oss/github-actions-cache-server).
# Drop-in replacement for the GitHub-hosted cache service used by actions/cache@v4.
# Storage backend: Garage on the same VM (S3-compatible).
#
# Required env vars:
#   CF_API_TOKEN          - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL     - Email for Let's Encrypt
#   GHA_CACHE_DOMAIN      - FQDN (e.g. gha-cache.internal.prakash.com.br)
#   GHA_CACHE_S3_BUCKET   - Garage bucket name (e.g. gha-cache)
#   GHA_CACHE_S3_KEY_ID   - Garage access key id
#   GHA_CACHE_S3_SECRET   - Garage secret access key
#
# Optional env vars:
#   GHA_CACHE_VERSION         - image tag (default: 9.7.0)
#   GHA_CACHE_PORT            - loopback port (default: 3000)
#   GHA_CACHE_S3_ENDPOINT     - S3 endpoint URL (default: https://garage.internal.prakash.com.br)
#   GHA_CACHE_S3_REGION       - S3 region label (default: garage)
#   GHA_CACHE_S3_SOCKET_TIMEOUT_MS - S3 inactivity timeout (default: 30000)
#   GHA_CACHE_CLEANUP_DAYS    - cache TTL in days, 0 disables (default: 14)
#   GHA_CACHE_MAX_SIZE_BYTES  - hard cache payload cap (default: 200 GiB)
#   GHA_CACHE_MGMT_API_KEY    - random string to enable /management-api (default: unset → disabled)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN           "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL      "${LETSENCRYPT_EMAIL:-}" \
      GHA_CACHE_DOMAIN       "${GHA_CACHE_DOMAIN:-}" \
      GHA_CACHE_S3_BUCKET    "${GHA_CACHE_S3_BUCKET:-}" \
      GHA_CACHE_S3_KEY_ID    "${GHA_CACHE_S3_KEY_ID:-}" \
      GHA_CACHE_S3_SECRET    "${GHA_CACHE_S3_SECRET:-}" \
      GHA_CACHE_VERSION      "${GHA_CACHE_VERSION:-}" \
      GHA_CACHE_PORT         "${GHA_CACHE_PORT:-}" \
      GHA_CACHE_S3_ENDPOINT  "${GHA_CACHE_S3_ENDPOINT:-}" \
      GHA_CACHE_S3_REGION    "${GHA_CACHE_S3_REGION:-}" \
      GHA_CACHE_S3_SOCKET_TIMEOUT_MS "${GHA_CACHE_S3_SOCKET_TIMEOUT_MS:-}" \
      GHA_CACHE_CLEANUP_DAYS "${GHA_CACHE_CLEANUP_DAYS:-}" \
      GHA_CACHE_MAX_SIZE_BYTES "${GHA_CACHE_MAX_SIZE_BYTES:-}" \
      GHA_CACHE_MGMT_API_KEY "${GHA_CACHE_MGMT_API_KEY:-}"
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
: "${GHA_CACHE_DOMAIN:?must be set}"
: "${GHA_CACHE_S3_BUCKET:?must be set}"
: "${GHA_CACHE_S3_KEY_ID:?must be set}"
: "${GHA_CACHE_S3_SECRET:?must be set}"

GHA_CACHE_VERSION="${GHA_CACHE_VERSION:-9.7.0}"
GHA_CACHE_PORT="${GHA_CACHE_PORT:-3000}"
GHA_CACHE_S3_ENDPOINT="${GHA_CACHE_S3_ENDPOINT:-https://garage.internal.prakash.com.br}"
GHA_CACHE_S3_REGION="${GHA_CACHE_S3_REGION:-garage}"
GHA_CACHE_S3_SOCKET_TIMEOUT_MS="${GHA_CACHE_S3_SOCKET_TIMEOUT_MS:-30000}"
GHA_CACHE_CLEANUP_DAYS="${GHA_CACHE_CLEANUP_DAYS:-14}"
GHA_CACHE_MAX_SIZE_BYTES="${GHA_CACHE_MAX_SIZE_BYTES:-214748364800}"
GHA_CACHE_MGMT_API_KEY="${GHA_CACHE_MGMT_API_KEY:-}"

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
# Let's Encrypt certificate for GHA_CACHE_DOMAIN (DNS-01)
# ---------------------------------------------------------------------------
echo ""
echo "==> Obtaining Let's Encrypt certificate for ${GHA_CACHE_DOMAIN}..."

if [ ! -d "/etc/letsencrypt/live/${GHA_CACHE_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${GHA_CACHE_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# gha-cache stack files
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing gha-cache configuration..."
mkdir -p /opt/gha-cache/data

# Derive the bare hostname from the S3 endpoint URL for extra_hosts below.
# Garage runs on this same VM; without this pinning, every cache op does a
# public-DNS round-trip (we observed intermittent EAI_AGAIN failures).
GHA_CACHE_S3_HOST="${GHA_CACHE_S3_ENDPOINT#*://}"
GHA_CACHE_S3_HOST="${GHA_CACHE_S3_HOST%%/*}"
GHA_CACHE_S3_HOST="${GHA_CACHE_S3_HOST%%:*}"

cat > /opt/gha-cache/.env <<ENV
GHA_CACHE_VERSION=${GHA_CACHE_VERSION}
GHA_CACHE_PORT=${GHA_CACHE_PORT}
GHA_CACHE_DOMAIN=${GHA_CACHE_DOMAIN}
GHA_CACHE_S3_BUCKET=${GHA_CACHE_S3_BUCKET}
GHA_CACHE_S3_ENDPOINT=${GHA_CACHE_S3_ENDPOINT}
GHA_CACHE_S3_HOST=${GHA_CACHE_S3_HOST}
GHA_CACHE_S3_REGION=${GHA_CACHE_S3_REGION}
GHA_CACHE_S3_SOCKET_TIMEOUT_MS=${GHA_CACHE_S3_SOCKET_TIMEOUT_MS}
GHA_CACHE_S3_KEY_ID=${GHA_CACHE_S3_KEY_ID}
GHA_CACHE_S3_SECRET=${GHA_CACHE_S3_SECRET}
GHA_CACHE_CLEANUP_DAYS=${GHA_CACHE_CLEANUP_DAYS}
GHA_CACHE_MAX_SIZE_BYTES=${GHA_CACHE_MAX_SIZE_BYTES}
GHA_CACHE_MGMT_API_KEY=${GHA_CACHE_MGMT_API_KEY}
ENV
chmod 600 /opt/gha-cache/.env

# Cache server binds loopback only; shared nginx fronts it with TLS.
# Runners authenticate to GitHub-issued tokens, which the server validates
# against api.github.com — so the public URL must match API_BASE_URL exactly.
cat > /opt/gha-cache/docker-compose.yml <<'COMPOSE'
services:
  gha-cache:
    image: ghcr.io/falcondev-oss/github-actions-cache-server:${GHA_CACHE_VERSION}
    container_name: gha-cache
    restart: unless-stopped
    # Pin Garage's FQDN to the Docker bridge gateway (= the host's interface
    # on this bridge). The shared services nginx runs on host networking and
    # answers on every host interface, so TLS + SNI still work — we just skip
    # an external DNS round-trip on every cache request. Fixes intermittent
    # EAI_AGAIN failures that were breaking downloads (and merges).
    extra_hosts:
      - "${GHA_CACHE_S3_HOST}:host-gateway"
    ports:
      - "127.0.0.1:${GHA_CACHE_PORT}:3000"
    environment:
      API_BASE_URL: "https://${GHA_CACHE_DOMAIN}"
      STORAGE_DRIVER: s3
      STORAGE_S3_BUCKET: ${GHA_CACHE_S3_BUCKET}
      AWS_ENDPOINT_URL: ${GHA_CACHE_S3_ENDPOINT}
      AWS_REGION: ${GHA_CACHE_S3_REGION}
      STORAGE_S3_SOCKET_TIMEOUT_MS: ${GHA_CACHE_S3_SOCKET_TIMEOUT_MS}
      AWS_ACCESS_KEY_ID: ${GHA_CACHE_S3_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${GHA_CACHE_S3_SECRET}
      # AWS SDK v3 (>=3.729) added default CRC32 checksum validation on every
      # GetObject / PutObject. Garage's CRC32 implementation doesn't match what
      # the SDK recomputes from the response body, so every cache download
      # crashes with "Checksum mismatch ... x-amz-checksum-crc32". Disable both
      # sides — the cache action does its own integrity check on top of this.
      # See: https://docs.aws.amazon.com/sdkref/latest/guide/feature-dataintegrity.html
      AWS_RESPONSE_CHECKSUM_VALIDATION: when_required
      AWS_REQUEST_CHECKSUM_CALCULATION: when_required
      DB_DRIVER: sqlite
      DB_SQLITE_PATH: /data/cache-server.db
      CACHE_CLEANUP_OLDER_THAN_DAYS: ${GHA_CACHE_CLEANUP_DAYS}
      CACHE_MAX_SIZE_BYTES: ${GHA_CACHE_MAX_SIZE_BYTES}
      MANAGEMENT_API_KEY: ${GHA_CACHE_MGMT_API_KEY}
    volumes:
      - /opt/gha-cache/data:/data
COMPOSE

# Vhost served by the shared services proxy (/opt/services).
# Cache uploads/downloads are large opaque blobs — disable buffering and
# size limits so nginx streams straight through to the upstream.
cat > /opt/services/conf.d/gha-cache.conf <<NGINX
upstream gha_cache_upstream { server 127.0.0.1:${GHA_CACHE_PORT}; }

server {
  listen 80;
  server_name ${GHA_CACHE_DOMAIN};
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${GHA_CACHE_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${GHA_CACHE_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${GHA_CACHE_DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers   HIGH:!aNULL:!MD5;

  client_max_body_size 0;
  proxy_request_buffering off;
  proxy_buffering off;
  proxy_read_timeout 600s;
  proxy_send_timeout 600s;

  location / {
    proxy_pass http://gha_cache_upstream;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
  }
}
NGINX

cat > /etc/systemd/system/gha-cache.service <<'SVC'
[Unit]
Description=Self-hosted GitHub Actions cache server
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/gha-cache
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start gha-cache
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting gha-cache..."
systemctl daemon-reload
systemctl enable gha-cache

if systemctl is-active --quiet gha-cache; then
  systemctl restart gha-cache
else
  systemctl start gha-cache
fi

# Wait for the cache server to respond locally. The root path returns 404
# (no route), so we probe a known route — /healthcheck — which the nitro
# server exposes for liveness.
echo -n "  Waiting for cache server"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GHA_CACHE_PORT}/healthcheck" || true)"
  if [[ "$code" =~ ^(200|204|404)$ ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

# Reload the shared services proxy so the vhost takes effect
docker exec services nginx -s reload 2>/dev/null || systemctl restart services

echo ""
echo "✓ gha-cache is running."
echo "  URL:            https://${GHA_CACHE_DOMAIN}/"
echo "  Storage:        s3://${GHA_CACHE_S3_BUCKET} on ${GHA_CACHE_S3_ENDPOINT}"
echo "  Retention:      ${GHA_CACHE_CLEANUP_DAYS} days"
echo "  Capacity cap:   ${GHA_CACHE_MAX_SIZE_BYTES} bytes"
if [[ -n "$GHA_CACHE_MGMT_API_KEY" ]]; then
  echo "  Management API: https://${GHA_CACHE_DOMAIN}/management-api/_docs"
fi
echo ""
echo "  Point runners at it by setting on each runner:"
echo "    ACTIONS_RESULTS_URL=https://${GHA_CACHE_DOMAIN}/"
echo "  (NOTE: the official actions/runner overwrites this unless its"
echo "   Runner.Worker.dll has been patched — bootstrap/gh-runners handles this.)"
