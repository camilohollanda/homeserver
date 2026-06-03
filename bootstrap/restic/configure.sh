#!/usr/bin/env bash
# Provisions restic on a known VM using pre-canned backup paths for the apps
# we actually run on this homeserver. Profiles encode what's worth backing up
# on each host (and what isn't — Postgres lives elsewhere via wal-g, model
# files re-download from upstream, etc.).
#
# Usage:
#   ./bootstrap/restic/configure.sh services    # VM 114 (Garage meta, Infisical, ...)
#   ./bootstrap/restic/configure.sh k3s         # VM 112 (werify uploads, k3s state, ...)
#   ./bootstrap/restic/configure.sh proxmox     # Host 192.168.20.10 (/etc/pve, templates, NIC fix)
#   ./bootstrap/restic/configure.sh all         # all three, in sequence
#
# Same S3/R2 credentials as setup.sh (re-exported from env):
#   S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET
#   R2_ACCOUNT_ID  (or S3_ENDPOINT directly for B2 / other S3)
#
# Auto-generated if unset (printed at the end so you can store in Infisical):
#   RESTIC_PASSWORD
#
# Reuse the SAME RESTIC_PASSWORD across hosts. Each host writes to its own
# prefix in the shared bucket, so they don't collide.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Profiles: { ssh-host, JOBS string, friendly notes }
# JOBS format: "name:/path[,/path...] name2:/path ..."  (space-separated jobs)
# Each "name" becomes one systemd timer. Paths are validated on the remote VM
# before we commit to running — a missing path is a hard error, not a warning.
# ---------------------------------------------------------------------------

profile_services() {
  RESTIC_SSH="deployer@192.168.20.22"
  # Why each path:
  #   garage-meta      — Garage LMDB metadata. Without this the bucket data
  #                      (which we replicate separately to R2) is unreadable.
  #   infisical-cfg    — Holds ENCRYPTION_KEY + AUTH_SECRET in .env. Without
  #                      these, the Infisical Postgres backup is undecryptable.
  #   services-cfg     — Live shared nginx vhosts (conf.d/*.conf). Mostly
  #                      reproducible from git, but captures any drift.
  #   mailpit-data     — Dev SMTP capture sqlite. Low value but tiny (~150K).
  #   letsencrypt      — LE account + issued certs. Renewable, but skips a
  #                      few hours of re-issuing during a full rebuild.
  JOBS="\
garage-meta:/var/lib/garage/meta \
infisical-cfg:/opt/infisical \
services-cfg:/opt/services \
mailpit-data:/opt/mailpit/data \
letsencrypt:/etc/letsencrypt"
  PROFILE_NOTES="Services VM (114) — Garage meta + Infisical/Garage .env files (critical), plus configs + certs"
}

profile_k3s() {
  RESTIC_SSH="deployer@192.168.20.11"
  # Why each path:
  #   werify-prod-uploads, werify-stg-uploads
  #                    — User-uploaded files. THIS IS THE USER DATA. Largest
  #                      and most important payload on this VM.
  #   grafana          — Dashboard JSON, datasource configs. Annoying to
  #                      reconstruct by hand.
  #   loki             — Log storage. Regenerable (logs flow in continuously),
  #                      kept here so a restore retains historical logs.
  #   k3s-db           — kine/sqlite cluster state. The gitops manifests are
  #                      in git, but cluster certs/tokens live here.
  #   k3s-server       — TLS material + node tokens. Pair with k3s-db to
  #                      bring a cluster back up without re-bootstrapping
  #                      every workload's TLS identity.
  JOBS="\
werify-prod-uploads:/mnt/k8s-persistent/pvs/werify-production-uploads \
werify-stg-uploads:/mnt/k8s-persistent/pvs/werify-staging-data \
grafana:/var/lib/rancher/k3s/storage/pvc-6c6c5fbf-8baa-4563-90ca-36934a0022a3_grafana_grafana-storage \
loki:/mnt/k8s-persistent/pvs/loki-storage \
k3s-db:/var/lib/rancher/k3s/server/db \
k3s-server:/var/lib/rancher/k3s/server/tls,/var/lib/rancher/k3s/server/cred,/var/lib/rancher/k3s/server/token,/var/lib/rancher/k3s/server/node-token,/var/lib/rancher/k3s/server/agent-token"
  PROFILE_NOTES="k3s VM (112) — werify uploads (11G prod + 2.2G stg), grafana, loki, k3s cluster state"
}

