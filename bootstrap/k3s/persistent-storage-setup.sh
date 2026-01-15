#!/bin/bash
#
# Setup persistent storage for K3s using Proxmox storage (ZFS or LVM)
#
# This script:
# 1. Creates and attaches a disk in Proxmox (ZFS or LVM)
# 2. Formats and mounts it in the K3s VM
# 3. Creates PV directories on the mounted disk
#
# Usage:
#   ./persistent-storage-setup.sh [K3S_IP] [PROXMOX_HOST]
#
# Environment variables:
#   PROXMOX_USER      - Proxmox SSH user (default: root)
#   PROXMOX_HOST      - Proxmox host (can be passed as arg or env var)
#   K3S_VMID          - K3s VM ID (default: 112)
#   SSH_USER          - K3s VM SSH user (default: deployer)
#
# Examples:
#   ./persistent-storage-setup.sh 192.168.20.11 proxmox.local
#
# This script is idempotent - safe to run multiple times.
#

set -euo pipefail


# Configuration
K3S_IP="${1:-192.168.20.11}"
PROXMOX_HOST="${2:-${PROXMOX_HOST:-192.168.20.10}}"
K3S_VMID="${K3S_VMID:-112}"
SSH_USER="${SSH_USER:-deployer}"
SSH_KEY="${SSH_KEY:-}"
PROXMOX_USER="${PROXMOX_USER:-root}"
DISK_SIZE="${DISK_SIZE:-200G}"
MOUNT_POINT="/mnt/k8s-persistent"
PV_BASE_PATH="${MOUNT_POINT}/pvs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

ssh_cmd() {
    ssh $SSH_OPTS "$SSH_USER@$K3S_IP" "$@"
}

proxmox_cmd() {
    if [ -z "$PROXMOX_HOST" ]; then
        log_error "PROXMOX_HOST not set. Provide as argument or environment variable."
        exit 1
    fi
    ssh $SSH_OPTS "$PROXMOX_USER@$PROXMOX_HOST" "$@"
}

echo ""
echo "=============================================="
echo "   K3s Persistent Storage Setup"
echo "=============================================="
echo ""
log_info "K3s VM IP: $K3S_IP"
log_info "K3s VM ID: $K3S_VMID"
log_info "Proxmox Host: ${PROXMOX_HOST:-<not set>}"
echo ""

# Check SSH connectivity to K3s VM
log_info "Checking SSH connectivity to K3s VM..."
if ! ssh_cmd "echo 'SSH connection successful'" 2>/dev/null; then
    log_error "Cannot connect to $K3S_IP"
    log_info "Make sure:"
    log_info "  1. The VM is running (check Proxmox)"
    log_info "  2. Your SSH key is authorized"
    log_info "  3. The IP address is correct"
    exit 1
fi
log_success "SSH connection to K3s VM established"

# Check SSH connectivity to Proxmox
if [ -n "$PROXMOX_HOST" ]; then
    log_info "Checking SSH connectivity to Proxmox..."
    if ! proxmox_cmd "echo 'SSH connection successful'" 2>/dev/null; then
        log_error "Cannot connect to Proxmox host: $PROXMOX_HOST"
        log_info "Make sure:"
        log_info "  1. Proxmox host is reachable"
        log_info "  2. Your SSH key is authorized for $PROXMOX_USER@$PROXMOX_HOST"
        exit 1
    fi
    log_success "SSH connection to Proxmox established"
fi

# Check if kubectl is available on K3s VM
log_info "Checking kubectl access..."
if ! ssh_cmd "sudo kubectl get nodes" &>/dev/null; then
    log_error "Cannot access Kubernetes cluster"
    log_info "Make sure K3s is installed and running"
    exit 1
fi
log_success "Kubernetes cluster accessible"

# Step 1: Select storage type
echo ""
log_info "Select storage type:"
echo "  1) LVM (local-lvm) - Recommended, simpler, matches postgres setup"
echo "  2) ZFS (tank) - For advanced features (snapshots, compression)"
echo ""
read -p "Enter choice [1-2] (default: 1): " storage_choice
storage_choice="${storage_choice:-1}"

