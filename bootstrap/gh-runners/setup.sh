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
#   GH_ORGS                    - Comma-separated org list, each entry `org` or
#                                `org:count`, e.g. "iddh-com-br:2,prem-prakash:12".
#                                A bare org falls back to RUNNERS_PER_ORG.
#
# The App must be installed on every org in GH_ORGS with the org-level
# "Self-hosted runners: Read & write" permission. Per-org installation IDs
# are auto-discovered at runtime — no GH_APP_INSTALLATION_ID needed even if
# you list multiple orgs.
#
# Optional env vars:
#   GH_RUNNERS_SSH             - default: deployer@192.168.20.50
#   RUNNERS_PER_ORG            - default: 4. Only applies to orgs listed without
#                                a `:count` — prefer per-org counts in GH_ORGS.
#   RUNNER_VERSION             - default: 2.336.0 (GitHub hard-blocks deprecated
#                                runner versions — see install.sh)
#   RUNNER_LABELS              - default: "self-hosted,linux,homeserver"
#   RUNNER_ERL_FLAGS           - default: "+S 4:4". Caps the BEAM scheduler pool
#                                for every job so one `mix test` can't take the
#                                whole box. Set empty to leave the BEAM alone.
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
export RUNNER_VERSION="${RUNNER_VERSION:-2.336.0}"
export RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,homeserver}"
# Unset-only default (`-`, not `:-`) so an explicit empty value survives as the
# "leave the BEAM alone" opt-out — see install.sh.
export RUNNER_ERL_FLAGS="${RUNNER_ERL_FLAGS-+S 4:4}"
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
echo "  Default per org:  ${RUNNERS_PER_ORG}  (entries with :count override it)"
echo "  Runner version:   ${RUNNER_VERSION}"
echo "  Labels:           ${RUNNER_LABELS}"
echo "  ERL_FLAGS:        ${RUNNER_ERL_FLAGS:-(unset — BEAM unconstrained)}"
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
