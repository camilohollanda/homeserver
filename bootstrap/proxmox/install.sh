#!/usr/bin/env bash
# Reinstalls Proxmox host-level customisations that don't fit anywhere else:
#
#   1. NIC fix for the on-board Intel I217-LM (e1000e). Without this, large
#      TCP transfers corrupt mid-stream and peers drop the connection. The
#      `if-up.d/*` scripts disable offloads + EEE on nic0 every time the
#      interface comes up.
#
#   2. The nic0 rename (.link file under /usr/local/lib/systemd/network/) is
#      installed by the Proxmox ISO; we only verify it here.
#
# This script is idempotent. Run it once after a clean PVE install, or any
# time the if-up.d scripts in this folder change.
#
# Remote:
#   REMOTE_HOST=root@192.168.20.10 ./install.sh
#
# Local (run on the PVE host itself):
#   sudo ./install.sh
if [[ -n "${REMOTE_HOST:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Bundle the if-up.d scripts into the remote invocation by base64-embedding
  # them, then have the remote shell decode + drop them in place. Avoids a
  # separate scp step and keeps the "one script does it all" pattern used by
  # the other bootstrap installers in this repo.
  DISABLE_OFFLOADS_B64="$(base64 < "${SCRIPT_DIR}/if-up.d/disable-offloads")"
  DISABLE_EEE_B64="$(base64 < "${SCRIPT_DIR}/if-up.d/disable-eee")"
  # PVE doesn't ship sudo (root-only OS); detect that and skip the prefix.
  remote_sh="sudo bash -s"
  [[ "${REMOTE_HOST%%@*}" == "root" ]] && remote_sh="bash -s"
  { printf 'export %s=%q\n' \
      DISABLE_OFFLOADS_B64 "${DISABLE_OFFLOADS_B64}" \
      DISABLE_EEE_B64      "${DISABLE_EEE_B64}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "$remote_sh"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution" >&2
  exit 1
fi

: "${DISABLE_OFFLOADS_B64:?must be set (re-exec via REMOTE_HOST=)}"
: "${DISABLE_EEE_B64:?must be set (re-exec via REMOTE_HOST=)}"

echo "==> Installing NIC fix scripts to /etc/network/if-up.d/..."
install -d -m 0755 /etc/network/if-up.d
echo "$DISABLE_OFFLOADS_B64" | base64 -d > /etc/network/if-up.d/disable-offloads
echo "$DISABLE_EEE_B64"      | base64 -d > /etc/network/if-up.d/disable-eee
chmod 0755 /etc/network/if-up.d/disable-offloads /etc/network/if-up.d/disable-eee
echo "  ✓ /etc/network/if-up.d/disable-offloads"
echo "  ✓ /etc/network/if-up.d/disable-eee"

echo ""
echo "==> Verifying nic0 rename rule is in place..."
LINK_FILE=/usr/local/lib/systemd/network/50-pmx-nic0.link
if [[ -f "$LINK_FILE" ]]; then
  echo "  ✓ $LINK_FILE present"
else
  echo "  ⚠️  $LINK_FILE missing — was this PVE installed by something other"
  echo "     than the official ISO? The if-up.d scripts only run when the"
  echo "     interface is named 'nic0', so without that .link file they're"
  echo "     a no-op."
fi

echo ""
echo "==> Applying offload settings to the live interface (no reboot needed)..."
if ip link show nic0 >/dev/null 2>&1; then
  IFACE=nic0 /etc/network/if-up.d/disable-offloads
  /etc/network/if-up.d/disable-eee
  echo "  ✓ offloads + EEE disabled on nic0"
  echo ""
  echo "==> Current offload state:"
  ethtool -k nic0 | grep -E "tcp-segmentation|generic-(segmentation|receive)|large-receive|rx-checksumming|tx-checksumming" | sed 's/^/    /'
else
  echo "  ⚠️  nic0 not present yet — scripts will fire on next ifup."
fi

echo ""
echo "✓ Proxmox host customisations installed."
echo "  Next: bootstrap/restic/configure.sh proxmox    # to add backups"
