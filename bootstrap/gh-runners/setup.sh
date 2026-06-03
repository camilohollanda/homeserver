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
#   GH_ORGS                    - Comma-separated org list
#                                e.g. "iddh-com-br,prem-prakash"
#
# The App must be installed on every org in GH_ORGS with the org-level
# "Self-hosted runners: Read & write" permission. Per-org installation IDs
# are auto-discovered at runtime — no GH_APP_INSTALLATION_ID needed even if
# you list multiple orgs.
#
# Optional env vars:
#   GH_RUNNERS_SSH             - default: deployer@192.168.20.50
#   RUNNERS_PER_ORG            - default: 4
#   RUNNER_VERSION             - default: 2.328.0
#   RUNNER_LABELS              - default: "self-hosted,linux,homeserver"
#   ACTIONS_RESULTS_URL        - Self-hosted gha-cache URL (e.g.
#                                https://gha-cache.internal.prakash.com.br/).
#                                When set, install.sh patches each Runner.Worker.dll
#                                so the runner stops overwriting this value,
#                                and points all jobs at the self-hosted cache.
#                                Leave unset to keep using GitHub's cache.
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
export RUNNERS_PER_ORG="${RUNNERS_PER_ORG:-4}"
export RUNNER_VERSION="${RUNNER_VERSION:-2.334.0}"
export RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,homeserver}"
export ACTIONS_RESULTS_URL="${ACTIONS_RESULTS_URL:-}"

check_env GH_APP_CLIENT_ID GH_APP_PRIVATE_KEY_FILE GH_ORGS

if [[ ! -r "$GH_APP_PRIVATE_KEY_FILE" ]]; then
  echo "Error: cannot read GH_APP_PRIVATE_KEY_FILE: $GH_APP_PRIVATE_KEY_FILE"
  exit 1
fi

# Forward the PEM contents via env to install.sh (preserved across `printf %q`).
export GH_APP_PRIVATE_KEY="$(cat "$GH_APP_PRIVATE_KEY_FILE")"

echo "=============================================="
echo "  GitHub Actions Runners Setup"
echo "  Target:           ${GH_RUNNERS_SSH}"
echo "  Orgs:             ${GH_ORGS}"
echo "  Runners per org:  ${RUNNERS_PER_ORG}"
echo "  Runner version:   ${RUNNER_VERSION}"
echo "  Labels:           ${RUNNER_LABELS}"
if [[ -n "$ACTIONS_RESULTS_URL" ]]; then
  echo "  Cache server:     ${ACTIONS_RESULTS_URL}"
else
  echo "  Cache server:     (none — using GitHub-hosted cache)"
fi
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
echo "  Each runner appears in its org at:"
echo "    https://github.com/organizations/<org>/settings/actions/runners"
echo ""
echo "  Workflows must opt in with:"
echo "    runs-on: [self-hosted, linux, homeserver]"
echo ""
echo "  Store credentials in Infisical (project homeserver, path /github-runners/):"
echo "    GH_APP_CLIENT_ID         = ${GH_APP_CLIENT_ID}"
echo "    GH_APP_PRIVATE_KEY       = <contents of ${GH_APP_PRIVATE_KEY_FILE}>"
echo "    GH_ORGS                  = ${GH_ORGS}"
echo ""
echo "  GitHub App needs this organization permission:"
echo "    - Self-hosted runners:  Read & write   (org-scoped JIT registration)"
echo "    - Metadata:             Read           (default)"
echo "  And must be installed on every org in GH_ORGS."
echo "  Per-org installation IDs are auto-discovered at runtime."
echo ""
echo "  On the free plan there is only one runner group (Default). To stop"
echo "  arbitrary repos in each org from scheduling jobs on these runners,"
echo "  set Default → Repository access → Selected repositories in the org's"
echo "  Settings → Actions → Runner groups page."
echo ""
