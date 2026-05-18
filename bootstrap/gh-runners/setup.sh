#!/usr/bin/env bash
# Provisions GitHub Actions self-hosted runners on the gh-runners VM
# (vmid 117, IP .50). Runs from your local machine — SSHes into the VM for
# all remote operations.
#
# Usage:
#   ./bootstrap/gh-runners/setup.sh
#
# Required env vars:
#   GH_APP_CLIENT_ID           - GitHub App Client ID (preferred) or numeric App ID
#   GH_APP_PRIVATE_KEY_FILE    - Path to the App's PEM private key on your laptop
#   GH_REPOS                   - Comma-separated owner/repo list
#                                e.g. "iddh-com-br/members,prem-prakash/werify"
#
# The App must be installed on every account/org that owns a repo in GH_REPOS,
# but the per-repo installation IDs are auto-discovered at runtime — no
# GH_APP_INSTALLATION_ID needed even if repos span multiple owners.
#
# Optional env vars:
#   GH_RUNNERS_SSH             - default: deployer@192.168.20.50
#   RUNNERS_PER_REPO           - default: 2
#   RUNNER_VERSION             - default: 2.328.0
#   RUNNER_LABELS              - default: "self-hosted,linux,homeserver"
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

GH_RUNNERS_SSH="${GH_RUNNERS_SSH:-deployer@192.168.20.50}"
export RUNNERS_PER_REPO="${RUNNERS_PER_REPO:-2}"
export RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
export RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,homeserver}"

check_env GH_APP_CLIENT_ID GH_APP_PRIVATE_KEY_FILE GH_REPOS

if [[ ! -r "$GH_APP_PRIVATE_KEY_FILE" ]]; then
  echo "Error: cannot read GH_APP_PRIVATE_KEY_FILE: $GH_APP_PRIVATE_KEY_FILE"
  exit 1
fi

# Forward the PEM contents via env to install.sh (preserved across `printf %q`).
export GH_APP_PRIVATE_KEY="$(cat "$GH_APP_PRIVATE_KEY_FILE")"

echo "=============================================="
echo "  GitHub Actions Runners Setup"
echo "  Target:           ${GH_RUNNERS_SSH}"
echo "  Repos:            ${GH_REPOS}"
echo "  Runners per repo: ${RUNNERS_PER_REPO}"
echo "  Runner version:   ${RUNNER_VERSION}"
echo "  Labels:           ${RUNNER_LABELS}"
echo "=============================================="
echo ""

wait_ssh "$GH_RUNNERS_SSH"

echo ""
echo "==> Running install on $GH_RUNNERS_SSH..."
REMOTE_HOST="$GH_RUNNERS_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  GitHub Actions runners setup complete!"
echo "=============================================="
echo ""
echo "  Each runner appears in its repo at:"
echo "    https://github.com/<owner>/<repo>/settings/actions/runners"
echo ""
echo "  Workflows must opt in with:"
echo "    runs-on: [self-hosted, linux, homeserver]"
echo ""
echo "  Store credentials in Infisical (project homeserver, path /github-runners/):"
echo "    GH_APP_CLIENT_ID         = ${GH_APP_CLIENT_ID}"
echo "    GH_APP_PRIVATE_KEY       = <contents of ${GH_APP_PRIVATE_KEY_FILE}>"
echo "    GH_REPOS                 = ${GH_REPOS}"
echo ""
echo "  GitHub App needs these repository permissions:"
echo "    - Administration:  Read & write   (runner registration)"
echo "    - Actions:         Read & write   (job dispatch)"
echo "    - Metadata:        Read           (default)"
echo "  And must be installed on every account/org that owns a repo in GH_REPOS."
echo "  Per-repo installation IDs are auto-discovered at runtime."
echo ""
