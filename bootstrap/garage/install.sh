#!/usr/bin/env bash
# Runs on the services VM (currently vmid 114) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt
#   GARAGE_DOMAIN        - FQDN for Garage (e.g. garage.internal.prakash.com.br)
#   GARAGE_RPC_SECRET    - 64-char hex (openssl rand -hex 32)
#   GARAGE_ADMIN_TOKEN   - random token (openssl rand -base64 32)
#
# Optional env vars:
#   GARAGE_VERSION       - image tag (default: v1.0.1)
#   GARAGE_DATA_DEVICE   - block device for data dir (default: /dev/sdb)
#   GARAGE_DATA_MOUNT    - mountpoint inside VM (default: /var/lib/garage/data)
#   GARAGE_META_DIR      - metadata path on OS disk (default: /var/lib/garage/meta)
#   GARAGE_S3_REGION     - region label (default: garage)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN         "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL    "${LETSENCRYPT_EMAIL:-}" \
      GARAGE_DOMAIN        "${GARAGE_DOMAIN:-}" \
      GARAGE_RPC_SECRET    "${GARAGE_RPC_SECRET:-}" \
      GARAGE_ADMIN_TOKEN   "${GARAGE_ADMIN_TOKEN:-}" \
      GARAGE_VERSION       "${GARAGE_VERSION:-}" \
      GARAGE_DATA_DEVICE   "${GARAGE_DATA_DEVICE:-}" \
      GARAGE_DATA_MOUNT    "${GARAGE_DATA_MOUNT:-}" \
      GARAGE_META_DIR      "${GARAGE_META_DIR:-}" \
      GARAGE_S3_REGION     "${GARAGE_S3_REGION:-}"
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
: "${GARAGE_DOMAIN:?must be set}"
: "${GARAGE_RPC_SECRET:?must be set}"
: "${GARAGE_ADMIN_TOKEN:?must be set}"

GARAGE_VERSION="${GARAGE_VERSION:-v1.0.1}"
GARAGE_DATA_DEVICE="${GARAGE_DATA_DEVICE:-/dev/sdb}"
GARAGE_DATA_MOUNT="${GARAGE_DATA_MOUNT:-/var/lib/garage/data}"
GARAGE_META_DIR="${GARAGE_META_DIR:-/var/lib/garage/meta}"
GARAGE_S3_REGION="${GARAGE_S3_REGION:-garage}"

# ---------------------------------------------------------------------------
# Prereqs: shared services proxy must already exist
# ---------------------------------------------------------------------------
if [[ ! -f /opt/services/docker-compose.yml ]]; then
  echo "Error: shared services proxy not installed. Run bootstrap/services/install.sh first." >&2
  exit 1
fi
if ! command -v docker &>/dev/null; then
  echo "Error: docker missing. Run bootstrap/services/install.sh first (it installs Docker)." >&2
  exit 1
fi
if ! command -v certbot &>/dev/null; then
  echo "Error: certbot missing. Run bootstrap/services/install.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Data disk: format if blank, mount, persist in fstab
# ---------------------------------------------------------------------------
echo ""
echo "==> Preparing data disk ${GARAGE_DATA_DEVICE} -> ${GARAGE_DATA_MOUNT}..."

if [[ ! -b "$GARAGE_DATA_DEVICE" ]]; then
  echo "Error: block device ${GARAGE_DATA_DEVICE} not present."
  echo "Attach a virtio disk to VM 114 in Proxmox (storage: tank), then re-run."
  exit 1
fi

EXISTING_FSTYPE="$(blkid -o value -s TYPE "$GARAGE_DATA_DEVICE" 2>/dev/null || true)"
if [[ -z "$EXISTING_FSTYPE" ]]; then
  echo "  ${GARAGE_DATA_DEVICE} is unformatted — creating ext4 filesystem..."
  mkfs.ext4 -L garage-data -m 0 "$GARAGE_DATA_DEVICE"
elif [[ "$EXISTING_FSTYPE" != "ext4" ]]; then
  echo "Error: ${GARAGE_DATA_DEVICE} already has filesystem type '${EXISTING_FSTYPE}'."
  echo "Refusing to reformat. Verify the device is correct, wipe manually if intended."
  exit 1
else
  echo "  ${GARAGE_DATA_DEVICE} already ext4 — keeping existing filesystem."
fi

mkdir -p "$GARAGE_DATA_MOUNT" "$GARAGE_META_DIR"

DATA_UUID="$(blkid -o value -s UUID "$GARAGE_DATA_DEVICE")"
FSTAB_LINE="UUID=${DATA_UUID} ${GARAGE_DATA_MOUNT} ext4 defaults,noatime,nofail 0 2"

if ! grep -qE "^UUID=${DATA_UUID}\s" /etc/fstab; then
  echo "  Adding fstab entry for UUID=${DATA_UUID}"
  echo "$FSTAB_LINE" >> /etc/fstab
fi

if ! mountpoint -q "$GARAGE_DATA_MOUNT"; then
  mount "$GARAGE_DATA_MOUNT"
fi

echo "  ✓ ${GARAGE_DATA_MOUNT} mounted ($(df -h "$GARAGE_DATA_MOUNT" | awk 'NR==2 {print $2" total, "$4" free"}'))"

# Garage runs as UID 1000 inside the official image
chown -R 1000:1000 "$GARAGE_DATA_MOUNT" "$GARAGE_META_DIR"

# ---------------------------------------------------------------------------
# Let's Encrypt certificate for GARAGE_DOMAIN (DNS-01)
# ---------------------------------------------------------------------------
echo ""
echo "==> Obtaining Let's Encrypt certificate for ${GARAGE_DOMAIN}..."

