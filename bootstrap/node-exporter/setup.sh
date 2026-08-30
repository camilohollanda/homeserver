#!/usr/bin/env bash
# Provisions node_exporter on every homeserver host, including the hypervisor.
#
# Usage:
#   ./bootstrap/node-exporter/setup.sh
#
# Required env vars: (none)
#
# Optional knobs:
#   NODE_EXPORTER_TARGETS - space-separated ssh targets (default: all seven)
#   NODE_EXPORTER_PORT    - listen port (default: 9100)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

wait_ssh() {
  local host="$1" timeout="${2:-120}" elapsed=0
  echo "Waiting for SSH on ${host}..."
  while ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" true 2>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then echo "Error: SSH not available on ${host} after ${timeout}s"; exit 1; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "✓ SSH ready"
}

# The hypervisor logs in as root, the VMs as deployer.
NODE_EXPORTER_TARGETS="${NODE_EXPORTER_TARGETS:-\
root@192.168.20.10 \
deployer@192.168.20.11 \
deployer@192.168.20.22 \
deployer@192.168.20.23 \
deployer@192.168.20.30 \
deployer@192.168.20.40 \
deployer@192.168.20.50}"

export NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
# Read once here so every target gets the same collector without install.sh
# having to find it on the far side of the pipe.
export LVM_COLLECTOR_SRC="$(cat "${SCRIPT_DIR}/lvm-thinpool-metrics.sh")"

echo "=============================================="
echo "  node_exporter Setup"
echo "  Port:    ${NODE_EXPORTER_PORT}"
echo "  Targets: ${NODE_EXPORTER_TARGETS}"
echo "=============================================="

failed=()
for target in $NODE_EXPORTER_TARGETS; do
  echo ""
  echo "---- ${target} ----"
  wait_ssh "$target"
  # Deliberately not aborting the loop: one unreachable host must not stop the
  # other six from being provisioned. The exit code below preserves the failure.
  if REMOTE_HOST="$target" bash "${SCRIPT_DIR}/install.sh"; then
    echo "✓ ${target}"
  else
    echo "✗ ${target}"
    failed+=("$target")
  fi
done

echo ""
echo "=============================================="
if [[ ${#failed[@]} -eq 0 ]]; then
  echo "  node_exporter setup complete on all hosts"
else
  echo "  FAILED on: ${failed[*]}"
fi
echo "=============================================="
echo ""
echo "  Scrape targets are declared in"
echo "    gitops/victoria-metrics/scrape-config.yaml"
echo "  Nothing to store in Infisical -- this stack has no secrets."
echo ""
[[ ${#failed[@]} -eq 0 ]]
