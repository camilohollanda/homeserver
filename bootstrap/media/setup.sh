#!/usr/bin/env bash
# Provisions the media VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/media/setup.sh
#
# Required env vars:
#   CF_API_TOKEN          - Cloudflare API token (Zone.DNS Edit) used on the VM
#                           by certbot for the DNS-01 challenge. A records for
#                           these domains are managed in terraform/cloudflare-dns.tf.
#   LETSENCRYPT_EMAIL     - Email for Let's Encrypt notifications
#
# Optional env vars:
#   MEDIA_SSH             - SSH target (default: deployer@192.168.20.40)
#   MEDIA_TIMEZONE        - Timezone (default: America/Sao_Paulo)
#   MEDIA_UID             - UID for media processes (default: 1000)
#   MEDIA_GID             - GID for media processes (default: 1000)
#   MEDIA_LIBRARY_PATH    - Path to media library (default: /srv/media)
#   MEDIA_DOWNLOAD_PATH   - Path for downloads (default: /srv/downloads)
#   DOMAIN_JELLYFIN       - default: jellyfin.internal.prakash.com.br
#   DOMAIN_QBITTORRENT    - default: torrent.internal.prakash.com.br
#   DOMAIN_RADARR         - default: radarr.internal.prakash.com.br
#   DOMAIN_SONARR         - default: sonarr.internal.prakash.com.br
#   DOMAIN_PROWLARR       - default: prowlarr.internal.prakash.com.br
#   DOMAIN_BAZARR         - default: bazarr.internal.prakash.com.br
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

MEDIA_SSH="${MEDIA_SSH:-deployer@192.168.20.40}"

# Domains default to the internal A records in terraform/cloudflare-dns.tf.
export DOMAIN_JELLYFIN="${DOMAIN_JELLYFIN:-jellyfin.internal.prakash.com.br}"
export DOMAIN_QBITTORRENT="${DOMAIN_QBITTORRENT:-torrent.internal.prakash.com.br}"
export DOMAIN_RADARR="${DOMAIN_RADARR:-radarr.internal.prakash.com.br}"
export DOMAIN_SONARR="${DOMAIN_SONARR:-sonarr.internal.prakash.com.br}"
export DOMAIN_PROWLARR="${DOMAIN_PROWLARR:-prowlarr.internal.prakash.com.br}"
export DOMAIN_BAZARR="${DOMAIN_BAZARR:-bazarr.internal.prakash.com.br}"

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

echo "=============================================="
echo "  Media Server Setup"
echo "  Target: ${MEDIA_SSH}"
echo "=============================================="
echo ""

wait_ssh "$MEDIA_SSH"

REMOTE_HOST="$MEDIA_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Media server setup complete!"
echo "=============================================="
echo ""
