#!/bin/bash
# Create Debian 12 + NVIDIA GPU template for Proxmox
# Pre-installs NVIDIA drivers so VMs are GPU-ready immediately

set -e

# Configuration
PROXMOX_HOST="192.168.20.10"
PROXMOX_USER="root"
PROXMOX_STORAGE="local-lvm"
PROXMOX_SNIPPET_STORAGE="local"
PROXMOX_IMAGE_DIR="/var/lib/vz/template/iso"
TEMPLATE_VMID="9003"
TEMPLATE_NAME="debian-12-nvidia-cloudinit"

# Cloud-init configuration
CLOUD_INIT_USER="deployer"
CLOUD_INIT_PASSWORD="deployer123"
SSH_KEYS_FILE="/root/.ssh/authorized_keys"

# Debian 12 cloud image
DEBIAN12_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Debian 12 + NVIDIA GPU Template Creation${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check connection
echo -e "${YELLOW}Checking connection to Proxmox host...${NC}"
if ! ssh -o ConnectTimeout=5 "${PROXMOX_USER}@${PROXMOX_HOST}" "exit" 2>/dev/null; then
    echo -e "${RED}ERROR: Cannot connect to ${PROXMOX_USER}@${PROXMOX_HOST}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to Proxmox${NC}"

# Check for libguestfs-tools
echo -e "${YELLOW}Checking for required tools...${NC}"
if ! ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "which virt-customize" &>/dev/null; then
    echo -e "${RED}ERROR: libguestfs-tools not installed on Proxmox host${NC}"
    echo "Install with: apt-get install -y libguestfs-tools"
    exit 1
fi
echo -e "${GREEN}✓ libguestfs-tools available${NC}"

# Check if SSH keys exist
if ! ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${SSH_KEYS_FILE}"; then
    echo -e "${RED}ERROR: SSH keys file not found: ${SSH_KEYS_FILE}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ SSH keys file exists${NC}"
echo ""

# Image paths
ORIGINAL_FILENAME="debian-12-genericcloud-amd64.original.qcow2"
IMAGE_FILENAME="debian-12-nvidia-amd64.qcow2"
ORIGINAL_PATH="${PROXMOX_IMAGE_DIR}/${ORIGINAL_FILENAME}"
IMAGE_PATH="${PROXMOX_IMAGE_DIR}/${IMAGE_FILENAME}"
MARKER_FILE="${IMAGE_PATH}.customized"

# Check if template already exists
if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm status ${TEMPLATE_VMID}" &>/dev/null; then
    echo -e "${YELLOW}WARNING: VM ${TEMPLATE_VMID} already exists${NC}"
    read -p "Destroy and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm destroy ${TEMPLATE_VMID}"
        echo -e "${GREEN}✓ VM ${TEMPLATE_VMID} destroyed${NC}"
    else
        echo "Exiting."
        exit 0
    fi
fi

# Download original image if needed
if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${ORIGINAL_PATH}"; then
    echo -e "${GREEN}✓ Original Debian 12 image cached${NC}"
else
    echo -e "${YELLOW}Downloading Debian 12 cloud image...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "wget -q --show-progress -O ${ORIGINAL_PATH} ${DEBIAN12_IMAGE_URL}"
    echo -e "${GREEN}✓ Image downloaded${NC}"
fi

# Check if customized NVIDIA image exists
NEED_CUSTOMIZATION=false
if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${IMAGE_PATH}"; then
    if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${MARKER_FILE}"; then
        CUSTOM_DATE=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "cat ${MARKER_FILE}")
        echo -e "${GREEN}✓ NVIDIA image exists (customized: ${CUSTOM_DATE})${NC}"
        read -p "Re-customize? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "rm -f ${IMAGE_PATH} ${MARKER_FILE}"
            NEED_CUSTOMIZATION=true
        fi
    else
        NEED_CUSTOMIZATION=true
    fi
else
    NEED_CUSTOMIZATION=true
fi

