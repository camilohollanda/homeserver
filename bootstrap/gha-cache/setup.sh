#!/usr/bin/env bash
# Provisions the self-hosted GitHub Actions cache server on the services VM
# (vmid 114, IP .22). Runs from your local machine — SSHes into the VM for all
# remote operations.
#
# Usage:
#   ./bootstrap/gha-cache/setup.sh
#
# Required env vars:
#   CF_API_TOKEN           - Cloudflare API token (used on the VM by certbot for the
#                            DNS-01 challenge; no DNS records are created by this script —
#                            A records are managed in terraform/cloudflare-dns.tf)
#   LETSENCRYPT_EMAIL      - Email for Let's Encrypt notifications
#
# Optional env vars (auto-generated/discovered if unset):
#   GHA_CACHE_S3_BUCKET    - Garage bucket name (default: gha-cache)
#   GHA_CACHE_S3_KEY_NAME  - Garage key name (default: gha-cache-key)
#   GHA_CACHE_S3_KEY_ID    - looked up from Garage if not set
#   GHA_CACHE_S3_SECRET    - looked up from Garage if not set
#   GHA_CACHE_MGMT_API_KEY - generated random 32-char if unset
#
# Optional knobs:
#   GHA_CACHE_DOMAIN       - default: gha-cache.internal.prakash.com.br
#   GHA_CACHE_SSH          - default: deployer@192.168.20.22
#   GHA_CACHE_VERSION      - default: 9.4.7
#   GHA_CACHE_PORT         - default: 3000 (loopback, fronted by shared nginx)
#   GHA_CACHE_S3_ENDPOINT  - default: https://garage.internal.prakash.com.br
#   GHA_CACHE_S3_REGION    - default: garage
#   GHA_CACHE_CLEANUP_DAYS - default: 14
#   SKIP_GARAGE=1          - Skip auto-provisioning the Garage bucket+key
#                            (use when bringing your own S3 backend)
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
GHA_CACHE_SSH="${GHA_CACHE_SSH:-deployer@192.168.20.22}"
export GHA_CACHE_DOMAIN="${GHA_CACHE_DOMAIN:-gha-cache.internal.prakash.com.br}"
export GHA_CACHE_VERSION="${GHA_CACHE_VERSION:-9.4.7}"
export GHA_CACHE_PORT="${GHA_CACHE_PORT:-3000}"
export GHA_CACHE_S3_ENDPOINT="${GHA_CACHE_S3_ENDPOINT:-https://garage.internal.prakash.com.br}"
export GHA_CACHE_S3_REGION="${GHA_CACHE_S3_REGION:-garage}"
export GHA_CACHE_S3_BUCKET="${GHA_CACHE_S3_BUCKET:-gha-cache}"
export GHA_CACHE_CLEANUP_DAYS="${GHA_CACHE_CLEANUP_DAYS:-14}"
export GHA_CACHE_MGMT_API_KEY="${GHA_CACHE_MGMT_API_KEY:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"
GHA_CACHE_S3_KEY_NAME="${GHA_CACHE_S3_KEY_NAME:-gha-cache-key}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  GHA Cache Server Setup"
echo "  Target:   ${GHA_CACHE_SSH}"
echo "  Domain:   ${GHA_CACHE_DOMAIN}"
echo "  Version:  ${GHA_CACHE_VERSION}"
echo "  Storage:  s3://${GHA_CACHE_S3_BUCKET} @ ${GHA_CACHE_S3_ENDPOINT}"
echo "=============================================="
echo ""

wait_ssh "$GHA_CACHE_SSH"

# DNS for ${GHA_CACHE_DOMAIN} is managed by terraform/cloudflare-dns.tf
# (resource cloudflare_dns_record.internal_a["gha_cache"]).