case "$storage_choice" in
    1)
        STORAGE_TYPE="lvm"
        PROXMOX_STORAGE="${PROXMOX_STORAGE:-local-lvm}"
        ;;
    2)
        STORAGE_TYPE="zfs"
        PROXMOX_STORAGE="${PROXMOX_STORAGE:-tank}"
        ;;
    *)
        log_error "Invalid choice"
        exit 1
        ;;
esac

log_success "Selected: $STORAGE_TYPE (storage: $PROXMOX_STORAGE)"

# Step 2: Check if disk is already attached
log_info "Checking for attached persistent disk..."
DISK_DEVICE=$(ssh_cmd "lsblk -o NAME,TYPE,MOUNTPOINT | grep -E '^sd[b-z]|^vd[b-z]' | grep -v 'part' | head -1 | awk '{print \$1}'" || echo "")

if [ -z "$DISK_DEVICE" ]; then
    log_warn "No persistent disk found attached to VM"

    if [ -z "$PROXMOX_HOST" ]; then
        log_error "Cannot create disk: PROXMOX_HOST not set"
        log_info "Provide Proxmox host as second argument or set PROXMOX_HOST env var"
        exit 1
    fi

    echo ""
    log_info "Creating disk in Proxmox..."

    DISK_NAME="vm-${K3S_VMID}-persistent"

    # Check if disk already exists in Proxmox
    if proxmox_cmd "pvesm status | grep -q ${DISK_NAME}" 2>/dev/null; then
        log_warn "Disk ${DISK_NAME} already exists in Proxmox storage"
        read -p "Use existing disk? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted. Please remove existing disk or choose different name."
            exit 0
        fi
    else
        # Create disk
        log_info "Creating ${DISK_SIZE} disk on ${PROXMOX_STORAGE}..."
        if [ "$STORAGE_TYPE" = "zfs" ]; then
            # For ZFS, create dataset first if it doesn't exist
            if ! proxmox_cmd "zfs list ${PROXMOX_STORAGE}/k8s-persistent" &>/dev/null; then
                log_info "Creating ZFS dataset..."
                proxmox_cmd "zfs create ${PROXMOX_STORAGE}/k8s-persistent" || true
            fi
        fi

        proxmox_cmd "pvesm alloc ${PROXMOX_STORAGE} ${K3S_VMID} ${DISK_NAME} ${DISK_SIZE}"
        log_success "Disk created in Proxmox"
    fi

    # Attach disk to VM
    log_info "Attaching disk to VM ${K3S_VMID}..."

    # Check if scsi1 is already in use
    if proxmox_cmd "qm config ${K3S_VMID} | grep -q '^scsi1:'"; then
        log_warn "scsi1 is already in use on VM ${K3S_VMID}"
        log_info "Current scsi1 configuration:"
        proxmox_cmd "qm config ${K3S_VMID} | grep '^scsi1:'" || true
        read -p "Replace existing scsi1? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Aborted. Please manually attach disk or free up scsi1."
            exit 0
        fi
    fi

    proxmox_cmd "qm set ${K3S_VMID} --scsi1 ${PROXMOX_STORAGE}:${DISK_NAME}"
    log_success "Disk attached to VM"

    # Wait a moment for disk to appear
    log_info "Waiting for disk to appear in VM..."
    sleep 3

    # Re-check for disk
    DISK_DEVICE=$(ssh_cmd "lsblk -o NAME,TYPE,MOUNTPOINT | grep -E '^sd[b-z]|^vd[b-z]' | grep -v 'part' | head -1 | awk '{print \$1}'" || echo "")
    if [ -z "$DISK_DEVICE" ]; then
        log_error "Disk still not found. You may need to rescan:"
        log_info "  ssh $SSH_USER@$K3S_IP 'echo \"- - -\" | sudo tee /sys/class/scsi_host/host*/scan'"
        exit 1
    fi
fi

log_success "Found disk: /dev/$DISK_DEVICE"

# Step 3: Check if disk is formatted
log_info "Checking if disk is formatted..."
IS_FORMATTED=$(ssh_cmd "sudo blkid /dev/$DISK_DEVICE" || echo "")

if [ -z "$IS_FORMATTED" ]; then
    log_warn "Disk is not formatted"
    echo ""
    log_warn "This will format the disk and destroy any existing data!"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi

    log_info "Formatting disk with ext4..."
    ssh_cmd "sudo mkfs.ext4 -L k8s-persistent -F /dev/$DISK_DEVICE"
    log_success "Disk formatted"
