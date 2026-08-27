#!/usr/bin/env bash
# Provisions wal-g on a postgres VM. Defaults to the PG 18 box (vmid 118, .23),
# which is now the only one — VM 113 (.21, PG 17) was decommissioned 2026-08-27.
# Still parameterised rather than hardcoded: install.sh restarts the cluster, so
# pointing it at a live database is destructive and should stay a deliberate act.
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   WALG_PREFIX=wal-g-18 ./bootstrap/wal-g/setup.sh
#
# Required env vars:
#   S3_ACCESS_KEY_ID      - Bucket access key (R2 API token ID, or B2 keyID)
#   S3_SECRET_ACCESS_KEY  - Bucket secret
#   S3_BUCKET             - Bucket name (create it in the CF/B2 console first)
#
# Optional env vars (defaults assume R2):
#   S3_ENDPOINT           - default: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
#                           To use B2: https://s3.<region>.backblazeb2.com
#   S3_REGION             - default: auto (R2). For B2 set to e.g. us-west-002.
#   R2_ACCOUNT_ID         - Required only when using R2 default endpoint above
#
# Auto-generated if unset:
#   WALG_LIBSODIUM_KEY    - 32-byte hex; LOSING THIS LOSES THE BACKUPS
#
# Optional knobs:
#   WALG_SSH              - default: deployer@192.168.20.23
#   PG_VERSION            - default: 18
#   WALG_VERSION          - default: 3.0.8
#   WALG_RETAIN_FULL      - default: 7
#   WALG_PREFIX           - path inside the bucket (default: wal-g).
#                           Use a fresh prefix for a new cluster — see install.sh.
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

WALG_SSH="${WALG_SSH:-deployer@192.168.20.23}"
export PG_VERSION="${PG_VERSION:-18}"
export WALG_VERSION="${WALG_VERSION:-3.0.8}"
export WALG_RETAIN_FULL="${WALG_RETAIN_FULL:-7}"
export S3_REGION="${S3_REGION:-auto}"
export WALG_PREFIX="${WALG_PREFIX:-wal-g}"

# Resolve the endpoint: explicit S3_ENDPOINT wins, else derive from R2_ACCOUNT_ID.
if [[ -z "${S3_ENDPOINT:-}" ]]; then
  if [[ -n "${R2_ACCOUNT_ID:-}" ]]; then
    export S3_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  else
    echo "Error: set S3_ENDPOINT, or set R2_ACCOUNT_ID to auto-derive the R2 endpoint." >&2
    exit 1
  fi
fi
export S3_ENDPOINT

export WALG_LIBSODIUM_KEY="${WALG_LIBSODIUM_KEY:-$(openssl rand -hex 32)}"

check_env S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET

echo "=============================================="
echo "  wal-g Setup (PostgreSQL PITR)"
echo "  Target:   ${WALG_SSH}"
echo "  PG ver:   ${PG_VERSION}"
echo "  wal-g:    v${WALG_VERSION}"
echo "  Bucket:   s3://${S3_BUCKET}/${WALG_PREFIX}"
echo "  Endpoint: ${S3_ENDPOINT}"
echo "  Region:   ${S3_REGION}"
echo "=============================================="
echo ""

wait_ssh "$WALG_SSH"

echo "==> Running wal-g install on VM..."
REMOTE_HOST="$WALG_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  wal-g setup complete!"
echo "=============================================="
echo ""
echo "  Verify:"
echo "    ssh ${WALG_SSH} sudo -u postgres bash -lc \\"
echo "      \"set -a; . /etc/wal-g/wal-g.env; wal-g backup-list\""
echo ""
echo "  Store secrets in Infisical (project homeserver, path /backups/wal-g/):"
echo "    WALG_LIBSODIUM_KEY=${WALG_LIBSODIUM_KEY}"
echo "    S3_ACCESS_KEY_ID=${S3_ACCESS_KEY_ID}"
echo "    S3_SECRET_ACCESS_KEY=${S3_SECRET_ACCESS_KEY}"
echo "    S3_ENDPOINT=${S3_ENDPOINT}"
echo "    S3_BUCKET=${S3_BUCKET}"
echo ""
echo "  ⚠️  WALG_LIBSODIUM_KEY encrypts the backups. Lose it = lose the ability"
echo "      to restore. Store it in Infisical NOW before closing this terminal."
echo ""