profile_proxmox() {
  RESTIC_SSH="root@192.168.20.10"
  # Why each path:
  #   pve-cluster      — /etc/pve is the FUSE-mounted cluster config. Holds
  #                      every VM .conf (incl. templates 9001/9002/9003),
  #                      storage.cfg, users, ACLs, firewall rules. Tiny but
  #                      irreplaceable.
  #   host-network     — interfaces + the if-up.d/disable-{offloads,eee}
  #                      scripts that work around the I217-LM e1000e bug.
  #                      See bootstrap/proxmox/README.md.
  #   host-modprobe    — vfio.conf (GPU passthrough PCI IDs) + nvidia /
  #                      microcode blacklists.
  #   host-apt         — Enterprise vs no-subscription repo wiring; subtle
  #                      and easy to forget on a rebuild.
  #   pmx-link         — /usr/local/lib/systemd/network/50-pmx-nic0.link,
  #                      the rule that renames the on-board NIC to nic0.
  #                      Without it, the if-up.d scripts (which match on
  #                      IFACE=nic0) silently skip.
  #   vz-template      — qcow2 base images in /var/lib/vz/template/iso
  #                      (~8G; the nvidia variant alone is 5.3G). These are
  #                      the SOURCE blobs for the cloud-init templates; the
  #                      templates themselves live in LVM-thin and are
  #                      rebuilt from these. Note: PVE's `iso` dir holds
  #                      the customized qcow2 sources on this host — that's
  #                      just how the template-build pipeline drops them.
  JOBS="\
pve-cluster:/etc/pve \
host-network:/etc/network \
host-modprobe:/etc/modprobe.d \
host-apt:/etc/apt \
pmx-link:/usr/local/lib/systemd/network \
vz-template:/var/lib/vz/template/iso"
  PROFILE_NOTES="Proxmox host (192.168.20.10) — /etc/pve, NIC-fix scripts, GPU passthrough config, qcow2 template sources"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

usage() {
  cat >&2 <<EOF
Usage: $0 {services|k3s|proxmox|all}

Requires the following env vars set (same as bootstrap/restic/setup.sh):
  S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY, S3_BUCKET
  R2_ACCOUNT_ID  (or S3_ENDPOINT directly)
  RESTIC_PASSWORD (auto-generated on first run — reuse the same value for
                   subsequent runs against other hosts)
EOF
  exit 2
}

[[ $# -eq 1 ]] || usage

profile="$1"

# Sanity: shared credential env (let setup.sh enforce; we just bail early with
# a friendlier message).
for v in S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET; do
  [[ -n "${!v:-}" ]] || { echo "Error: $v must be set in the environment." >&2; exit 1; }
done
if [[ -z "${S3_ENDPOINT:-}" && -z "${R2_ACCOUNT_ID:-}" ]]; then
  echo "Error: set R2_ACCOUNT_ID (R2) or S3_ENDPOINT (B2/other)." >&2
  exit 1
fi

# Strongly recommend reusing the same RESTIC_PASSWORD across hosts. If unset,
# warn + generate.
if [[ -z "${RESTIC_PASSWORD:-}" ]]; then
  export RESTIC_PASSWORD="$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)"
  echo "⚠️  RESTIC_PASSWORD not set — generated one:"
  echo "    $RESTIC_PASSWORD"
  echo "    Store this in Infisical NOW, then export it before running other hosts."
  echo ""
fi

run_profile() {
  local p="$1"
  case "$p" in
    services) profile_services ;;
    k3s)      profile_k3s ;;
    proxmox)  profile_proxmox ;;
    *)        echo "Unknown profile: $p" >&2; usage ;;
  esac

  # Proxmox doesn't ship `sudo` by default — you SSH in as root and there's
  # nothing to elevate to. Skip the sudo prefix when the remote user is root
  # so the same preflight logic works against both deployer-style VMs and
  # the PVE host.
  local ssh_user="${RESTIC_SSH%%@*}"
  local sudo_pfx="sudo "
  [[ "$ssh_user" == "root" ]] && sudo_pfx=""

  echo "=============================================="
  echo "  Restic profile: $p"
  echo "  $PROFILE_NOTES"
  echo "  Target: $RESTIC_SSH"
  echo "=============================================="

  # Pre-flight: every path in JOBS must exist on the target. Better to fail
  # here than to discover six months later that we've been backing up
  # nothing because a path was typo'd.
  echo ""
  echo "==> Pre-flight: verifying paths on $RESTIC_SSH..."
  missing=()
  for job in $JOBS; do
    paths_csv="${job#*:}"
    IFS=',' read -ra paths <<< "$paths_csv"
    for path in "${paths[@]}"; do
      if ssh -o BatchMode=yes "$RESTIC_SSH" "${sudo_pfx}test -e '$path'" 2>/dev/null; then
        size=$(ssh -o BatchMode=yes "$RESTIC_SSH" "${sudo_pfx}du -sh '$path' 2>/dev/null | awk '{print \$1}'")
        printf "  ✓ %-7s %s\n" "$size" "$path"
      else
        printf "  ✗ MISSING  %s\n" "$path"
        missing+=("$path")
      fi
    done
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "" >&2
    echo "Error: ${#missing[@]} path(s) missing on $RESTIC_SSH — fix the profile or skip this run." >&2
    exit 1
  fi

  echo ""
  echo "==> Dispatching to bootstrap/restic/setup.sh..."
  RESTIC_SSH="$RESTIC_SSH" JOBS="$JOBS" bash "${SCRIPT_DIR}/setup.sh"
}

case "$profile" in
  services|k3s|proxmox) run_profile "$profile" ;;
  all)
    run_profile services
    echo ""
    run_profile k3s
    echo ""
    run_profile proxmox
    ;;
  *) usage ;;
esac

echo ""
echo "=============================================="
echo "  configure.sh complete"
echo "=============================================="
echo "Verify on any host:"
echo "  ssh <host> 'sudo bash -c \"set -a; . /etc/restic/repo.env; restic snapshots --compact\"'"
