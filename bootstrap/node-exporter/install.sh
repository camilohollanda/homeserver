#!/usr/bin/env bash
# Runs on any homeserver VM or on the Proxmox host, as root.
# Remote: REMOTE_HOST=deployer@192.168.20.11 ./install.sh
#
# Installs prometheus-node-exporter from Debian, binds it to the LAN address
# and trims the filesystem collector so container overlays don't inflate the
# series count. On a host that has LVM thin pools (the hypervisor) it also
# installs a textfile collector for them, because node_exporter has no LVM
# collector and a thin pool has no mounted filesystem to be seen through.
#
# Optional env vars:
#   NODE_EXPORTER_PORT - listen port (default: 9100)
#   LAN_PROBE_ADDR     - address used to derive the LAN IP (default: 192.168.20.1)
#   LVM_COLLECTOR_SRC  - source of lvm-thinpool-metrics.sh; defaults to the
#                        copy sitting next to this script
if [[ -n "${REMOTE_HOST:-}" ]]; then
  # The collector is forwarded as an env var rather than embedded in a heredoc
  # here, so it stays a single readable file in the repo with no second copy to
  # drift. $0 is a real path on this side of the pipe; on the far side it isn't.
  if [[ -z "${LVM_COLLECTOR_SRC:-}" ]]; then
    _collector="$(dirname "$0")/lvm-thinpool-metrics.sh"
    [[ -f "$_collector" ]] && LVM_COLLECTOR_SRC="$(cat "$_collector")"
  fi
  { printf 'export %s=%q\n' \
      NODE_EXPORTER_PORT "${NODE_EXPORTER_PORT:-}" \
      LAN_PROBE_ADDR     "${LAN_PROBE_ADDR:-}" \
      LVM_COLLECTOR_SRC  "${LVM_COLLECTOR_SRC:-}"
    cat "$0"
  # The Proxmox host logs in as root and has no sudo installed; the VMs log in
  # as deployer and do. Every other installer in this repo hardcodes
  # `sudo bash -s` because none of them target the hypervisor.
  } | ssh "$REMOTE_HOST" 'if [ "$(id -u)" -eq 0 ]; then bash -s; else sudo bash -s; fi'
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution" >&2
  exit 1
fi

NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
LAN_PROBE_ADDR="${LAN_PROBE_ADDR:-192.168.20.1}"
TEXTFILE_DIR=/var/lib/prometheus/node-exporter

LAN_IP="$(ip -4 route get "$LAN_PROBE_ADDR" 2>/dev/null \
          | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)"
if [[ -z "$LAN_IP" ]]; then
  echo "Error: could not derive a LAN address from the route to ${LAN_PROBE_ADDR}" >&2
  exit 1
fi
echo "==> LAN address: ${LAN_IP}"

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
# Only refresh the index if the package isn't resolvable yet. On the Proxmox
# host `apt-get update` hits the enterprise repo without a subscription and
# returns non-zero, which would abort under `set -e` for no good reason.
if ! apt-cache policy prometheus-node-exporter 2>/dev/null | grep -q 'Candidate: [0-9]'; then
  echo "==> Refreshing package index..."
  apt-get update -qq
fi

if ! dpkg -s prometheus-node-exporter &>/dev/null; then
  echo "==> Installing prometheus-node-exporter..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq prometheus-node-exporter
else
  echo "==> prometheus-node-exporter already installed"
fi

mkdir -p "$TEXTFILE_DIR"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
# Excluding the container overlay mounts is not cosmetic: without it the k3s
# and docker hosts emit one node_filesystem_* series per container layer and
# the series count grows with every deploy. /mnt/k8s-persistent -- the
# local-path PV store -- is deliberately still in scope.
MOUNT_EXCLUDE='^/(dev|proc|sys|run|var/lib/kubelet/.+|var/lib/docker/.+|var/lib/containerd/.+)($|/)'

echo "==> Writing /etc/default/prometheus-node-exporter..."
# ARGS must be a single line: this file is read as a systemd EnvironmentFile,
# which does not honour backslash continuations.
cat > /etc/default/prometheus-node-exporter <<EOF
# Managed by bootstrap/node-exporter/install.sh -- local edits are overwritten.
ARGS="--web.listen-address=${LAN_IP}:${NODE_EXPORTER_PORT} --collector.textfile.directory=${TEXTFILE_DIR} --collector.filesystem.mount-points-exclude=${MOUNT_EXCLUDE}"
EOF

systemctl enable --now prometheus-node-exporter
systemctl restart prometheus-node-exporter

# ---------------------------------------------------------------------------
# LVM thin pool metrics (hosts that have thin pools -- in practice the hypervisor)
# ---------------------------------------------------------------------------
# Detected by the presence of thin pools rather than by hostname or IP, so this
# stays honest if the hypervisor ever moves.
if command -v lvs &>/dev/null && \
   lvs --noheadings --select 'lv_attr=~"^t"' 2>/dev/null | grep -q .; then
  if [[ -z "${LVM_COLLECTOR_SRC:-}" ]]; then
    echo "Error: thin pools present but LVM_COLLECTOR_SRC is empty." >&2
    echo "       Run through setup.sh, or from a checkout that has" >&2
    echo "       lvm-thinpool-metrics.sh next to this script." >&2
    exit 1
  fi
  echo "==> Thin pools present -- installing the LVM textfile collector..."

  printf '%s\n' "$LVM_COLLECTOR_SRC" > /usr/local/bin/lvm-thinpool-metrics.sh
  chmod 0755 /usr/local/bin/lvm-thinpool-metrics.sh

  cat > /etc/systemd/system/lvm-thinpool-metrics.service <<'UNIT'
[Unit]
Description=Export LVM thin pool usage for node_exporter

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lvm-thinpool-metrics.sh
UNIT

  cat > /etc/systemd/system/lvm-thinpool-metrics.timer <<'UNIT'
[Unit]
Description=Refresh LVM thin pool metrics every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now lvm-thinpool-metrics.timer
  systemctl start lvm-thinpool-metrics.service
else
  echo "==> No LVM thin pools here -- skipping the LVM textfile collector"
fi

# ---------------------------------------------------------------------------
# Smoke check
# ---------------------------------------------------------------------------
sleep 2
# Read into a variable rather than piping into grep: `grep -q` exits on the
# first match, curl takes SIGPIPE, and pipefail turns a healthy exporter into
# a failed install.
metrics="$(curl -sf --max-time 5 "http://${LAN_IP}:${NODE_EXPORTER_PORT}/metrics" || true)"
if grep -q '^node_memory_MemAvailable_bytes' <<<"$metrics"; then
  echo "==> OK: exporter answering on ${LAN_IP}:${NODE_EXPORTER_PORT}"
else
  echo "Error: exporter not answering on ${LAN_IP}:${NODE_EXPORTER_PORT}" >&2
  systemctl status prometheus-node-exporter --no-pager || true
  exit 1
fi