# ---------------------------------------------------------------------------
# Provision Garage bucket + key (idempotent). Reuses an existing key with the
# same name so re-runs don't rotate credentials out from under the cache
# server. Set SKIP_GARAGE=1 to bring your own S3 backend.
# ---------------------------------------------------------------------------
if [[ "${SKIP_GARAGE:-0}" != "1" && ( -z "${GHA_CACHE_S3_KEY_ID:-}" || -z "${GHA_CACHE_S3_SECRET:-}" ) ]]; then
  echo ""
  echo "==> Provisioning Garage bucket + key..."
  if ! ssh "$GHA_CACHE_SSH" "sudo docker ps --format '{{.Names}}'" | grep -qx garage; then
    echo "Error: 'garage' container not running on $GHA_CACHE_SSH." >&2
    echo "  Either run bootstrap/garage/setup.sh first, or pass GHA_CACHE_S3_KEY_ID +" >&2
    echo "  GHA_CACHE_S3_SECRET (and SKIP_GARAGE=1) to bring your own S3 backend." >&2
    exit 1
  fi

  GARAGE_EXEC="sudo docker exec garage /garage"

  # Bucket: create if missing. Garage exits non-zero on "already exists",
  # so we check first rather than swallowing.
  if ssh "$GHA_CACHE_SSH" "$GARAGE_EXEC bucket list" 2>/dev/null \
       | awk '{print $1}' | grep -qx "$GHA_CACHE_S3_BUCKET"; then
    echo "  Bucket '${GHA_CACHE_S3_BUCKET}' already exists."
  else
    echo "  Creating bucket '${GHA_CACHE_S3_BUCKET}'..."
    ssh "$GHA_CACHE_SSH" "$GARAGE_EXEC bucket create $GHA_CACHE_S3_BUCKET" >/dev/null
  fi

  # Key: reuse if present, otherwise create. `key info --show-secret` works
  # for re-runs; `key create` is what we parse on first run.
  if ssh "$GHA_CACHE_SSH" "$GARAGE_EXEC key list" 2>/dev/null \
       | grep -qE "\\b${GHA_CACHE_S3_KEY_NAME}\\b"; then
    echo "  Key '${GHA_CACHE_S3_KEY_NAME}' already exists — reading credentials."
    KEY_INFO="$(ssh "$GHA_CACHE_SSH" "$GARAGE_EXEC key info --show-secret $GHA_CACHE_S3_KEY_NAME")"
  else
    echo "  Creating key '${GHA_CACHE_S3_KEY_NAME}'..."
    KEY_INFO="$(ssh "$GHA_CACHE_SSH" "$GARAGE_EXEC key create $GHA_CACHE_S3_KEY_NAME")"
  fi

  GHA_CACHE_S3_KEY_ID="$(echo "$KEY_INFO" | awk -F': *' '/^Key ID:/    {print $2; exit}')"
  GHA_CACHE_S3_SECRET="$(echo "$KEY_INFO" | awk -F': *' '/^Secret key:/ {print $2; exit}')"

  if [[ -z "$GHA_CACHE_S3_KEY_ID" || -z "$GHA_CACHE_S3_SECRET" ]]; then
    echo "Error: failed to parse Garage key credentials from:" >&2
    echo "$KEY_INFO" >&2
    exit 1
  fi

  # Grant the key R/W + ownership on the bucket. Garage treats this as
  # idempotent (no-op if the permission is already in place).
  echo "  Granting r/w on '${GHA_CACHE_S3_BUCKET}' to '${GHA_CACHE_S3_KEY_NAME}'..."
  ssh "$GHA_CACHE_SSH" "$GARAGE_EXEC bucket allow --read --write --owner $GHA_CACHE_S3_BUCKET --key $GHA_CACHE_S3_KEY_NAME" >/dev/null

  export GHA_CACHE_S3_KEY_ID GHA_CACHE_S3_SECRET
fi

check_env GHA_CACHE_S3_KEY_ID GHA_CACHE_S3_SECRET

echo ""
echo "==> Running gha-cache install on VM..."
REMOTE_HOST="$GHA_CACHE_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  gha-cache setup complete!"
echo "=============================================="
echo ""
echo "  URL:               https://${GHA_CACHE_DOMAIN}/"
echo "  Storage:           s3://${GHA_CACHE_S3_BUCKET} @ ${GHA_CACHE_S3_ENDPOINT}"
echo "  Retention:         ${GHA_CACHE_CLEANUP_DAYS} days"
echo "  Management API:    https://${GHA_CACHE_DOMAIN}/management-api/_docs"
echo ""
echo "  Next: re-run bootstrap/gh-runners/setup.sh with"
echo "    ACTIONS_RESULTS_URL=https://${GHA_CACHE_DOMAIN}/"
echo "  so each runner instance is patched + pointed at this cache server."
echo ""
echo "  Store these in Infisical (project homeserver, path /gha-cache/):"
echo "    GHA_CACHE_S3_KEY_ID    = ${GHA_CACHE_S3_KEY_ID}"
echo "    GHA_CACHE_S3_SECRET    = ${GHA_CACHE_S3_SECRET}"
echo "    GHA_CACHE_MGMT_API_KEY = ${GHA_CACHE_MGMT_API_KEY}"
echo ""
