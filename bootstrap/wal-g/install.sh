#!/usr/bin/env bash
# Runs on a postgres VM as root.
# Installs wal-g, wires PostgreSQL's archive_command to push WAL segments to an
# S3-compatible bucket (Cloudflare R2 by default), and schedules a daily base
# backup + weekly retention prune. Together these give point-in-time recovery.
#
# Remote: REMOTE_HOST=deployer@192.168.20.23 WALG_PREFIX=wal-g-18 ./install.sh
#
# The target is deliberately NOT hardcoded: this script restarts the cluster, so
# running it against a live database is destructive. That mattered during the
# blue/green upgrade, when 113 (.21, PG 17) was production and 118 (.23) was the
# target; 113 was decommissioned on 2026-08-27 and 118 is now the only database
# VM, but the argument for keeping the target explicit is unchanged.
#
# Required env vars:
#   S3_ACCESS_KEY_ID      - Access key for the bucket (R2 API token or B2 keyID)
#   S3_SECRET_ACCESS_KEY  - Secret for the bucket
#   S3_ENDPOINT           - S3 API endpoint URL (no trailing slash)
#                           R2: https://<account-id>.r2.cloudflarestorage.com
#                           B2: https://s3.<region>.backblazeb2.com
#   S3_BUCKET             - Bucket name (e.g. homeserver-pg-walg)
#   WALG_LIBSODIUM_KEY    - 32-byte libsodium key, hex-encoded (openssl rand -hex 32)
#
# Optional env vars:
#   S3_REGION             - default: auto (R2 accepts "auto"; B2 wants "us-west-002" etc.)
#   PG_VERSION            - default: 18
#   WALG_VERSION          - default: 3.0.8
#   WALG_RETAIN_FULL      - number of base backups to keep (default: 7)
#   WALG_PREFIX           - path inside the bucket (default: wal-g)
#                           A NEW CLUSTER NEEDS A NEW PREFIX. pg_upgrade and a
#                           fresh initdb both produce a new system identifier and
#                           restart WAL at 000000010000000000000001, colliding
#                           with the existing cluster's segment names. wal-g's
#                           split-brain check only works against clean storage,
#                           and mixing the two corrupts PITR and breaks
#                           `wal-g wal-verify integrity` (used by
#                           scripts/check-backups.sh).
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      S3_ACCESS_KEY_ID     "${S3_ACCESS_KEY_ID:-}" \
      S3_SECRET_ACCESS_KEY "${S3_SECRET_ACCESS_KEY:-}" \
      S3_ENDPOINT          "${S3_ENDPOINT:-}" \
      S3_BUCKET            "${S3_BUCKET:-}" \
      S3_REGION            "${S3_REGION:-auto}" \
      WALG_LIBSODIUM_KEY   "${WALG_LIBSODIUM_KEY:-}" \
      PG_VERSION           "${PG_VERSION:-18}" \
      WALG_VERSION         "${WALG_VERSION:-3.0.8}" \
      WALG_RETAIN_FULL     "${WALG_RETAIN_FULL:-7}" \
      WALG_PREFIX          "${WALG_PREFIX:-wal-g}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

: "${S3_ACCESS_KEY_ID:?must be set}"
: "${S3_SECRET_ACCESS_KEY:?must be set}"
: "${S3_ENDPOINT:?must be set}"
: "${S3_BUCKET:?must be set}"
: "${WALG_LIBSODIUM_KEY:?must be set}"

S3_REGION="${S3_REGION:-auto}"
PG_VERSION="${PG_VERSION:-18}"
WALG_VERSION="${WALG_VERSION:-3.0.8}"
WALG_RETAIN_FULL="${WALG_RETAIN_FULL:-7}"
WALG_PREFIX="${WALG_PREFIX:-wal-g}"

PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
[[ -f "$PG_CONF" ]] || { echo "Error: ${PG_CONF} not found — is postgres installed?" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Install wal-g
# ---------------------------------------------------------------------------
echo "==> Installing wal-g ${WALG_VERSION}..."

if ! command -v wal-g >/dev/null 2>&1 || ! wal-g --version 2>&1 | grep -q "${WALG_VERSION}"; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  # Artifact naming changed at v3.0.8: dropped the "ubuntu-" infix.
  # Pick the asset that matches this version's convention.
  case "${WALG_VERSION}" in
    3.0.[0-7]|2.*|1.*|0.*) asset="wal-g-pg-ubuntu-22.04-amd64" ;;
    *)                     asset="wal-g-pg-22.04-amd64" ;;
  esac
  url="https://github.com/wal-g/wal-g/releases/download/v${WALG_VERSION}/${asset}.tar.gz"
  curl -fsSL -o "$tmp/wal-g.tar.gz" "$url"
  tar -xzf "$tmp/wal-g.tar.gz" -C "$tmp"
  install -m 0755 "$tmp/${asset}" /usr/local/bin/wal-g
  echo "  ✓ wal-g $(/usr/local/bin/wal-g --version | head -1)"
else
  echo "  wal-g ${WALG_VERSION} already installed — skipping."
fi

# ---------------------------------------------------------------------------
# wal-g config (consumed by archive_command wrapper + systemd units)
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing /etc/wal-g/wal-g.env..."
install -d -m 0750 -o postgres -g postgres /etc/wal-g

