#!/usr/bin/env bash
# Provisions restic on a target VM (defaults to the services VM, vmid 114).
# Runs from your local machine — SSHes into the VM.
#
# Usage:
#   # Default: back up the data dirs on the services VM
#   ./bootstrap/restic/setup.sh
#
#   # Back up a different VM with a different job set
#   RESTIC_SSH=deployer@192.168.20.40 \
#   JOBS="media-cfg:/opt/jellyfin/config,/opt/sonarr/config" \
#     ./bootstrap/restic/setup.sh
#
# Required env vars:
#   S3_ACCESS_KEY_ID      - Bucket access key (R2 API token ID, or B2 keyID)
#   S3_SECRET_ACCESS_KEY  - Bucket secret
#   S3_BUCKET             - Bucket name (create it in the CF/B2 console first)
#
# Optional env vars (defaults assume R2):
#   S3_ENDPOINT           - default: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
#                           To use B2: https://s3.<region>.backblazeb2.com
#   R2_ACCOUNT_ID         - Required only when using R2 default endpoint above
#
# Auto-generated if unset:
#   RESTIC_PASSWORD       - 32-char random; LOSING THIS LOSES THE BACKUPS
#
# Optional knobs:
#   RESTIC_SSH            - default: deployer@192.168.20.22 (services VM)
#   JOBS                  - default: services-data:/opt/garage/meta,/opt/mailpit/data,/opt/infisical/data
#   RESTIC_HOST_PREFIX    - default: derived on the VM from `hostname -s`
#   RESTIC_KEEP_DAILY     - default: 7
#   RESTIC_KEEP_WEEKLY    - default: 4
#   RESTIC_KEEP_MONTHLY   - default: 6
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_env() {
  local missing=()
  for var in "$@"; do [[ -z "${!var:-}" ]] && missing+=("$var"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: missing required environment variables: ${missing[*]}"; exit 1
  fi
}
wait_ssh() {
  local host="$1" timeout="${2:-120}" elapsed=0
  echo "Waiting for SSH on ${host}..."
  while ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" true 2>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then echo "Error: SSH not available on ${host} after ${timeout}s"; exit 1; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "✓ SSH ready"
}

RESTIC_SSH="${RESTIC_SSH:-deployer@192.168.20.22}"
export JOBS="${JOBS:-services-data:/opt/garage/meta,/opt/mailpit/data,/opt/infisical/data}"
export RESTIC_HOST_PREFIX="${RESTIC_HOST_PREFIX:-}"
export RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-7}"
export RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-4}"
export RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-6}"

if [[ -z "${S3_ENDPOINT:-}" ]]; then
  if [[ -n "${R2_ACCOUNT_ID:-}" ]]; then
    export S3_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  else
    echo "Error: set S3_ENDPOINT, or set R2_ACCOUNT_ID to auto-derive the R2 endpoint." >&2
    exit 1
  fi
fi
export S3_ENDPOINT

export RESTIC_PASSWORD="${RESTIC_PASSWORD:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"

check_env S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET

echo "=============================================="
echo "  restic Setup"
echo "  Target:   ${RESTIC_SSH}"
echo "  Bucket:   s3://${S3_BUCKET}/  (per-host prefix added on the VM)"
echo "  Endpoint: ${S3_ENDPOINT}"
echo "  Jobs:     ${JOBS}"
echo "=============================================="
echo ""

wait_ssh "$RESTIC_SSH"

echo "==> Running restic install on VM..."
REMOTE_HOST="$RESTIC_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  restic setup complete!"
echo "=============================================="
echo ""
echo "  Verify:"
echo "    ssh ${RESTIC_SSH} 'sudo bash -c \"set -a; . /etc/restic/repo.env; restic snapshots\"'"
echo ""
echo "  Store secrets in Infisical (project homeserver, path /backups/restic/):"
echo "    RESTIC_PASSWORD=${RESTIC_PASSWORD}"
echo "    S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}"
echo "    S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}"
echo "    S3_ENDPOINT=${S3_ENDPOINT}"
echo "    S3_BUCKET=${S3_BUCKET}"
echo ""
echo "  ⚠️  RESTIC_PASSWORD encrypts the repo. Lose it = lose the backups."
echo "      Store it in Infisical NOW before closing this terminal."
echo ""
echo "  Reuse this same password+bucket when running setup.sh against other VMs."
echo "  Each VM writes to its own prefix in the bucket, so they don't collide."
echo ""