else
    log_success "Disk is already formatted"
    # Check label
    DISK_LABEL=$(ssh_cmd "sudo blkid -s LABEL -o value /dev/$DISK_DEVICE" || echo "")
    if [ "$DISK_LABEL" != "k8s-persistent" ]; then
        log_warn "Disk label is '$DISK_LABEL', expected 'k8s-persistent'"
        log_info "Continuing anyway..."
    fi
fi

# Step 4: Create mount point and mount
log_info "Setting up mount point..."
ssh_cmd "sudo mkdir -p $MOUNT_POINT"

# Check if already mounted
IS_MOUNTED=$(ssh_cmd "mountpoint -q $MOUNT_POINT && echo 'yes' || echo 'no'")
if [ "$IS_MOUNTED" = "no" ]; then
    log_info "Mounting disk..."
    ssh_cmd "sudo mount -L k8s-persistent $MOUNT_POINT || sudo mount /dev/$DISK_DEVICE $MOUNT_POINT"
    log_success "Disk mounted"
else
    log_success "Disk already mounted"
fi

# Add to fstab if not present
log_info "Ensuring persistent mount (fstab)..."
FSTAB_ENTRY="LABEL=k8s-persistent $MOUNT_POINT ext4 defaults,noatime 0 2"
if ! ssh_cmd "grep -q 'k8s-persistent' /etc/fstab" 2>/dev/null; then
    ssh_cmd "echo '$FSTAB_ENTRY' | sudo tee -a /etc/fstab"
    log_success "Added to fstab"
else
    log_success "Already in fstab"
fi

# Step 5: Create base directory structure
log_info "Creating directory structure..."
ssh_cmd "sudo mkdir -p $PV_BASE_PATH"
ssh_cmd "sudo chmod 755 $PV_BASE_PATH"
log_success "Directory structure created"

# Step 6: Create PV directories
log_info "Creating PV directories..."
ssh_cmd "sudo mkdir -p ${PV_BASE_PATH}/werify-staging-uploads"
ssh_cmd "sudo mkdir -p ${PV_BASE_PATH}/werify-production-uploads"
ssh_cmd "sudo mkdir -p ${PV_BASE_PATH}/bugsink-data"
ssh_cmd "sudo chmod 777 ${PV_BASE_PATH}/werify-staging-uploads"
ssh_cmd "sudo chmod 777 ${PV_BASE_PATH}/werify-production-uploads"
ssh_cmd "sudo chmod 777 ${PV_BASE_PATH}/bugsink-data"
log_success "PV directories created"

# Step 7: Get node name for reference
log_info "Getting Kubernetes node name..."
NODE_NAME=$(ssh_cmd "sudo kubectl get nodes -o jsonpath='{.items[0].metadata.name}'")
if [ -z "$NODE_NAME" ]; then
    log_warn "Could not determine node name"
else
    log_success "Node name: $NODE_NAME"
    log_info "Update PV manifests with this node name if needed"
fi

# Summary
echo ""
echo "=============================================="
echo "   Setup Complete!"
echo "=============================================="
echo ""
log_success "Persistent storage is configured"
echo ""
log_info "Proxmox disk: ${PROXMOX_STORAGE}:vm-${K3S_VMID}-persistent (${DISK_SIZE})"
log_info "Mount point: $MOUNT_POINT"
log_info "PV base path: $PV_BASE_PATH"
if [ -n "$NODE_NAME" ]; then
    log_info "Node name: $NODE_NAME"
fi
echo ""
log_info "PV directories created:"
echo "  - ${PV_BASE_PATH}/werify-staging-uploads"
echo "  - ${PV_BASE_PATH}/werify-production-uploads"
echo "  - ${PV_BASE_PATH}/bugsink-data"
echo ""
log_info "Next steps:"
echo "  1. Ensure PV manifests in gitops/storageclass/ have correct node name"
if [ -n "$NODE_NAME" ]; then
    echo "     Current node name: $NODE_NAME"
fi
echo "  2. Commit and push gitops changes to git"
echo "  3. ArgoCD will sync the changes automatically"
echo ""
log_info "To verify after sync:"
echo "  kubectl get pv"
echo "  kubectl get pvc -A"
echo "  ssh $SSH_USER@$K3S_IP 'df -h $MOUNT_POINT'"
echo ""
