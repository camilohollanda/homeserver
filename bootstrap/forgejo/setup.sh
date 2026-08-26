#!/usr/bin/env bash
# Provisions Forgejo on VM 119 (IP .24).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# Usage:
#   ./bootstrap/forgejo/setup.sh
#
# Required env vars:
#   CF_API_TOKEN         - Cloudflare API token (used on the VM by certbot for the
#                          DNS-01 challenge; no DNS records are created by this script —
#                          A records are managed in terraform/cloudflare-dns.tf)
#   LETSENCRYPT_EMAIL    - Email for Let's Encrypt notifications
#
# Optional env vars (auto-generated if unset):
#   FORGEJO_ADMIN_USER   - default: camilo
#   FORGEJO_ADMIN_PASS   - generated random 32-char if unset
#   FORGEJO_ADMIN_EMAIL  - defaults to LETSENCRYPT_EMAIL
#
# Optional knobs:
#   FORGEJO_DOMAIN       - default: forgejo.internal.prakash.com.br
#   FORGEJO_SSH          - default: deployer@192.168.20.24
#   FORGEJO_VERSION      - default: 16.0.3
#   FORGEJO_SSH_PORT     - default: 2222
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

check_env CF_API_TOKEN LETSENCRYPT_EMAIL

FORGEJO_SSH="${FORGEJO_SSH:-deployer@192.168.20.24}"
export FORGEJO_DOMAIN="${FORGEJO_DOMAIN:-forgejo.internal.prakash.com.br}"
export FORGEJO_VERSION="${FORGEJO_VERSION:-16.0.3}"
export FORGEJO_SSH_PORT="${FORGEJO_SSH_PORT:-2222}"
export FORGEJO_ADMIN_USER="${FORGEJO_ADMIN_USER:-camilo}"
export FORGEJO_ADMIN_EMAIL="${FORGEJO_ADMIN_EMAIL:-${LETSENCRYPT_EMAIL}}"
export FORGEJO_ADMIN_PASS="${FORGEJO_ADMIN_PASS:-$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)}"

echo "=============================================="
echo "  Forgejo Setup"
echo "  Target:   ${FORGEJO_SSH}"
echo "  Domain:   ${FORGEJO_DOMAIN}"
echo "  Version:  ${FORGEJO_VERSION}"
echo "=============================================="
echo ""

wait_ssh "$FORGEJO_SSH"

# DNS for ${FORGEJO_DOMAIN} is managed by terraform/cloudflare-dns.tf
# (resource cloudflare_dns_record.internal_a["forgejo"]).

echo "==> Running Forgejo install on VM..."
REMOTE_HOST="$FORGEJO_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Forgejo setup complete!"
echo "=============================================="
echo ""
echo "  Web UI:   https://${FORGEJO_DOMAIN}"
echo "    user:   ${FORGEJO_ADMIN_USER}"
echo "    pass:   ${FORGEJO_ADMIN_PASS}"
echo ""
echo "  Git/SSH:  ssh://git@${FORGEJO_DOMAIN}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git"
echo "  Registry: ${FORGEJO_DOMAIN}/<owner>/<image>"
echo ""
echo "  Store in Infisical (project homeserver, path /Forgejo/):"
echo "    FORGEJO_ADMIN_USER=${FORGEJO_ADMIN_USER}"
echo "    FORGEJO_ADMIN_PASS=${FORGEJO_ADMIN_PASS}"
echo ""
echo "  These can only be minted from the UI after first boot — create them"
echo "  now and store them under /Forgejo/ as well:"
echo "    FORGEJO_RUNNER_TOKEN     Site Admin → Actions → Runners → registration token"
echo "                             (needed by bootstrap/forgejo-runner/setup.sh)"
echo "    FORGEJO_ARGO_USER        read-only user for Argo CD"
echo "    FORGEJO_ARGO_TOKEN       its access token"
echo "    FORGEJO_REGISTRY_USER    registry pull user for k3s"
echo "    FORGEJO_REGISTRY_TOKEN   its access token"
echo ""
echo "  The sync timer reads its own credentials from /etc/forgejo-sync/env on"
echo "  the VM (created empty by install.sh). Fill it in, then start the unit:"
echo "    GITHUB_SYNC_PAT=<GitHub PAT, repo:read>"
echo "    FORGEJO_SYNC_USER=<Forgejo automation/admin user>"
echo "    FORGEJO_SYNC_TOKEN=<token allowed to create orgs/repos and push>"
echo "    ssh ${FORGEJO_SSH} 'sudo systemctl start forgejo-sync.service && sudo systemctl start forgejo-sync.timer'"
echo ""
echo "  Then register the runner and configure encrypted backups:"
echo "    FORGEJO_RUNNER_TOKEN=... ./bootstrap/forgejo-runner/setup.sh"
echo "    ./bootstrap/restic/configure.sh forgejo"
echo ""
echo "  Full rollout and cutover runbook: bootstrap/forgejo/README.md"
echo ""
