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
# Design and runbook: bootstrap/forgejo/README.md
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
#   FORGEJO_VERSION      - image tag (default: 16.0.3)
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

FORGEJO_VERSION="${FORGEJO_VERSION:-16.0.3}"
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
apt-get install -y -qq certbot python3-certbot-dns-cloudflare jq sqlite3

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
# Forgejo creates the configured repository root lazily on the first repo.
# Create it now so backup pre-flights also work on a brand-new installation.
mkdir -p /opt/forgejo/data/gitea/conf /opt/forgejo/data/forgejo-repositories

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

# ---------------------------------------------------------------------------
# GitHub → Forgejo sync
#
# Forgejo holds regular repos, so something has to carry GitHub commits across.
# The primary CI trigger is a second push URL on the dev machine (a real push
# event, no latency); this timer is the safety net for anything that lands on
# GitHub another way, such as a PR merged in the GitHub UI.
#
# Its single most important property is that it NEVER force-pushes.
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/forgejo-sync-repos <<'SYNC'
#!/usr/bin/env bash
# Mirrors GitHub → Forgejo for the configured repos.
#
# NEVER force-pushes. A rejected push means Forgejo holds commits GitHub does
# not — almost always work pushed straight to Forgejo during an outage — so the
# sync stops and says so rather than deleting it.
#
# Config: /etc/forgejo-sync/repos  ("owner/name private|public", # comments ok)
#         /etc/forgejo-sync/env    (GITHUB_SYNC_PAT, FORGEJO_SYNC_TOKEN)
set -uo pipefail

CONF_DIR=/etc/forgejo-sync
STATE_DIR=/var/lib/forgejo-sync
ASKPASS=/usr/local/sbin/forgejo-sync-askpass
FORGEJO_HOST="${FORGEJO_HOST:-forgejo.internal.prakash.com.br}"
SYNC_FAIL_THRESHOLD="${SYNC_FAIL_THRESHOLD:-3}"
FORGEJO_SYNC_AUTO_CREATE="${FORGEJO_SYNC_AUTO_CREATE:-true}"

# shellcheck disable=SC1091
. "${CONF_DIR}/env"
: "${GITHUB_SYNC_PAT:?not set in ${CONF_DIR}/env}"
: "${FORGEJO_SYNC_USER:?not set in ${CONF_DIR}/env}"
: "${FORGEJO_SYNC_TOKEN:?not set in ${CONF_DIR}/env}"

install -d -m 0700 "$STATE_DIR"
rc=0

git_auth() {
  local username="$1" password="$2"
  shift 2
  GIT_ASKPASS="$ASKPASS" \
    GIT_TERMINAL_PROMPT=0 \
    GIT_SYNC_USERNAME="$username" \
    GIT_SYNC_PASSWORD="$password" \
    git "$@"
}

forgejo_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(
    -fsS -X "$method"
    -H "Authorization: token ${FORGEJO_SYNC_TOKEN}"
    -H "Accept: application/json"
  )
  [[ -z "$body" ]] || args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}" "https://${FORGEJO_HOST}/api/v1${path}"
}

ensure_forgejo_repo() {
  local repo="$1" private="$2" owner name current_user payload

  if forgejo_api GET "/repos/${repo}" >/dev/null 2>&1; then
    return 0
  fi
  [[ "$FORGEJO_SYNC_AUTO_CREATE" == "true" ]] || {
    echo "sync ${repo}: target repository is missing and auto-create is disabled" >&2
    return 1
  }

  owner="${repo%%/*}"
  name="${repo#*/}"
  current_user="$(forgejo_api GET /user | jq -r .login)" || return 1

  if [[ "$owner" == "$current_user" ]]; then
    payload="$(jq -nc --arg name "$name" --argjson private "$private" \
      '{name: $name, private: $private, auto_init: false}')"
    forgejo_api POST /user/repos "$payload" >/dev/null
  else
    if ! forgejo_api GET "/orgs/${owner}" >/dev/null 2>&1; then
      payload="$(jq -nc --arg username "$owner" \
        '{username: $username, visibility: "public"}')"
      forgejo_api POST /orgs "$payload" >/dev/null || {
        echo "sync ${repo}: could not create Forgejo organization ${owner}" >&2
        return 1
      }
    fi
    payload="$(jq -nc --arg name "$name" --argjson private "$private" \
      '{name: $name, private: $private, auto_init: false}')"
    forgejo_api POST "/orgs/${owner}/repos" "$payload" >/dev/null
  fi

  echo "sync ${repo}: created target repository"
}

