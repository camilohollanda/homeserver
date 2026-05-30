#!/usr/bin/env bash
# Runs on the services VM (currently vmid 114) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Installs (or upgrades) Garage AND the Noooste/garage-ui dashboard in one pass.
# Both run as containers on the services VM, behind the shared nginx:
#
#   https://${GARAGE_DOMAIN}     -> 127.0.0.1:3900  (Garage S3 API)
#   https://${GARAGE_UI_DOMAIN}  -> 127.0.0.1:8080  (garage-ui web dashboard)
#
# Required env vars:
#   CF_API_TOKEN          - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL     - Email for Let's Encrypt
#   GARAGE_DOMAIN         - FQDN for the S3 endpoint (e.g. garage.internal.prakash.com.br)
#   GARAGE_UI_DOMAIN      - FQDN for the web UI    (e.g. garage-ui.internal.prakash.com.br)
#   GARAGE_RPC_SECRET     - 64-char hex (openssl rand -hex 32)
#   GARAGE_ADMIN_TOKEN    - random token (openssl rand -base64 32); shared with the UI
#
# Optional env vars:
#   GARAGE_VERSION        - image tag (default: v2.3.0). Must be v2.1.0+ for the UI.
#   GARAGE_UI_VERSION     - image tag (default: latest)
#   GARAGE_DATA_DEVICE    - block device for data dir (default: /dev/sdb)
#   GARAGE_DATA_MOUNT     - mountpoint inside VM (default: /var/lib/garage/data)
#   GARAGE_META_DIR       - metadata path on OS disk (default: /var/lib/garage/meta)
#   GARAGE_S3_REGION      - region label (default: garage)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN         "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL    "${LETSENCRYPT_EMAIL:-}" \
      GARAGE_DOMAIN        "${GARAGE_DOMAIN:-}" \
      GARAGE_UI_DOMAIN     "${GARAGE_UI_DOMAIN:-}" \
      GARAGE_RPC_SECRET    "${GARAGE_RPC_SECRET:-}" \
      GARAGE_ADMIN_TOKEN   "${GARAGE_ADMIN_TOKEN:-}" \
      GARAGE_VERSION       "${GARAGE_VERSION:-}" \
      GARAGE_UI_IMAGE      "${GARAGE_UI_IMAGE:-}" \
      GARAGE_UI_VERSION    "${GARAGE_UI_VERSION:-}" \
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
: "${GARAGE_UI_DOMAIN:?must be set}"
: "${GARAGE_RPC_SECRET:?must be set}"
: "${GARAGE_ADMIN_TOKEN:?must be set}"

GARAGE_VERSION="${GARAGE_VERSION:-v2.3.0}"
GARAGE_UI_VERSION="${GARAGE_UI_VERSION:-bulk-delete}"
# Using the camilohollanda fork — it adds object-level delete on top of Noooste's
# UI. Override with GARAGE_UI_IMAGE / GARAGE_UI_VERSION if you switch back to
# upstream (noooste/garage-ui).
GARAGE_UI_IMAGE="${GARAGE_UI_IMAGE:-ghcr.io/camilohollanda/garage-ui}"
GARAGE_DATA_DEVICE="${GARAGE_DATA_DEVICE:-/dev/sdb}"
GARAGE_DATA_MOUNT="${GARAGE_DATA_MOUNT:-/var/lib/garage/data}"
GARAGE_META_DIR="${GARAGE_META_DIR:-/var/lib/garage/meta}"
GARAGE_S3_REGION="${GARAGE_S3_REGION:-garage}"

# Refuse to install a UI-incompatible Garage. The UI needs v2.1.0+ and the
# admin API auth changed between v1 and v2, so a v1 image will leave the UI
# unable to talk to the cluster.
case "$GARAGE_VERSION" in
  v0.*|v1.*) echo "Error: GARAGE_VERSION=$GARAGE_VERSION is incompatible with garage-ui (needs v2.1.0+)." >&2; exit 1 ;;
