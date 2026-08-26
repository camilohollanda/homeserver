#!/usr/bin/env bash
# Runs on any VM as root. Installs restic, points it at an S3-compatible bucket
# (Cloudflare R2 by default), and schedules one daily systemd timer per JOB.
#
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Required env vars:
#   S3_ACCESS_KEY_ID      - Bucket access key
#   S3_SECRET_ACCESS_KEY  - Bucket secret
#   S3_ENDPOINT           - S3 API endpoint URL (no trailing slash, no scheme suffix)
#                           R2: https://<account-id>.r2.cloudflarestorage.com
#                           B2: https://s3.<region>.backblazeb2.com
#   S3_BUCKET             - Bucket name (shared across hosts; per-host prefix below)
#   RESTIC_PASSWORD       - Repo passphrase; LOSING THIS LOSES THE BACKUPS
#   JOBS                  - Space-separated "name:/path[,/path...]" entries, e.g.
#                           "services-data:/opt/garage/meta app-conf:/opt/infisical/data"
#
# Optional env vars:
#   RESTIC_HOST_PREFIX    - Path prefix inside the bucket. Default: hostname -s.
#                           Each host gets its own repo at s3://$S3_BUCKET/$RESTIC_HOST_PREFIX.
#   RESTIC_KEEP_DAILY     - default: 7
#   RESTIC_KEEP_WEEKLY    - default: 4
#   RESTIC_KEEP_MONTHLY   - default: 6
if [[ -n "${REMOTE_HOST:-}" ]]; then
  # Skip `sudo` when SSHing in as root (e.g. the Proxmox host, which doesn't
  # ship sudo by default).
  remote_sh="sudo bash -s"
  [[ "${REMOTE_HOST%%@*}" == "root" ]] && remote_sh="bash -s"
  { printf 'export %s=%q\n' \
      S3_ACCESS_KEY_ID     "${S3_ACCESS_KEY_ID:-}" \
      S3_SECRET_ACCESS_KEY "${S3_SECRET_ACCESS_KEY:-}" \
      S3_ENDPOINT          "${S3_ENDPOINT:-}" \
      S3_BUCKET            "${S3_BUCKET:-}" \
      RESTIC_PASSWORD      "${RESTIC_PASSWORD:-}" \
      RESTIC_HOST_PREFIX   "${RESTIC_HOST_PREFIX:-}" \
      RESTIC_KEEP_DAILY    "${RESTIC_KEEP_DAILY:-7}" \
      RESTIC_KEEP_WEEKLY   "${RESTIC_KEEP_WEEKLY:-4}" \
      RESTIC_KEEP_MONTHLY  "${RESTIC_KEEP_MONTHLY:-6}" \
      JOBS                 "${JOBS:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "$remote_sh"
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
: "${RESTIC_PASSWORD:?must be set}"
: "${JOBS:?must be set (e.g. \"services-data:/opt/garage/meta\")}"

RESTIC_HOST_PREFIX="${RESTIC_HOST_PREFIX:-$(hostname -s)}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-7}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-4}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-6}"

# ---------------------------------------------------------------------------
# Install restic
# ---------------------------------------------------------------------------
echo "==> Installing restic..."
if ! command -v restic >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq restic
else
  echo "  restic already installed ($(restic version | head -1)) — skipping."
fi

# ---------------------------------------------------------------------------
# Shared environment file (one repo per host, in the same bucket)
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing /etc/restic/repo.env..."

# Strip a leading https:// — restic's S3 backend takes the endpoint without scheme.
S3_ENDPOINT_NOSCHEME="${S3_ENDPOINT#https://}"
S3_ENDPOINT_NOSCHEME="${S3_ENDPOINT_NOSCHEME#http://}"

install -d -m 0700 /etc/restic
cat > /etc/restic/repo.env <<ENV
# To swap R2 → B2 (or any S3), regenerate this file with a different S3_ENDPOINT.
# The restic repo URL uses the S3 backend, so endpoint is the only thing that varies.
RESTIC_REPOSITORY=s3:${S3_ENDPOINT_NOSCHEME}/${S3_BUCKET}/${RESTIC_HOST_PREFIX}
RESTIC_PASSWORD=${RESTIC_PASSWORD}
AWS_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}
ENV
chmod 0600 /etc/restic/repo.env