cat > /etc/wal-g/wal-g.env <<ENV
# S3-compatible target. To swap R2 → B2, change S3_ENDPOINT + S3_REGION on the
# command line and re-run install.sh — nothing else needs to change here.
WALG_S3_PREFIX=s3://${S3_BUCKET}/${WALG_PREFIX}
AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}
AWS_ENDPOINT=${S3_ENDPOINT}
AWS_REGION=${S3_REGION}
AWS_S3_FORCE_PATH_STYLE=true
WALG_LIBSODIUM_KEY=${WALG_LIBSODIUM_KEY}
WALG_COMPRESSION_METHOD=brotli
PGHOST=/var/run/postgresql
ENV
chown postgres:postgres /etc/wal-g/wal-g.env
chmod 0640 /etc/wal-g/wal-g.env

# Wrapper so archive_command can be a single absolute path — keeps PG happy
# and avoids leaking env vars through ps(1).
cat > /usr/local/bin/wal-g-push <<'EOF'
#!/bin/sh
set -a; . /etc/wal-g/wal-g.env; set +a
exec /usr/local/bin/wal-g wal-push "$1"
EOF
chmod 0755 /usr/local/bin/wal-g-push

# ---------------------------------------------------------------------------
# Enable archiving in postgresql.conf (idempotent)
# ---------------------------------------------------------------------------
echo ""
echo "==> Enabling WAL archiving in ${PG_CONF}..."

if grep -q '^# --- wal-g ---' "$PG_CONF"; then
  echo "  Block already present — replacing settings in place."
  sed -i \
    -e "s|^archive_mode = .*|archive_mode = on|" \
    -e "s|^archive_command = .*|archive_command = '/usr/local/bin/wal-g-push %p'|" \
    "$PG_CONF"
else
  cat >> "$PG_CONF" <<'PGCONF'

# --- wal-g ---
# Continuous WAL archiving to S3-compatible storage. Changing archive_mode
# requires a full restart (not just reload); the install script handles that.
archive_mode = on
archive_timeout = 60
archive_command = '/usr/local/bin/wal-g-push %p'
PGCONF
fi

# archive_mode change needs a full restart, not just a reload.
systemctl restart "postgresql@${PG_VERSION}-main"

# Wait for the cluster to accept queries, then ask Postgres (authoritatively)
# where its data dir lives — on this VM it's not the Debian default.
echo -n "  Waiting for postgres to accept queries"
for _ in $(seq 1 30); do
  if sudo -u postgres pg_isready -q; then echo " ✓"; break; fi
  echo -n "."; sleep 1
done

PG_DATA="$(sudo -u postgres psql -tAc 'SHOW data_directory' 2>/dev/null | tr -d '[:space:]')"
if [[ -z "$PG_DATA" || ! -d "$PG_DATA" ]]; then
  echo "Error: could not determine PostgreSQL data_directory (got: '${PG_DATA}')" >&2
  exit 1
fi
echo "  PG data_directory: ${PG_DATA}"

# ---------------------------------------------------------------------------
# Daily base backup + weekly prune
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing systemd units..."

cat > /etc/systemd/system/wal-g-basebackup.service <<SVC
[Unit]
Description=wal-g base backup of PostgreSQL ${PG_VERSION}
After=postgresql.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=postgres
Group=postgres
EnvironmentFile=/etc/wal-g/wal-g.env
ExecStart=/usr/local/bin/wal-g backup-push ${PG_DATA}
SVC

cat > /etc/systemd/system/wal-g-basebackup.timer <<'TMR'
[Unit]
Description=Daily wal-g base backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
TMR

cat > /etc/systemd/system/wal-g-prune.service <<SVC
[Unit]
Description=wal-g retention prune (keep ${WALG_RETAIN_FULL} fulls + their WAL)
After=network-online.target

[Service]
Type=oneshot
User=postgres
Group=postgres
EnvironmentFile=/etc/wal-g/wal-g.env
ExecStart=/usr/local/bin/wal-g delete retain FULL ${WALG_RETAIN_FULL} --confirm
ExecStart=/usr/local/bin/wal-g delete garbage --confirm
SVC

cat > /etc/systemd/system/wal-g-prune.timer <<'TMR'
[Unit]
Description=Weekly wal-g prune

[Timer]
OnCalendar=Sun 04:30:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now wal-g-basebackup.timer wal-g-prune.timer

# ---------------------------------------------------------------------------
# First base backup (synchronous so we fail loudly if creds are wrong)
# ---------------------------------------------------------------------------
echo ""
echo "==> Running initial base backup (synchronous — first one validates creds)..."
if sudo -u postgres bash -c 'set -a; . /etc/wal-g/wal-g.env; set +a; wal-g backup-list 2>/dev/null | tail -n +2 | grep -q .'; then
  echo "  Existing backups present — skipping initial push."
else
  systemctl start wal-g-basebackup.service
fi

echo ""
echo "✓ wal-g configured."
echo "  Bucket   : s3://${S3_BUCKET}/${WALG_PREFIX}"
echo "  Endpoint : ${S3_ENDPOINT}"
echo "  List     : sudo -u postgres bash -c 'set -a; . /etc/wal-g/wal-g.env; wal-g backup-list'"
echo "  Restore  : see https://github.com/wal-g/wal-g/blob/master/docs/PostgreSQL.md#backup-fetch"
