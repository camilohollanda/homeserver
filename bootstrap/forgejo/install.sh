#!/usr/bin/env bash
# Runs on the Forgejo VM (vmid 119) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.24 ./install.sh
#
# Forgejo as a warm failover for GitHub Actions: git forge + Actions control
# plane + OCI registry.
#
# GitHub stays canonical. Repos here are REGULAR repos, never pull mirrors: a
# pull mirror is read-only and would reject the very push you need to make
# during a GitHub outage, which is the whole point of the failover. Keeping
# them writable is what costs us the sync timer.
#
# Spec: docs/superpowers/specs/2026-08-06-forgejo-actions-design.md
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (Zone.DNS Edit) for DNS-01
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt
#   FORGEJO_DOMAIN       - FQDN (e.g. forgejo.internal.prakash.com.br)
#   FORGEJO_ADMIN_USER   - Initial admin username
#   FORGEJO_ADMIN_PASS   - Initial admin password
#   FORGEJO_ADMIN_EMAIL  - Initial admin email
#
# Optional env vars:
#   FORGEJO_VERSION      - image tag (default: 15.0.1)
#   FORGEJO_SSH_PORT     - host port for Forgejo's SSH server (default: 2222)
#   FORGEJO_DATA_DEV     - data disk device (default: /dev/sdb)
#   FORGEJO_PKG_KEEP_H   - package retention in hours (default: 2160 = 90d)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN        "${CF_API_TOKEN:-}" \
      LETSENCRYPT_EMAIL   "${LETSENCRYPT_EMAIL:-}" \
      FORGEJO_DOMAIN      "${FORGEJO_DOMAIN:-}" \
      FORGEJO_ADMIN_USER  "${FORGEJO_ADMIN_USER:-}" \
      FORGEJO_ADMIN_PASS  "${FORGEJO_ADMIN_PASS:-}" \
      FORGEJO_ADMIN_EMAIL "${FORGEJO_ADMIN_EMAIL:-}" \
      FORGEJO_VERSION     "${FORGEJO_VERSION:-}" \
      FORGEJO_SSH_PORT    "${FORGEJO_SSH_PORT:-}" \
      FORGEJO_DATA_DEV    "${FORGEJO_DATA_DEV:-}" \
      FORGEJO_PKG_KEEP_H  "${FORGEJO_PKG_KEEP_H:-}"
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
: "${FORGEJO_DOMAIN:?must be set}"
: "${FORGEJO_ADMIN_USER:?must be set}"
: "${FORGEJO_ADMIN_PASS:?must be set}"
: "${FORGEJO_ADMIN_EMAIL:?must be set}"

FORGEJO_VERSION="${FORGEJO_VERSION:-15.0.1}"
FORGEJO_SSH_PORT="${FORGEJO_SSH_PORT:-2222}"
FORGEJO_DATA_DEV="${FORGEJO_DATA_DEV:-/dev/sdb}"
FORGEJO_PKG_KEEP_H="${FORGEJO_PKG_KEEP_H:-2160}"

# ---------------------------------------------------------------------------
# Data disk: repos, SQLite and registry blobs
#
# Only format when the device has NO filesystem at all. Any other signature
# means something else owns this disk — bail rather than destroy it. Same guard
# bootstrap/garage/install.sh uses for the Garage data disk on VM 114.
# ---------------------------------------------------------------------------
echo "==> Preparing ${FORGEJO_DATA_DEV}..."
if [[ ! -b "$FORGEJO_DATA_DEV" ]]; then
  echo "Error: ${FORGEJO_DATA_DEV} is not a block device." >&2
  exit 1
fi

FSTYPE="$(blkid -o value -s TYPE "$FORGEJO_DATA_DEV" 2>/dev/null || true)"
case "$FSTYPE" in
  "")   echo "  No filesystem — creating ext4."; mkfs.ext4 -q -L forgejo-data "$FORGEJO_DATA_DEV" ;;
  ext4) echo "  Already ext4 — leaving as is." ;;
  *)    echo "Error: ${FORGEJO_DATA_DEV} holds a ${FSTYPE} filesystem; refusing to overwrite." >&2; exit 1 ;;
esac