# Init repo if it doesn't exist yet (idempotent).
set -a; . /etc/restic/repo.env; set +a
if ! restic snapshots >/dev/null 2>&1; then
  echo "  Repo not initialised — running restic init..."
  restic init
else
  echo "  Repo already initialised."
fi

# ---------------------------------------------------------------------------
# One systemd service+timer per job
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing per-job systemd units..."

# Stagger the timers (02:00, 02:10, 02:20, ...) so they don't all fire at once.
i=0
declare -a installed_timers=()
for job in $JOBS; do
  name="${job%%:*}"
  paths_csv="${job#*:}"
  # shellcheck disable=SC2206
  paths_args=(${paths_csv//,/ })

  if [[ -z "$name" || -z "$paths_csv" || "$name" == "$paths_csv" ]]; then
    echo "  Skipping malformed JOB entry: ${job}" >&2
    continue
  fi

  # Validate that paths actually exist — restic will error otherwise, and a
  # silent miss in cron is exactly the kind of thing that turns "we have backups"
  # into "we thought we had backups."
  for p in "${paths_args[@]}"; do
    [[ -e "$p" ]] || { echo "  ERROR: job '${name}' references missing path: $p" >&2; exit 1; }
  done

  printf -v stagger '%02d' "$((i * 10))"
  unit="restic-${name}"

  cat > "/etc/systemd/system/${unit}.service" <<SVC
[Unit]
Description=restic backup: ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/repo.env
ExecStart=/usr/bin/restic backup --tag ${name} --host ${RESTIC_HOST_PREFIX} ${paths_args[*]}
ExecStart=/usr/bin/restic forget --tag ${name} --host ${RESTIC_HOST_PREFIX} \\
  --keep-daily ${RESTIC_KEEP_DAILY} \\
  --keep-weekly ${RESTIC_KEEP_WEEKLY} \\
  --keep-monthly ${RESTIC_KEEP_MONTHLY} \\
  --prune
# Don't let backups starve the host of IO.
IOSchedulingClass=best-effort
IOSchedulingPriority=7
Nice=10
SVC

  cat > "/etc/systemd/system/${unit}.timer" <<TMR
[Unit]
Description=Daily restic backup: ${name}

[Timer]
OnCalendar=*-*-* 02:${stagger}:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
TMR

  installed_timers+=("${unit}.timer")
  echo "  ✓ ${unit}  (paths: ${paths_args[*]})"
  i=$((i + 1))
done

systemctl daemon-reload
for t in "${installed_timers[@]}"; do
  systemctl enable --now "$t"
done

# ---------------------------------------------------------------------------
# Initial run — sync first job (validates creds, fails loudly if wrong),
# async the rest (so a big initial backup like werify uploads doesn't make
# install.sh appear to hang for 30+ minutes).
# ---------------------------------------------------------------------------
first_job=""
async_units=()
for job in $JOBS; do
  name="${job%%:*}"
  if [[ -z "$first_job" ]]; then
    first_job="$name"
  else
    async_units+=("restic-${name}.service")
  fi
done

if [[ -n "$first_job" ]]; then
  echo ""
  echo "==> Running first job synchronously (validates creds): ${first_job}"
  systemctl start "restic-${first_job}.service"
  echo "  ✓ initial run complete"

  if [[ ${#async_units[@]} -gt 0 ]]; then
    echo ""
    echo "==> Kicking remaining ${#async_units[@]} job(s) in background..."
    systemctl start --no-block "${async_units[@]}"
    echo "  Tail any of them with:  journalctl -u <unit> -f"
  fi
fi

echo ""
echo "✓ restic configured."
echo "  Repo     : ${RESTIC_REPOSITORY}"
echo "  Snapshots: restic --json snapshots | jq ."
echo "  Restore  : restic restore <snapshot-id> --target /tmp/restore"
echo "  Run now  : systemctl start restic-<jobname>.service"