# Create and customize image
if [ "$NEED_CUSTOMIZATION" = true ]; then
    echo -e "${YELLOW}Creating resized copy from original (20GB)...${NC}"
    # Use virt-resize to copy AND expand the root partition
    # This is necessary because NVIDIA drivers + headers need ~5-6GB
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qemu-img create -f qcow2 ${IMAGE_PATH} 20G"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "virt-resize --expand /dev/sda1 ${ORIGINAL_PATH} ${IMAGE_PATH}"
    echo -e "${GREEN}✓ Image created and resized to 20GB${NC}"

    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Customizing image with NVIDIA drivers${NC}"
    echo -e "${BLUE}This will take 10-15 minutes...${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    echo "  - Image resized to 20GB (NVIDIA needs ~5-6GB)"
    echo "  - Updating all packages"
    echo "  - Blacklisting nouveau driver"
    echo "  - Enabling non-free repositories"
    echo "  - Installing NVIDIA drivers + DKMS"
    echo "  - Installing qemu-guest-agent"
    echo "  - Creating user: ${CLOUD_INIT_USER}"
    echo ""

    # Generate password hash
    VIRT_PASSWORD_HASH=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "openssl passwd -6 '${CLOUD_INIT_PASSWORD}'")

    # Run virt-customize with NVIDIA driver installation
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "virt-customize -a ${IMAGE_PATH} \
        --update \
        --run-command 'echo \"blacklist nouveau\" > /etc/modprobe.d/blacklist-nouveau.conf' \
        --run-command 'echo \"blacklist lbm-nouveau\" >> /etc/modprobe.d/blacklist-nouveau.conf' \
        --run-command 'echo \"options nouveau modeset=0\" >> /etc/modprobe.d/blacklist-nouveau.conf' \
        --run-command 'echo \"alias nouveau off\" >> /etc/modprobe.d/blacklist-nouveau.conf' \
        --run-command 'echo \"alias lbm-nouveau off\" >> /etc/modprobe.d/blacklist-nouveau.conf' \
        --run-command 'if [ -f /etc/apt/sources.list.d/debian.sources ]; then sed -i \"s/Components: main\$/Components: main contrib non-free non-free-firmware/\" /etc/apt/sources.list.d/debian.sources; fi' \
        --run-command 'apt-get update' \
        --install linux-headers-amd64,nvidia-driver,nvidia-kernel-dkms,firmware-misc-nonfree,qemu-guest-agent \
        --run-command 'update-initramfs -u' \
        --run-command 'useradd -m -s /bin/bash ${CLOUD_INIT_USER}' \
        --run-command 'usermod -aG sudo,video,render ${CLOUD_INIT_USER}' \
        --password ${CLOUD_INIT_USER}:password:'${VIRT_PASSWORD_HASH}' \
        --ssh-inject ${CLOUD_INIT_USER}:file:${SSH_KEYS_FILE} \
        --run-command 'chmod 755 /home/${CLOUD_INIT_USER}' \
        --write /etc/sudoers.d/${CLOUD_INIT_USER}:'${CLOUD_INIT_USER} ALL=(ALL) NOPASSWD: ALL' \
        --run-command 'chmod 440 /etc/sudoers.d/${CLOUD_INIT_USER}' \
        --run-command 'apt-get clean' \
        --run-command 'rm -rf /var/lib/apt/lists/*' \
        --selinux-relabel 2>&1 | grep -v '^libguestfs:' || true"

    # Mark as customized
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "date '+%Y-%m-%d %H:%M:%S' > ${MARKER_FILE}"
    echo -e "${GREEN}✓ Image customized with NVIDIA drivers${NC}"
fi

echo ""
echo -e "${YELLOW}Creating VM ${TEMPLATE_VMID}...${NC}"

# Create VM
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm create ${TEMPLATE_VMID} \
    --name ${TEMPLATE_NAME} \
    --memory 4096 \
    --cores 4 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-pci \
    --bios ovmf \
    --machine q35"
echo -e "${GREEN}✓ VM created${NC}"

# Import disk
echo -e "${YELLOW}Importing disk...${NC}"
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm importdisk ${TEMPLATE_VMID} ${IMAGE_PATH} ${PROXMOX_STORAGE} --format qcow2"
echo -e "${GREEN}✓ Disk imported${NC}"

# Attach disk
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} --scsi0 ${PROXMOX_STORAGE}:vm-${TEMPLATE_VMID}-disk-0"
echo -e "${GREEN}✓ Disk attached${NC}"

# Add EFI disk (Secure Boot DISABLED for NVIDIA)
echo -e "${YELLOW}Adding EFI disk (Secure Boot disabled)...${NC}"
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} --efidisk0 ${PROXMOX_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
echo -e "${GREEN}✓ EFI disk added${NC}"

# Cloud-init drive
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} --ide2 ${PROXMOX_STORAGE}:cloudinit"
echo -e "${GREEN}✓ Cloud-init drive added${NC}"

# Boot options
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} --boot c --bootdisk scsi0"
echo -e "${GREEN}✓ Boot options configured${NC}"

# Serial console
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} --serial0 socket --vga serial0"
echo -e "${GREEN}✓ Serial console added${NC}"

# QEMU guest agent
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} --agent enabled=1,fstrim_cloned_disks=1"
echo -e "${GREEN}✓ QEMU guest agent enabled${NC}"

# Cloud-init settings
PASSWORD_HASH=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "openssl passwd -6 '${CLOUD_INIT_PASSWORD}'")
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${TEMPLATE_VMID} \
    --ciuser ${CLOUD_INIT_USER} \
    --cipassword '${PASSWORD_HASH}' \
    --sshkeys ${SSH_KEYS_FILE} \
    --ipconfig0 ip=dhcp"
echo -e "${GREEN}✓ Cloud-init configured${NC}"

# Convert to template
echo -e "${YELLOW}Converting to template...${NC}"
ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm template ${TEMPLATE_VMID}"
echo -e "${GREEN}✓ Template created${NC}"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}NVIDIA Template Created Successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Template: VMID ${TEMPLATE_VMID} (${TEMPLATE_NAME})"
echo ""
echo -e "${BLUE}Pre-installed:${NC}"
echo "  • NVIDIA driver 535.x (from Debian non-free)"
echo "  • NVIDIA kernel modules (DKMS)"
echo "  • nouveau driver blacklisted"
echo "  • Secure Boot disabled"
echo "  • qemu-guest-agent"
echo "  • User: ${CLOUD_INIT_USER} (NOPASSWD sudo)"
echo ""
echo -e "${BLUE}Usage in Terraform:${NC}"
echo "  template_vmid_debian12_nvidia = ${TEMPLATE_VMID}"
echo ""
echo -e "${GREEN}VMs cloned from this template will have GPU support immediately!${NC}"
echo ""