mkdir -p /opt/forgejo
DISK_UUID="$(blkid -o value -s UUID "$FORGEJO_DATA_DEV")"
if ! grep -q "$DISK_UUID" /etc/fstab; then
  echo "UUID=${DISK_UUID} /opt/forgejo ext4 defaults,noatime 0 2" >> /etc/fstab
fi
mountpoint -q /opt/forgejo || mount /opt/forgejo

# ---------------------------------------------------------------------------
# Docker
#
# Log rotation is configured here, on day one, rather than after an incident.
# On 2026-08-04 an uncapped json-file log reached 22.8 GiB on the services VM,
# filled the disk, and took down every ClusterSecretStore in the cluster. The
# cap costs nothing and removes the whole class.
# ---------------------------------------------------------------------------
echo "==> Installing Docker..."
if ! command -v docker >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
systemctl restart docker

# ---------------------------------------------------------------------------
# TLS
#
# This VM hosts a single app, so it does NOT replicate the shared nginx from
# VM 114 — Forgejo terminates TLS itself, the same way VMs 113/115/116 handle
# their own listeners. certbot is installed here rather than inherited.
# ---------------------------------------------------------------------------
echo "==> Installing certbot and obtaining the certificate..."
apt-get install -y -qq certbot python3-certbot-dns-cloudflare sqlite3

install -d -m 0700 /etc/letsencrypt
cat > /etc/letsencrypt/cloudflare.ini <<INI
dns_cloudflare_api_token = ${CF_API_TOKEN}
INI
chmod 600 /etc/letsencrypt/cloudflare.ini

