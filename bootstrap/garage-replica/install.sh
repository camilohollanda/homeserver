#!/usr/bin/env bash
# Runs on the services VM (vmid 114) as root. Configures rclone to mirror every
# Garage bucket into an S3-compatible destination (Cloudflare R2 by default).
# Soft-delete semantics: deletes/overwrites in Garage become hidden versions in
# R2 (or versioned objects in B2), so a "rm -rf my-bucket" in Garage isn't fatal.
#
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   GARAGE_ACCESS_KEY_ID      - Read-only Garage key (see setup.sh)
#   GARAGE_SECRET_ACCESS_KEY  - Garage secret
#   GARAGE_S3_REGION          - default: garage (matches the Garage config)
#   DEST_ACCESS_KEY_ID        - R2/B2 access key (write-only is fine)
#   DEST_SECRET_ACCESS_KEY    - R2/B2 secret
#   DEST_ENDPOINT             - https://<account-id>.r2.cloudflarestorage.com
#                               (or https://s3.<region>.backblazeb2.com)
#   DEST_BUCKET               - Destination bucket name (mirror lives at root)
#   DEST_REGION               - default: auto (R2). For B2: us-west-002 etc.
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      GARAGE_ACCESS_KEY_ID     "${GARAGE_ACCESS_KEY_ID:-}" \
      GARAGE_SECRET_ACCESS_KEY "${GARAGE_SECRET_ACCESS_KEY:-}" \
      GARAGE_S3_REGION         "${GARAGE_S3_REGION:-garage}" \
      DEST_ACCESS_KEY_ID       "${DEST_ACCESS_KEY_ID:-}" \
      DEST_SECRET_ACCESS_KEY   "${DEST_SECRET_ACCESS_KEY:-}" \
      DEST_ENDPOINT            "${DEST_ENDPOINT:-}" \
      DEST_BUCKET              "${DEST_BUCKET:-}" \
      DEST_REGION              "${DEST_REGION:-auto}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

: "${GARAGE_ACCESS_KEY_ID:?must be set}"
: "${GARAGE_SECRET_ACCESS_KEY:?must be set}"
: "${DEST_ACCESS_KEY_ID:?must be set}"
: "${DEST_SECRET_ACCESS_KEY:?must be set}"
: "${DEST_ENDPOINT:?must be set}"
: "${DEST_BUCKET:?must be set}"

GARAGE_S3_REGION="${GARAGE_S3_REGION:-garage}"
DEST_REGION="${DEST_REGION:-auto}"

# Detect the destination provider from the endpoint so we can pick the right
# rclone backend (R2 needs provider=Cloudflare; B2's S3 endpoint works with
# provider=Other).
if [[ "$DEST_ENDPOINT" == *r2.cloudflarestorage.com* ]]; then
  DEST_PROVIDER="Cloudflare"
elif [[ "$DEST_ENDPOINT" == *backblazeb2.com* ]]; then
  DEST_PROVIDER="Other"
else
  DEST_PROVIDER="Other"
fi

# ---------------------------------------------------------------------------
# Prereqs
# ---------------------------------------------------------------------------
if [[ ! -f /opt/garage/garage.toml ]]; then
  echo "Error: Garage not installed on this VM. Run bootstrap/garage/install.sh first." >&2
  exit 1
fi

echo "==> Installing rclone..."
# Pin to a version with mature R2 support. Debian's apt rclone is too old
# (v1.60-DEV ships on Debian 12) and returns "501 Not Implemented" on R2 PUTs
# because it predates the proper Cloudflare provider handling (added v1.62+).
RCLONE_VERSION="${RCLONE_VERSION:-v1.69.0}"
RCLONE_BIN="/usr/local/bin/rclone"

needs_install=true
if [[ -x "$RCLONE_BIN" ]] && "$RCLONE_BIN" version 2>/dev/null | head -1 | grep -q "${RCLONE_VERSION#v}"; then
  needs_install=false
fi

if $needs_install; then
  # If apt's rclone is on PATH, get it out of the way so /usr/local/bin wins.
  if dpkg -s rclone >/dev/null 2>&1; then
    apt-get remove -y -qq rclone
  fi
  apt-get install -y -qq curl unzip
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/rclone/rclone/releases/download/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip"
  curl -fsSL -o "$tmp/rclone.zip" "$url"
  unzip -q -o "$tmp/rclone.zip" -d "$tmp"
  install -m 0755 "$tmp/rclone-${RCLONE_VERSION}-linux-amd64/rclone" "$RCLONE_BIN"
  echo "  ✓ rclone $($RCLONE_BIN version | head -1)"