while read -r repo visibility _; do
  [[ -z "$repo" || "$repo" =~ ^[[:space:]]*# ]] && continue
  visibility="${visibility:-private}"
  case "$visibility" in
    private) repo_private=true ;;
    public)  repo_private=false ;;
    *) echo "sync ${repo}: visibility must be private or public" >&2; rc=1; continue ;;
  esac
  name="${repo##*/}"
  owner="${repo%%/*}"
  work="${STATE_DIR}/${owner}--${name}.git"

  gh_url="https://github.com/${repo}.git"
  fj_url="https://${FORGEJO_HOST}/${repo}.git"

  if ! ensure_forgejo_repo "$repo" "$repo_private"; then
    echo "sync ${repo}: target repository provisioning failed" >&2
    rc=1
    continue
  fi

  if [[ ! -d "$work" ]]; then
    git_auth x-access-token "$GITHUB_SYNC_PAT" clone --bare "$gh_url" "$work" >/dev/null 2>&1 \
      || { echo "sync ${repo}: initial clone failed" >&2; rc=1; continue; }
  fi

  git -C "$work" remote set-url origin "$gh_url" 2>/dev/null \
    || git -C "$work" remote add origin "$gh_url"
  git -C "$work" remote set-url forgejo "$fj_url" 2>/dev/null \
    || git -C "$work" remote add forgejo "$fj_url"

  if ! git_auth x-access-token "$GITHUB_SYNC_PAT" -C "$work" fetch --prune origin \
      '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*' >/dev/null 2>&1; then
    echo "sync ${repo}: fetch from GitHub failed (outage?) — Forgejo left untouched" >&2
    rc=1
    continue
  fi

  # No --force, no --mirror. The rejection IS the feature.
  if ! git_auth "$FORGEJO_SYNC_USER" "$FORGEJO_SYNC_TOKEN" -C "$work" push forgejo \
      'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' >/dev/null 2>&1; then
    echo "sync ${repo}: PUSH REJECTED — Forgejo has diverged from GitHub." >&2
    echo "  Nothing was overwritten. Fetch Forgejo into a separate namespace and reconcile deliberately:" >&2
    echo "    GIT_ASKPASS=${ASKPASS} GIT_SYNC_USERNAME=${FORGEJO_SYNC_USER} GIT_SYNC_PASSWORD=<token> \\" >&2
    echo "      git -C ${work} fetch forgejo '+refs/heads/*:refs/forgejo/*'" >&2
    echo "    git -C ${work} log --left-right --graph refs/heads/main...refs/forgejo/main" >&2
    rc=1
    continue
  fi

  echo "sync ${repo}: ok"
done < "${CONF_DIR}/repos"

# Alert only after repeated failures. During a GitHub outage this runs every
# few minutes; without the threshold the incident becomes a notification storm.
if [[ $rc -ne 0 ]]; then
  fails=$(( $(cat "${STATE_DIR}/consecutive_failures" 2>/dev/null || echo 0) + 1 ))
  echo "$fails" > "${STATE_DIR}/consecutive_failures"
  if [[ $fails -ge $SYNC_FAIL_THRESHOLD ]]; then
    echo "forgejo-sync has failed ${fails} consecutive times" >&2
  fi
else
  echo 0 > "${STATE_DIR}/consecutive_failures"
fi

exit $rc
SYNC
chmod 755 /usr/local/sbin/forgejo-sync-repos

# Git credentials are supplied through the environment instead of being
# persisted in each bare repository's remote URLs. /etc/forgejo-sync/env is
# root-only, and the token never appears in `git remote -v` or config backups.
cat > /usr/local/sbin/forgejo-sync-askpass <<'ASKPASS'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' "${GIT_SYNC_USERNAME:?}" ;;
  *Password*) printf '%s\n' "${GIT_SYNC_PASSWORD:?}" ;;
  *) exit 1 ;;