esac

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
# Let's Encrypt certificates (DNS-01) for both vhosts
# ---------------------------------------------------------------------------
for d in "$GARAGE_DOMAIN" "$GARAGE_UI_DOMAIN"; do
  echo ""
  echo "==> Obtaining Let's Encrypt certificate for ${d}..."
  if [ ! -d "/etc/letsencrypt/live/${d}" ]; then
    certbot certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
      -d "${d}" \
      --non-interactive --agree-tos \
      -m "${LETSENCRYPT_EMAIL}"
  else
    echo "  Certificate already exists — skipping."
  fi
done

# ---------------------------------------------------------------------------
# v1 -> v2 metadata snapshot (only if we're upgrading across the major boundary)
# ---------------------------------------------------------------------------
PREV_VERSION=""
if [[ -f /opt/garage/.env ]]; then
  PREV_VERSION="$(awk -F= '/^GARAGE_VERSION=/{print $2}' /opt/garage/.env | tr -d '"' | head -n1)"
fi

if [[ "$PREV_VERSION" =~ ^v1\. && "$GARAGE_VERSION" =~ ^v2\. ]]; then
  STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
  BAK="${GARAGE_META_DIR}.v1-bak.${STAMP}"
  echo ""
  echo "==> Detected v1 -> v2 upgrade from ${PREV_VERSION}. Snapshotting metadata to ${BAK}..."
  systemctl stop garage 2>/dev/null || true
  cp -a "$GARAGE_META_DIR" "$BAK"
  echo "  ✓ snapshot created ($(du -sh "$BAK" | awk '{print $1}'))"
  echo "  (Rollback: stop garage, rm -rf ${GARAGE_META_DIR}, mv ${BAK} ${GARAGE_META_DIR}, restore v1 image.)"
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
api_bind_addr = "127.0.0.1:3900"

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
      # tracing-subscriber emits ANSI colors by default — disable so logs are
      # readable both in `docker logs garage` and downstream in Loki/Grafana.
      NO_COLOR: "1"
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
# garage-ui stack files
#
# Auth mode: admin-token. The UI's login screen accepts the Garage admin
# token directly — no separate user database, no OIDC dance. Same token we
# already store in Infisical under /Garage/. Swap to OIDC later by editing
# /opt/garage-ui/config.yaml.
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing garage-ui configuration..."
mkdir -p /opt/garage-ui

# JWT signing key — generate once, persist so sessions survive container
# restarts. Ed25519 PEM, exactly what the UI expects.
if [[ ! -s /opt/garage-ui/jwt-key.pem ]]; then
  openssl genpkey -algorithm ED25519 -out /opt/garage-ui/jwt-key.pem
fi
chmod 600 /opt/garage-ui/jwt-key.pem

# Indent the PEM so it slots cleanly into the YAML literal-block scalar (`|`).
JWT_KEY_INDENTED="$(sed 's/^/      /' /opt/garage-ui/jwt-key.pem)"

cat > /opt/garage-ui/config.yaml <<YAML
server:
  host: "0.0.0.0"
  # 8090, NOT 8080 — Infisical's web container already binds 127.0.0.1:8080
  # on this VM. Both apps land on the same loopback via network_mode: host,
  # so collisions are silent (the second binder just fails to start).
  port: 8090
  environment: "production"
  domain: "${GARAGE_UI_DOMAIN}"
  protocol: "https"
  root_url: "https://${GARAGE_UI_DOMAIN}"
  # Match the shared-nginx client_max_body_size (60m) so the UI can accept
  # the same upload sizes nginx will forward to it.
  max_body_size: 62914560

garage:
  endpoint: "http://127.0.0.1:3900"
  region: "${GARAGE_S3_REGION}"
  admin_endpoint: "http://127.0.0.1:3903"
  admin_token: "${GARAGE_ADMIN_TOKEN}"

auth:
  jwt_private_key: |
${JWT_KEY_INDENTED}
  admin:
    enabled: false
  token:
    enabled: true
  oidc:
    enabled: false

cors:
  enabled: false

logging:
  level: "info"
  format: "json"
YAML

