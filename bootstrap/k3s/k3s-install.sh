#!/usr/bin/env bash
# Runs on the k3s VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.11 ./k3s-install.sh
if [[ -n "${REMOTE_HOST:-}" ]]; then
  cat "$0" | ssh "$REMOTE_HOST" "sudo bash -s"; exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

# Kubelet image garbage collection thresholds, written before the installer so a
# fresh node comes up with them already in effect.
#
# The defaults (85/80) pinned this node's root filesystem between 63G and 67G of
# its 79G. The images actually in use total ~3G; the rest was deploy history that
# GC evicted just in time to stay under the 85% alert threshold, so the disk
# always looked nearly full while never actually filling.
#
# Both of this VM's disks are thin volumes on the same oversubscribed local-lvm
# pool (262G backing 460G of provisioned volumes, and the pve VG has no free
# extents left to grow it), so that high-water mark is charged against the pool.
#
# 50/35 lets containerd sit between ~24G and ~36G instead. The floor is still ~8x
# the working set, so GC never thrashes, and the lower ceiling returns the
# difference to the thin pool once fstrim runs (scsi0 has discard=on).
echo "Writing kubelet image GC thresholds..."
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<'CONFIG'
kubelet-arg:
  - image-gc-high-threshold=50
  - image-gc-low-threshold=35
CONFIG

echo "Installing K3s with Traefik disabled..."

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

echo "Waiting for K3s service to be active..."
# Wait for k3s service to be active
timeout=120
elapsed=0
while ! systemctl is-active --quiet k3s; do
  if [ $elapsed -ge $timeout ]; then
    echo "Error: K3s service did not become active within ${timeout} seconds"
    echo "Checking k3s service status:"
    systemctl status k3s --no-pager -l || true
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

echo "K3s service is active, waiting for kubeconfig..."
# Wait for kubeconfig to be available
elapsed=0
while [ ! -f /etc/rancher/k3s/k3s.yaml ]; do
  if [ $elapsed -ge $timeout ]; then
    echo "Error: kubeconfig file not found within ${timeout} seconds"
    exit 1
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

# Set up kubeconfig for root user
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Update kubeconfig server URL if needed (replace localhost with actual IP)
# Get the primary IP address
PRIMARY_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K\S+' | head -1)
if [ -n "$PRIMARY_IP" ]; then
  echo "Updating kubeconfig server URL to use $PRIMARY_IP..."
  sed -i "s/127.0.0.1:6443/${PRIMARY_IP}:6443/g" /etc/rancher/k3s/k3s.yaml
fi

echo "Waiting for Kubernetes API to be ready..."
# Wait for kubectl to work with better diagnostics
elapsed=0
while true; do
  # Try to get nodes
  if kubectl get nodes &>/dev/null; then
    break
  fi

  if [ $elapsed -ge $timeout ]; then
    echo "Error: Kubernetes API did not become ready within ${timeout} seconds"
    echo ""
    echo "Diagnostics:"
    echo "1. K3s service status:"
    systemctl status k3s --no-pager -l | head -20 || true
    echo ""
    echo "2. Recent K3s logs:"
    journalctl -u k3s --no-pager -n 30 || true
    echo ""
    echo "3. Checking if API server is listening:"
    netstat -tlnp | grep 6443 || ss -tlnp | grep 6443 || true
    echo ""
    echo "4. Testing API server connection:"
    curl -k https://127.0.0.1:6443/healthz 2>&1 | head -5 || true
    echo ""
    exit 1
  fi

  # Show progress every 10 seconds
  if [ $((elapsed % 10)) -eq 0 ] && [ $elapsed -gt 0 ]; then
    echo "  Still waiting... (${elapsed}s elapsed)"
  fi

  sleep 2
  elapsed=$((elapsed + 2))
done

echo "K3s installed successfully"
echo "Kubernetes nodes:"
kubectl get nodes

# Install Helm
echo ""
echo "Installing Helm..."
if ! command -v helm &> /dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo "Helm installed successfully"
else
  echo "Helm already installed"
fi