if [ ! -d "/etc/letsencrypt/live/${GARAGE_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${GARAGE_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# Garage stack files
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing Garage configuration..."
mkdir -p /opt/garage

cat > /opt/garage/garage.toml <<TOML
metadata_dir = "${GARAGE_META_DIR}"
data_dir = "${GARAGE_DATA_MOUNT}"
db_engine = "lmdb"

replication_factor = 1

rpc_bind_addr = "127.0.0.1:3901"
rpc_public_addr = "127.0.0.1:3901"

[s3_api]
s3_region = "${GARAGE_S3_REGION}"
# Bound on all interfaces so cloudflared on the k3s VM can reach it over the LAN
# for public hostnames (storage.werify.app, storage.iddh.com.br). All requests
# are SigV4-signed; unauthenticated callers get 403. The shared services nginx
# still proxies the internal vhost via 127.0.0.1:3900 — that path is unchanged.
api_bind_addr = "0.0.0.0:3900"

[admin]
api_bind_addr = "127.0.0.1:3903"
TOML

cat > /opt/garage/.env <<ENV
GARAGE_VERSION=${GARAGE_VERSION}
GARAGE_RPC_SECRET=${GARAGE_RPC_SECRET}
GARAGE_ADMIN_TOKEN=${GARAGE_ADMIN_TOKEN}
ENV
chmod 600 /opt/garage/.env

cat > /opt/garage/docker-compose.yml <<'COMPOSE'
services:
  garage:
    image: dxflrs/garage:${GARAGE_VERSION}
    container_name: garage
    restart: unless-stopped
    network_mode: host
    environment:
      GARAGE_RPC_SECRET: ${GARAGE_RPC_SECRET}
      GARAGE_ADMIN_TOKEN: ${GARAGE_ADMIN_TOKEN}
    volumes:
      - /opt/garage/garage.toml:/etc/garage.toml:ro
      - /var/lib/garage/meta:/var/lib/garage/meta
      - /var/lib/garage/data:/var/lib/garage/data
COMPOSE

cat > /etc/systemd/system/garage.service <<'SVC'
[Unit]
Description=Garage S3-compatible object storage
Requires=docker.service
After=docker.service local-fs.target
RequiresMountsFor=/var/lib/garage/data

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/garage
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Vhost in the shared services proxy
# ---------------------------------------------------------------------------
echo ""
echo "==> Registering vhost ${GARAGE_DOMAIN} in shared services proxy..."

cat > /opt/services/conf.d/garage.conf <<NGINX
server {
  listen 80;
  server_name ${GARAGE_DOMAIN};
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${GARAGE_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${GARAGE_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${GARAGE_DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers   HIGH:!aNULL:!MD5;

  # S3 needs unbuffered, unbounded body sizes for large object uploads
  client_max_body_size 0;
  proxy_request_buffering off;
  proxy_buffering off;
  proxy_read_timeout 600s;
  proxy_send_timeout 600s;

  location / {
    proxy_pass http://127.0.0.1:3900;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
  }
}
NGINX

# ---------------------------------------------------------------------------
# Start Garage
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Garage..."
systemctl daemon-reload
systemctl enable garage

if systemctl is-active --quiet garage; then
  systemctl restart garage
else
  systemctl start garage
fi

# Wait for S3 endpoint to respond locally
echo -n "  Waiting for S3 endpoint"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3900/ || true)"
  if [[ "$code" =~ ^(200|400|403)$ ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

# Reload the shared services proxy so the Garage vhost takes effect
docker exec services nginx -s reload 2>/dev/null || systemctl restart services

# ---------------------------------------------------------------------------
# One-time cluster layout: assign this node to a single-node layout
# ---------------------------------------------------------------------------
echo ""
echo "==> Configuring single-node layout..."

GARAGE_EXEC=(docker exec -e GARAGE_RPC_SECRET="$GARAGE_RPC_SECRET" garage /garage)

CAPACITY_GB="$(df -BG --output=size "$GARAGE_DATA_MOUNT" | tail -1 | tr -d ' G')"

if "${GARAGE_EXEC[@]}" layout show 2>/dev/null | grep -qE '^[0-9a-f]{16}'; then
  echo "  Layout already applied — skipping."
else
  NODE_ID="$("${GARAGE_EXEC[@]}" node id -q | cut -d@ -f1)"
  echo "  Node ID: ${NODE_ID}"
  "${GARAGE_EXEC[@]}" layout assign -z dc1 -c "${CAPACITY_GB}G" "$NODE_ID"
  "${GARAGE_EXEC[@]}" layout apply --version 1
fi

echo ""
echo "✓ Garage is running."
echo "  S3 endpoint (LAN):    https://${GARAGE_DOMAIN}  (region: ${GARAGE_S3_REGION})"
echo "  S3 endpoint (public): https://storage.werify.app, https://storage.iddh.com.br"
echo "                        (served via Cloudflare Tunnel; run bootstrap/k3s/cloudflared-config.sh"
echo "                         to refresh ingress + DNS routes if they aren't wired yet)"
echo ""
echo "  Per-app provisioning (bucket + key + CORS) — use the helper:"
echo "    bootstrap/garage/configure-app.sh <bucket> <endpoint-host> '<origin1,origin2,...>'"
echo ""
echo "  Manual (no CORS — fine for server-side only):"
echo "    sudo docker exec garage /garage bucket create myapp"
echo "    sudo docker exec garage /garage key create myapp-key"
echo "    sudo docker exec garage /garage bucket allow --read --write --owner myapp --key myapp-key"