# The image runs as a non-root user, so root-owned 0600 means "container can't
# read it" → crash-loop. Discover the image's UID/GID and chown to match.
GARAGE_UI_UID="$(docker run --rm --entrypoint id "${GARAGE_UI_IMAGE}:${GARAGE_UI_VERSION}" -u)"
GARAGE_UI_GID="$(docker run --rm --entrypoint id "${GARAGE_UI_IMAGE}:${GARAGE_UI_VERSION}" -g)"
chown "${GARAGE_UI_UID}:${GARAGE_UI_GID}" /opt/garage-ui/config.yaml
chmod 600 /opt/garage-ui/config.yaml

cat > /opt/garage-ui/.env <<ENV
GARAGE_UI_IMAGE=${GARAGE_UI_IMAGE}
GARAGE_UI_VERSION=${GARAGE_UI_VERSION}
ENV
chmod 600 /opt/garage-ui/.env

cat > /opt/garage-ui/docker-compose.yml <<'COMPOSE'
services:
  garage-ui:
    image: ${GARAGE_UI_IMAGE}:${GARAGE_UI_VERSION}
    container_name: garage-ui
    restart: unless-stopped
    # host network: the UI needs to reach Garage on 127.0.0.1:{3900,3903},
    # and the shared nginx proxies to it on 127.0.0.1:8090. Same pattern as
    # the Garage container.
    network_mode: host
    volumes:
      - /opt/garage-ui/config.yaml:/app/config.yaml:ro
COMPOSE

cat > /etc/systemd/system/garage-ui.service <<'SVC'
[Unit]
Description=Garage UI - web dashboard for Garage S3 storage
Requires=docker.service garage.service
After=docker.service garage.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/garage-ui
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Vhosts in the shared services proxy
# ---------------------------------------------------------------------------
echo ""
echo "==> Registering vhosts in shared services proxy..."

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

  # Large enough for non-chunked single-shot uploads; chunks stream straight through
  client_max_body_size 60m;
  proxy_request_buffering off;
  proxy_buffering off;
  proxy_read_timeout 120s;
  proxy_send_timeout 120s;

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

cat > /opt/services/conf.d/garage-ui.conf <<NGINX
server {
  listen 80;
  server_name ${GARAGE_UI_DOMAIN};
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${GARAGE_UI_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${GARAGE_UI_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${GARAGE_UI_DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers   HIGH:!aNULL:!MD5;

  # Match max_body_size in garage-ui config.yaml — drag-and-drop uploads pass
  # through nginx before the UI hands them to Garage.
  client_max_body_size 60m;
  proxy_request_buffering off;
  proxy_buffering off;
  proxy_read_timeout 120s;
  proxy_send_timeout 120s;

  location / {
    proxy_pass http://127.0.0.1:8090;
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
# Start / restart Garage, then the UI
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Garage..."
systemctl daemon-reload
systemctl enable garage garage-ui

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

# Wait for admin endpoint — the UI will fail to start cleanly if the admin
# API isn't answering yet.
echo -n "  Waiting for admin endpoint"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${GARAGE_ADMIN_TOKEN}" http://127.0.0.1:3903/v2/GetClusterStatus || true)"
  if [[ "$code" =~ ^(200|404)$ ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "==> Starting garage-ui..."
if systemctl is-active --quiet garage-ui; then
  systemctl restart garage-ui
else
  systemctl start garage-ui
fi

echo -n "  Waiting for UI"
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8090/ || true)"
  if [[ "$code" =~ ^(200|302|401)$ ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

# Reload the shared services proxy so both vhosts take effect
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
echo "✓ Garage ${GARAGE_VERSION} + garage-ui ${GARAGE_UI_VERSION} are running."
echo "  S3 endpoint: https://${GARAGE_DOMAIN}      (region: ${GARAGE_S3_REGION})"
echo "  Web UI:      https://${GARAGE_UI_DOMAIN}   (log in with GARAGE_ADMIN_TOKEN)"
echo ""
echo "  Create a bucket + key:"
echo "    sudo docker exec garage /garage bucket create myapp"
echo "    sudo docker exec garage /garage key create myapp-key"
echo "    sudo docker exec garage /garage bucket allow --read --write --owner myapp --key myapp-key"
