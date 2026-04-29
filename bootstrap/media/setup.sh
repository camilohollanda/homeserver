#!/usr/bin/env bash
# Provisions the media VM from the local machine.
# Runs as your local user — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/media/setup.sh
#
# Required env vars:
#   DOMAIN_JELLYFIN       - e.g. jellyfin.internal.prakash.com.br
#   DOMAIN_QBITTORRENT    - e.g. qbittorrent.internal.prakash.com.br
#   DOMAIN_RADARR         - e.g. radarr.internal.prakash.com.br
#   DOMAIN_SONARR         - e.g. sonarr.internal.prakash.com.br
#   DOMAIN_PROWLARR       - e.g. prowlarr.internal.prakash.com.br
#   DOMAIN_BAZARR         - e.g. bazarr.internal.prakash.com.br
#
# Optional env vars:
#   MEDIA_SSH             - SSH target (default: deployer@192.168.20.40)
#   MEDIA_TIMEZONE        - Timezone (default: America/Sao_Paulo)
#   MEDIA_UID             - UID for media processes (default: 1000)
#   MEDIA_GID             - GID for media processes (default: 1000)
#   MEDIA_LIBRARY_PATH    - Path to media library (default: /mnt/media)
#   MEDIA_DOWNLOAD_PATH   - Path for downloads (default: /mnt/downloads)
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

check_env DOMAIN_JELLYFIN DOMAIN_QBITTORRENT DOMAIN_RADARR \
          DOMAIN_SONARR DOMAIN_PROWLARR DOMAIN_BAZARR

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
