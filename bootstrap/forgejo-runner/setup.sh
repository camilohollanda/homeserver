#!/usr/bin/env bash
# Registers the Forgejo act_runner on the gh-runners VM (vmid 117, IP .50).
# Runs from your local machine — SSHes into the VM for all remote operations.
#
# The GitHub Actions runners on that VM are left running. install.sh counts the
# active gh-runner@* units before and after and fails if the number drops.
#
# Usage:
#   FORGEJO_RUNNER_TOKEN=... ./bootstrap/forgejo-runner/setup.sh
#
# Required env vars:
#   FORGEJO_RUNNER_TOKEN - Site Admin → Actions → Runners → "Create new runner"
#                          (stored in Infisical under /Forgejo/)
#
# Optional knobs:
#   FORGEJO_URL          - default: https://forgejo.internal.prakash.com.br
#   RUNNER_SSH           - default: deployer@192.168.20.50
#   RUNNER_NAME          - default: homeserver-117
#   RUNNER_CAPACITY      - default: 2
#   RUNNER_IMAGE_VERSION - default: 13.0.0
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

check_env FORGEJO_RUNNER_TOKEN

RUNNER_SSH="${RUNNER_SSH:-deployer@192.168.20.50}"
export FORGEJO_URL="${FORGEJO_URL:-https://forgejo.internal.prakash.com.br}"
export RUNNER_NAME="${RUNNER_NAME:-homeserver-117}"
export RUNNER_CAPACITY="${RUNNER_CAPACITY:-2}"
export RUNNER_IMAGE_VERSION="${RUNNER_IMAGE_VERSION:-13.0.0}"

echo "=============================================="
echo "  Forgejo runner registration"
echo "  Target:   ${RUNNER_SSH}  (vmid 117)"
echo "  Instance: ${FORGEJO_URL}"
echo "  Name:     ${RUNNER_NAME}"
echo "  Version:  ${RUNNER_IMAGE_VERSION}"
echo "=============================================="
echo ""

# Fail early rather than half-registering against an instance that isn't up.
if ! curl -sf -o /dev/null "${FORGEJO_URL%/}/api/v1/version"; then
  echo "Error: ${FORGEJO_URL} is not reachable. Run bootstrap/forgejo/setup.sh first."
  exit 1
fi

wait_ssh "$RUNNER_SSH"

echo "==> Registering the Forgejo runner on VM 117..."
REMOTE_HOST="$RUNNER_SSH" bash "${SCRIPT_DIR}/install.sh"

echo ""
echo "=============================================="
echo "  Done"
echo "=============================================="
echo ""
echo "  Confirm the runner is Idle:"
echo "    ${FORGEJO_URL%/}/-/admin/actions/runners"
echo ""
echo "  Confirm the GitHub runners are still up:"
echo "    ssh ${RUNNER_SSH} 'systemctl list-units \"gh-runner@*.service\" --state=active'"
echo ""
echo "  Forgejo workflows must select the registered execution label:"
echo "    runs-on: docker"
echo ""