else
  echo "  rclone ${RCLONE_VERSION} already installed — skipping."
fi

# ---------------------------------------------------------------------------
# rclone config — system-wide, owned by root
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing /root/.config/rclone/rclone.conf..."
install -d -m 0700 /root/.config/rclone

cat > /root/.config/rclone/rclone.conf <<RCLONE
[garage]
type = s3
provider = Other
access_key_id = ${GARAGE_ACCESS_KEY_ID}
secret_access_key = ${GARAGE_SECRET_ACCESS_KEY}
endpoint = http://127.0.0.1:3900
region = ${GARAGE_S3_REGION}
# Garage uses path-style addressing
force_path_style = true

[dest]
type = s3
provider = ${DEST_PROVIDER}
access_key_id = ${DEST_ACCESS_KEY_ID}
secret_access_key = ${DEST_SECRET_ACCESS_KEY}
endpoint = ${DEST_ENDPOINT}
region = ${DEST_REGION}
RCLONE
chmod 0600 /root/.config/rclone/rclone.conf

# ---------------------------------------------------------------------------
# Replication script — mirrors each Garage bucket under its own prefix in dest
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing /usr/local/sbin/garage-replicate..."

cat > /usr/local/sbin/garage-replicate <<REPL
#!/usr/bin/env bash
# Sync every bucket in Garage into a single destination bucket, one prefix per
# source bucket. --backup-dir keeps a dated copy of anything we overwrite or
# delete, so "rm -rf in Garage" doesn't propagate as a hard delete.
set -euo pipefail

DEST_BUCKET="${DEST_BUCKET}"
STAMP=\$(date -u +%Y%m%d)

# Ask Garage which buckets exist (admin API on 127.0.0.1:3903 is unauthenticated
# in single-node mode; list via the S3 API instead using the read-only key).
buckets=\$(rclone lsd garage: 2>/dev/null | awk '{print \$NF}')

if [[ -z "\$buckets" ]]; then
  echo "No buckets found in Garage — nothing to replicate." >&2
  exit 0
fi

for b in \$buckets; do
  echo "==> Replicating garage:\$b -> dest:\${DEST_BUCKET}/\$b/"
  rclone sync "garage:\$b" "dest:\${DEST_BUCKET}/\$b" \\
    --fast-list \\
    --transfers 8 \\
    --checkers 16 \\
    --checksum \\
    --backup-dir "dest:\${DEST_BUCKET}/_trash/\$b/\$STAMP" \\
    --log-level INFO
done
REPL
chmod 0755 /usr/local/sbin/garage-replicate

# ---------------------------------------------------------------------------
# Systemd service + timer
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing systemd units..."

cat > /etc/systemd/system/garage-replica.service <<'SVC'
[Unit]
Description=Replicate Garage buckets to remote S3
After=network-online.target garage.service
Wants=network-online.target
Requires=garage.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/garage-replicate
# Network/IO is the bottleneck — keep this kind to the host.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
SVC

cat > /etc/systemd/system/garage-replica.timer <<'TMR'
[Unit]
Description=Daily Garage replication to remote S3

[Timer]
# Run after the restic window (02:00–02:30) and after the wal-g base backup (03:00).
OnCalendar=*-*-* 05:00:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now garage-replica.timer

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
echo ""
echo "==> Smoke-testing connectivity..."
if rclone lsd garage: >/dev/null 2>&1; then
  echo "  ✓ Can list Garage buckets"
else
  echo "  ✗ Cannot list Garage buckets — check GARAGE_ACCESS_KEY_ID permissions." >&2
  exit 1
fi
if rclone lsd "dest:${DEST_BUCKET}" >/dev/null 2>&1; then
  echo "  ✓ Can list destination bucket"
else
  echo "  ✗ Cannot list dest:${DEST_BUCKET} — check destination creds + bucket existence." >&2
  exit 1
fi

echo ""
echo "✓ Garage replica configured."
echo "  Destination: ${DEST_ENDPOINT} / ${DEST_BUCKET}"
echo "  Schedule   : daily 05:00 (+30m jitter)"
echo "  Run now    : sudo systemctl start garage-replica.service"
echo "  Tail logs  : journalctl -u garage-replica.service -f"