if [ ! -d "/etc/letsencrypt/live/${FORGEJO_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${FORGEJO_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# Forgejo reads the cert at startup and cannot read /etc/letsencrypt as uid
# 1000, so keep readable copies inside the data dir. Same shape Mailpit uses
# for its SMTP TLS.
mkdir -p /opt/forgejo/data/certs

cat > /usr/local/sbin/forgejo-rebuild-cert <<REBUILD
#!/bin/bash
set -euo pipefail
DOMAIN="${FORGEJO_DOMAIN}"
SRC=/etc/letsencrypt/live/\${DOMAIN}
DST=/opt/forgejo/data/certs
[[ -f "\${SRC}/fullchain.pem" && -f "\${SRC}/privkey.pem" ]] || { echo "LE cert for \${DOMAIN} not present" >&2; exit 1; }
umask 022
cp "\${SRC}/fullchain.pem" "\${DST}/cert.pem.tmp"
cp "\${SRC}/privkey.pem"   "\${DST}/key.pem.tmp"
mv "\${DST}/cert.pem.tmp" "\${DST}/cert.pem"
mv "\${DST}/key.pem.tmp"  "\${DST}/key.pem"
chown 1000:1000 "\${DST}/cert.pem" "\${DST}/key.pem"
chmod 640 "\${DST}/cert.pem" "\${DST}/key.pem"
REBUILD
chmod 755 /usr/local/sbin/forgejo-rebuild-cert
/usr/local/sbin/forgejo-rebuild-cert

# The shared-nginx reload hook on VM 114 does not exist here; this VM restarts
# its own container instead.
cat > /etc/letsencrypt/renewal-hooks/deploy/restart-forgejo.sh <<HOOK
#!/bin/bash
# Only act when *our* cert renews.
if [[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${FORGEJO_DOMAIN}" ]]; then
  /usr/local/sbin/forgejo-rebuild-cert
  docker restart forgejo >/dev/null 2>&1 || true
fi
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/restart-forgejo.sh

# ---------------------------------------------------------------------------
# app.ini
# ---------------------------------------------------------------------------
echo "==> Writing app.ini..."
mkdir -p /opt/forgejo/data/gitea/conf

# Regenerating these on every run would invalidate all sessions and stored 2FA
# secrets, so reuse whatever a previous run already wrote.
CONF=/opt/forgejo/data/gitea/conf/app.ini
if [[ -f "$CONF" ]]; then
  FORGEJO_SECRET_KEY="$(awk -F' *= *' '/^SECRET_KEY/{print $2; exit}' "$CONF")"
  FORGEJO_INTERNAL_TOKEN="$(awk -F' *= *' '/^INTERNAL_TOKEN/{print $2; exit}' "$CONF")"
fi
FORGEJO_SECRET_KEY="${FORGEJO_SECRET_KEY:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"
FORGEJO_INTERNAL_TOKEN="${FORGEJO_INTERNAL_TOKEN:-$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-48)}"

cat > "$CONF" <<INI
APP_NAME = Forgejo — homeserver
RUN_MODE = prod
RUN_USER = git

[server]
PROTOCOL         = https
DOMAIN           = ${FORGEJO_DOMAIN}
ROOT_URL         = https://${FORGEJO_DOMAIN}/
HTTP_PORT        = 3000
CERT_FILE        = /data/certs/cert.pem
KEY_FILE         = /data/certs/key.pem
START_SSH_SERVER = true
SSH_DOMAIN       = ${FORGEJO_DOMAIN}
SSH_PORT         = ${FORGEJO_SSH_PORT}
SSH_LISTEN_PORT  = 2222
LFS_START_SERVER = true

[database]
DB_TYPE = sqlite3
PATH    = /data/forgejo.db

[repository]
ROOT = /data/forgejo-repositories

[security]
INSTALL_LOCK   = true
SECRET_KEY     = ${FORGEJO_SECRET_KEY}
INTERNAL_TOKEN = ${FORGEJO_INTERNAL_TOKEN}

[service]
DISABLE_REGISTRATION = true

[packages]
ENABLED = true

# Immutable per-commit image tags grow without bound. Retention is mandatory,
# not tuning: a full disk here breaks image pulls for every migrated app.
[cron.cleanup_packages]
ENABLED      = true
RUN_AT_START = false
SCHEDULE     = @midnight
OLDER_THAN   = ${FORGEJO_PKG_KEEP_H}h

[actions]
ENABLED = true
# Defaults to https://data.forgejo.org, which mirrors the common actions — so
# actions/checkout and friends do NOT resolve from github.com. Stated
# explicitly because the entire failover depends on it.
DEFAULT_ACTIONS_URL = https://data.forgejo.org

[log]
LEVEL = Info
INI
chmod 640 "$CONF"
chown -R 1000:1000 /opt/forgejo/data

# ---------------------------------------------------------------------------
# Stack
# ---------------------------------------------------------------------------
cat > /opt/forgejo/docker-compose.yml <<COMPOSE
services:
  forgejo:
    image: codeberg.org/forgejo/forgejo:${FORGEJO_VERSION}
    container_name: forgejo
    restart: unless-stopped
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
    ports:
      # Forgejo terminates TLS itself: host 443 maps to the container's 3000.
      - "0.0.0.0:443:3000"
      - "0.0.0.0:${FORGEJO_SSH_PORT}:2222"
    volumes:
      - /opt/forgejo/data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
COMPOSE

cat > /etc/systemd/system/forgejo.service <<'SVC'
[Unit]
Description=Forgejo — git forge, Actions control plane, OCI registry
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/forgejo
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

echo "==> Starting Forgejo..."
systemctl daemon-reload
systemctl enable -q forgejo
if systemctl is-active --quiet forgejo; then
  systemctl restart forgejo
else
  systemctl start forgejo
fi

echo -n "  Waiting for Forgejo"
for _ in $(seq 1 60); do
  if curl -sk -o /dev/null "https://127.0.0.1/api/v1/version"; then echo " ✓"; break; fi
  echo -n "."
  sleep 2
done

# ---------------------------------------------------------------------------
# Admin user — created once, then left alone
# ---------------------------------------------------------------------------
if docker exec -u git forgejo forgejo admin user list 2>/dev/null | awk '{print $2}' | grep -qx "${FORGEJO_ADMIN_USER}"; then
  echo "  Admin user already exists — skipping."
else
  docker exec -u git forgejo forgejo admin user create \
    --admin \
    --username "${FORGEJO_ADMIN_USER}" \
    --password "${FORGEJO_ADMIN_PASS}" \
    --email "${FORGEJO_ADMIN_EMAIL}" \
    --must-change-password=false
fi

echo ""
echo "✓ Forgejo is running."
echo "  Web UI:   https://${FORGEJO_DOMAIN}"
echo "  Git/SSH:  ssh://git@${FORGEJO_DOMAIN}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git"
echo "  Registry: ${FORGEJO_DOMAIN}/<owner>/<image>"
