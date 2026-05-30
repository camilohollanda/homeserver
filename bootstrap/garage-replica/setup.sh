#!/usr/bin/env bash
# Sets up daily replication of every Garage bucket on the services VM into a
# remote S3 bucket (Cloudflare R2 by default). Runs from your local machine.
#
# Usage:
#   ./bootstrap/garage-replica/setup.sh
#
# Required env vars:
#   GARAGE_ACCESS_KEY_ID      - Read-only Garage key. Create with:
#                                 ssh deployer@192.168.20.22 \
#                                   sudo docker exec garage /garage key create replica-ro
#                               then grant read on each bucket you want mirrored
#                               (Garage has no wildcard — per-bucket grants only):
#                                 ssh deployer@192.168.20.22 '
#                                   for b in iddh-members iddh-members-staging iddh-members-prod ; do \
#                                     sudo docker exec garage /garage bucket allow \
#                                       --read --key replica-ro "$b"
#                                   done'
#                               Skip ephemeral buckets like gha-cache. Re-run
#                               the grant for any new bucket you want replicated.
#   GARAGE_SECRET_ACCESS_KEY  - Secret printed by `key create`
#   DEST_ACCESS_KEY_ID        - R2/B2 access key (only needs write to DEST_BUCKET)
#   DEST_SECRET_ACCESS_KEY    - R2/B2 secret
#   DEST_BUCKET               - Destination bucket (create it first in CF/B2 UI)
#
# Optional env vars (defaults assume R2):
#   DEST_ENDPOINT             - default: https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
#                               To use B2: https://s3.<region>.backblazeb2.com
#   R2_ACCOUNT_ID             - Required only when using R2 default endpoint
#   DEST_REGION               - default: auto (R2). B2: us-west-002 etc.
#   GARAGE_S3_REGION          - default: garage
#   GARAGE_REPLICA_SSH        - default: deployer@192.168.20.22
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

GARAGE_REPLICA_SSH="${GARAGE_REPLICA_SSH:-deployer@192.168.20.22}"
export GARAGE_S3_REGION="${GARAGE_S3_REGION:-garage}"
export DEST_REGION="${DEST_REGION:-auto}"

if [[ -z "${DEST_ENDPOINT:-}" ]]; then
  if [[ -n "${R2_ACCOUNT_ID:-}" ]]; then
    export DEST_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  else
    echo "Error: set DEST_ENDPOINT, or set R2_ACCOUNT_ID to auto-derive the R2 endpoint." >&2
    exit 1
  fi
fi
export DEST_ENDPOINT

check_env GARAGE_ACCESS_KEY_ID GARAGE_SECRET_ACCESS_KEY \
          DEST_ACCESS_KEY_ID DEST_SECRET_ACCESS_KEY DEST_BUCKET

echo "=============================================="
echo "  Garage Replica Setup"
echo "  Target:        ${GARAGE_REPLICA_SSH}"
echo "  Source:        Garage on 127.0.0.1:3900 (region ${GARAGE_S3_REGION})"
echo "  Destination:   ${DEST_ENDPOINT} / ${DEST_BUCKET}"
echo "=============================================="
echo ""

wait_ssh "$GARAGE_REPLICA_SSH"

echo "==> Running garage-replica install on VM..."
REMOTE_HOST="$GARAGE_REPLICA_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Garage replica setup complete!"
echo "=============================================="
echo ""
echo "  Manual replication run:"
echo "    ssh ${GARAGE_REPLICA_SSH} sudo systemctl start garage-replica.service"
echo "    ssh ${GARAGE_REPLICA_SSH} journalctl -u garage-replica.service -f"
echo ""
echo "  Store secrets in Infisical (project homeserver, path /backups/garage-replica/):"
echo "    GARAGE_ACCESS_KEY_ID=${GARAGE_ACCESS_KEY_ID}"
echo "    GARAGE_SECRET_ACCESS_KEY=${GARAGE_SECRET_ACCESS_KEY}"
echo "    DEST_ACCESS_KEY_ID=${DEST_ACCESS_KEY_ID}"
echo "    DEST_SECRET_ACCESS_KEY=${DEST_SECRET_ACCESS_KEY}"
echo "    DEST_ENDPOINT=${DEST_ENDPOINT}"
echo "    DEST_BUCKET=${DEST_BUCKET}"
echo ""
echo "  Overwrites/deletes in Garage land under _trash/<bucket>/<YYYYMMDD>/ in"
echo "  the destination, so accidental deletes have a recovery window. Trim that"
echo "  prefix periodically (or use R2/B2 lifecycle rules) once you've decided"
echo "  on a retention policy."
echo ""