esac
ASKPASS
chmod 700 /usr/local/sbin/forgejo-sync-askpass

install -d -m 0700 /etc/forgejo-sync
if [[ ! -f /etc/forgejo-sync/repos ]]; then
  cat > /etc/forgejo-sync/repos <<'REPOS'
# One "owner/name private|public" per line. Private is the safe default; mark
# mirrored git dependencies public when Actions jobs must clone them without a
# repository token. Start with infra and add app/dependency repos deliberately.
camilohollanda/homeserver private
REPOS
fi

# Placeholder so the unit fails with a clear message rather than a shell error.
if [[ ! -f /etc/forgejo-sync/env ]]; then
  cat > /etc/forgejo-sync/env <<'ENVF'
# Fill these in, then: systemctl start forgejo-sync.service
GITHUB_SYNC_PAT=
FORGEJO_SYNC_USER=
FORGEJO_SYNC_TOKEN=
# The token must be allowed to create organizations/repositories on first sync.
FORGEJO_SYNC_AUTO_CREATE=true
ENVF
  chmod 600 /etc/forgejo-sync/env
fi

cat > /etc/systemd/system/forgejo-sync.service <<'SVC'
[Unit]
Description=Sync GitHub repositories into Forgejo (fast-forward only)
Requires=forgejo.service
After=network-online.target forgejo.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/forgejo-sync-repos
SVC

cat > /etc/systemd/system/forgejo-sync.timer <<'TIMER'
[Unit]
Description=Periodic GitHub to Forgejo sync

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
# Keep the timer installed but quiet until all credentials exist. Starting it
# against the placeholder env file would create a failed unit every five
# minutes on a fresh deployment.
if (
  set -a
  # shellcheck disable=SC1091
  . /etc/forgejo-sync/env
  [[ -n "${GITHUB_SYNC_PAT:-}" && -n "${FORGEJO_SYNC_USER:-}" && -n "${FORGEJO_SYNC_TOKEN:-}" ]]
); then
  systemctl enable -q --now forgejo-sync.timer
else
  systemctl enable -q forgejo-sync.timer
  systemctl stop forgejo-sync.timer
  systemctl reset-failed forgejo-sync.service 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Backup support
#
# restic must never upload the live SQLite file: a byte-for-byte copy of a
# database being written to can capture a torn write, and you only discover
# that at restore time. `.backup` takes a consistent snapshot while the server
# keeps running, and restic backs up the snapshot instead.
#
# Registry blobs under data/packages are deliberately NOT part of the backup
# set — they are rebuildable artifacts, and paying R2 storage plus egress for
# them buys nothing.
# ---------------------------------------------------------------------------
cat > /usr/local/sbin/forgejo-db-backup <<'DUMP'
#!/bin/bash
set -euo pipefail
mkdir -p /opt/forgejo/backup
sqlite3 /opt/forgejo/data/forgejo.db ".backup '/opt/forgejo/backup/forgejo.db.tmp'"
mv /opt/forgejo/backup/forgejo.db.tmp /opt/forgejo/backup/forgejo.db
chmod 600 /opt/forgejo/backup/forgejo.db
DUMP
chmod 755 /usr/local/sbin/forgejo-db-backup

cat > /etc/systemd/system/forgejo-db-backup.service <<'SVC'
[Unit]
Description=Consistent SQLite snapshot of the Forgejo database
Requires=forgejo.service
After=forgejo.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/forgejo-db-backup
SVC

cat > /etc/systemd/system/forgejo-db-backup.timer <<'TIMER'
[Unit]
Description=Snapshot the Forgejo SQLite DB ahead of the restic run

[Timer]
# Must fire before the restic profile's first timer at 02:00 so the snapshot it
# uploads is fresh. The installer also creates one immediately for first backup.
OnCalendar=*-*-* 01:30:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable -q --now forgejo-db-backup.timer
/usr/local/sbin/forgejo-db-backup

echo ""
echo "✓ Forgejo is running."
echo "  Web UI:   https://${FORGEJO_DOMAIN}"
echo "  Git/SSH:  ssh://git@${FORGEJO_DOMAIN}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git"
echo "  Registry: ${FORGEJO_DOMAIN}/<owner>/<image>"
