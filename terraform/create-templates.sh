#!/bin/bash
# Create and configure Proxmox VM templates from Debian cloud images
# This script downloads cloud images, installs necessary packages, creates templates,
# and configures cloud-init settings in a single unified workflow

set -e

# Configuration
PROXMOX_HOST="192.168.20.10"
PROXMOX_USER="root"
PROXMOX_STORAGE="local-lvm"  # Storage for VM disks
PROXMOX_SNIPPET_STORAGE="local"  # Storage for snippets/ISOs
PROXMOX_IMAGE_DIR="/var/lib/vz/template/iso"  # Where Proxmox stores ISO/images
TEMPLATE_DEBIAN13_VMID="9001"
TEMPLATE_DEBIAN12_VMID="9002"

# Cloud-init configuration
CLOUD_INIT_USER="deployer"
CLOUD_INIT_PASSWORD="deployer123"  # Change this to your desired password
SSH_KEYS_FILE="/root/.ssh/authorized_keys"  # Path on Proxmox host

# Debian cloud image URLs
DEBIAN13_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
DEBIAN12_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Proxmox Template Creation & Setup${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if we can connect to Proxmox
echo -e "${YELLOW}Checking connection to Proxmox host...${NC}"
if ! ssh -o ConnectTimeout=5 "${PROXMOX_USER}@${PROXMOX_HOST}" "exit" 2>/dev/null; then
    echo -e "${RED}ERROR: Cannot connect to ${PROXMOX_USER}@${PROXMOX_HOST}${NC}"
    echo "Please ensure:"
    echo "  1. SSH access is configured"
    echo "  2. SSH keys are set up for passwordless login"
    exit 1
fi
echo -e "${GREEN}✓ Connected to Proxmox${NC}"
echo ""

# Check if libguestfs-tools is installed
echo -e "${YELLOW}Checking for required tools...${NC}"
if ! ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "which virt-customize" &>/dev/null; then
    echo -e "${RED}ERROR: libguestfs-tools not installed on Proxmox host${NC}"
    echo "Please install it first:"
    echo "  ssh ${PROXMOX_USER}@${PROXMOX_HOST} 'apt-get update && apt-get install -y libguestfs-tools'"
    exit 1
fi
echo -e "${GREEN}✓ libguestfs-tools available${NC}"
echo ""

# Function to create and configure a VM template
create_template() {
    local vmid=$1
    local template_name=$2
    local image_url=$3
    local debian_version=$4

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Creating template ${vmid}: ${template_name}${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Check if template already exists
    if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm status ${vmid}" &>/dev/null; then
        echo -e "${YELLOW}WARNING: VM ${vmid} already exists${NC}"
        read -p "Do you want to destroy and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}Destroying existing VM ${vmid}...${NC}"
            ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm destroy ${vmid}"
            echo -e "${GREEN}✓ VM ${vmid} destroyed${NC}"
        else
            echo -e "${YELLOW}Skipping template ${vmid}${NC}"
            echo ""
            return 0
        fi
    fi

    # Image paths: original (pristine download) and working copy (customized)
    local original_filename="debian-${debian_version}-genericcloud-amd64.original.qcow2"
    local image_filename="debian-${debian_version}-genericcloud-amd64.qcow2"
    local original_path="${PROXMOX_IMAGE_DIR}/${original_filename}"
    local image_path="${PROXMOX_IMAGE_DIR}/${image_filename}"
    local marker_file="${image_path}.customized"
    local need_customization=false

    # Step 1: Check if original image exists, download if needed
    if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${original_path}"; then
        echo -e "${GREEN}✓ Original image cached: ${original_path}${NC}"
        local orig_size=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "du -h ${original_path} | cut -f1")
        echo "  Size: ${orig_size}"
    else
        echo -e "${YELLOW}Downloading Debian ${debian_version} cloud image...${NC}"
        echo "URL: ${image_url}"
        echo "Destination: ${original_path}"
        ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "cd ${PROXMOX_IMAGE_DIR} && wget -q --show-progress -O ${original_filename} ${image_url}"
        echo -e "${GREEN}✓ Original image downloaded to ${original_path}${NC}"
    fi

    # Step 2: Check if customized working copy exists
    if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${image_path}"; then
        echo -e "${GREEN}✓ Working image exists: ${image_path}${NC}"
        local image_size=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "du -h ${image_path} | cut -f1")
        echo "  Size: ${image_size}"

        # Check if image has been customized
        if ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${marker_file}"; then
            local custom_date=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "cat ${marker_file}")
            echo -e "${GREEN}✓ Image was customized on: ${custom_date}${NC}"
            echo -e "${YELLOW}Do you want to re-customize this image?${NC}"
            echo "  This will create a fresh copy from the original (no re-download needed)."
            read -p "Re-customize? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Deleting working copy and marker...${NC}"
                ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "rm -f ${image_path} ${marker_file}"
                need_customization=true
            else
                echo -e "${YELLOW}Skipping customization, using existing image${NC}"
            fi
        else
            echo -e "${YELLOW}Working image exists but has not been customized yet${NC}"
            need_customization=true
        fi
    else
        need_customization=true
    fi

    # Step 3: Create fresh working copy from original if needed
    if [ "$need_customization" = true ]; then
        echo -e "${YELLOW}Creating fresh working copy from original...${NC}"
        ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "cp ${original_path} ${image_path}"
        echo -e "${GREEN}✓ Working copy created${NC}"
    fi

    # Customize the image: install packages and create user
    if [ "$need_customization" = true ]; then
        echo -e "${YELLOW}Customizing image...${NC}"
        echo "  - Running apt update && apt upgrade"
        echo "  - Installing qemu-guest-agent"
        echo "  - Creating user: ${CLOUD_INIT_USER}"
        echo "  - Setting password and sudo access (NOPASSWD)"
        echo "  - Adding SSH public keys from ${SSH_KEYS_FILE}"

        # Check if SSH keys file exists on Proxmox host
        if ! ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f ${SSH_KEYS_FILE}"; then
            echo -e "${RED}ERROR: SSH keys file not found on Proxmox host: ${SSH_KEYS_FILE}${NC}"
            echo "Please ensure the file exists with your public SSH keys"
            exit 1
        fi

        # Generate password hash for virt-customize
        local virt_password_hash=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "openssl passwd -6 '${CLOUD_INIT_PASSWORD}'")

        # Note: qemu-guest-agent is started automatically via udev when the VM runs
        # with the guest agent device enabled - no need to manually enable the service
        ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "virt-customize -a ${image_path} \
            --update \
            --install qemu-guest-agent \
            --run-command 'useradd -m -s /bin/bash ${CLOUD_INIT_USER}' \
            --run-command 'usermod -aG sudo ${CLOUD_INIT_USER}' \
            --password ${CLOUD_INIT_USER}:password:'${virt_password_hash}' \
            --ssh-inject ${CLOUD_INIT_USER}:file:${SSH_KEYS_FILE} \
            --run-command 'chmod 755 /home/${CLOUD_INIT_USER}' \
            --write /etc/sudoers.d/${CLOUD_INIT_USER}:'${CLOUD_INIT_USER} ALL=(ALL) NOPASSWD: ALL' \
            --run-command 'chmod 440 /etc/sudoers.d/${CLOUD_INIT_USER}' \
            --run-command 'apt-get clean' \
            --run-command 'rm -rf /var/lib/apt/lists/*' \
            --selinux-relabel 2>&1 | grep -v '^libguestfs:' || true"

        # Create marker file with timestamp
        ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "date '+%Y-%m-%d %H:%M:%S' > ${marker_file}"

        echo -e "${GREEN}✓ Image customized${NC}"
    else
        echo -e "${CYAN}⊘ Skipping customization (using existing customized image)${NC}"
    fi

    # Create VM with UEFI and q35 machine type
    echo -e "${YELLOW}Creating VM ${vmid}...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm create ${vmid} \
        --name ${template_name} \
        --memory 2048 \
        --cores 2 \
        --net0 virtio,bridge=vmbr0 \
        --scsihw virtio-scsi-pci \
        --bios ovmf \
        --machine q35"
    echo -e "${GREEN}✓ VM created (UEFI/q35)${NC}"

    # Import the disk (this becomes disk-0)
    echo -e "${YELLOW}Importing disk image...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm importdisk ${vmid} ${image_path} ${PROXMOX_STORAGE} --format qcow2"
    echo -e "${GREEN}✓ Disk imported${NC}"

    # Attach the disk to the VM
    echo -e "${YELLOW}Attaching disk to VM...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} --scsi0 ${PROXMOX_STORAGE}:vm-${vmid}-disk-0"
    echo -e "${GREEN}✓ Disk attached${NC}"

    # Add EFI disk for UEFI boot (this becomes disk-1)
    # pre-enrolled-keys=0 disables Secure Boot (needed for NVIDIA drivers)
    echo -e "${YELLOW}Adding EFI disk (Secure Boot disabled)...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} --efidisk0 ${PROXMOX_STORAGE}:1,efitype=4m,pre-enrolled-keys=0"
    echo -e "${GREEN}✓ EFI disk added (Secure Boot disabled)${NC}"

    # Add cloud-init drive
    echo -e "${YELLOW}Adding cloud-init drive...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} --ide2 ${PROXMOX_STORAGE}:cloudinit"
    echo -e "${GREEN}✓ Cloud-init drive added${NC}"

    # Set boot disk
    echo -e "${YELLOW}Configuring boot options...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} --boot c --bootdisk scsi0"
    echo -e "${GREEN}✓ Boot options configured${NC}"

    # Add serial console
    echo -e "${YELLOW}Adding serial console...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} --serial0 socket --vga serial0"
    echo -e "${GREEN}✓ Serial console added${NC}"

    # Enable QEMU guest agent
    echo -e "${YELLOW}Enabling QEMU guest agent...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} --agent enabled=1,fstrim_cloned_disks=1"
    echo -e "${GREEN}✓ QEMU guest agent enabled${NC}"

    # Configure cloud-init settings
    echo -e "${CYAN}Configuring cloud-init settings...${NC}"

    # Generate password hash
    local password_hash=$(ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "openssl passwd -6 '${CLOUD_INIT_PASSWORD}'")

    echo "  - Setting cloud-init user: ${CLOUD_INIT_USER}"
    echo "  - Setting cloud-init password: ${CLOUD_INIT_PASSWORD}"
    echo "  - Copying SSH keys from ${SSH_KEYS_FILE}"
    echo "  - Setting default IP config to DHCP"

    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm set ${vmid} \
        --ciuser ${CLOUD_INIT_USER} \
        --cipassword '${password_hash}' \
        --sshkeys ${SSH_KEYS_FILE} \
        --ipconfig0 ip=dhcp"

    echo -e "${GREEN}✓ Cloud-init configured${NC}"

    # Convert to template
    echo -e "${YELLOW}Converting VM to template...${NC}"
    ssh "${PROXMOX_USER}@${PROXMOX_HOST}" "qm template ${vmid}"
    echo -e "${GREEN}✓ VM converted to template${NC}"

    echo -e "${GREEN}✓✓✓ Template ${vmid} (${template_name}) created successfully!${NC}"
    echo ""
}

# Create Debian 13 template
echo -e "${GREEN}[1/2] Creating Debian 13 template${NC}"
create_template "${TEMPLATE_DEBIAN13_VMID}" "debian-13-cloudinit" "${DEBIAN13_IMAGE_URL}" "13"

# Create Debian 12 template
echo -e "${GREEN}[2/2] Creating Debian 12 template${NC}"
create_template "${TEMPLATE_DEBIAN12_VMID}" "debian-12-cloudinit" "${DEBIAN12_IMAGE_URL}" "12"

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Template Creation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Created templates:"
echo "  • VMID ${TEMPLATE_DEBIAN13_VMID}: debian-13-cloudinit"
echo "  • VMID ${TEMPLATE_DEBIAN12_VMID}: debian-12-cloudinit"
echo ""
echo "Cloud images stored in: ${PROXMOX_IMAGE_DIR}"
echo "  • Original images: *.original.qcow2 (pristine, never modified)"
echo "  • Working images: *.qcow2 (customized copies)"
echo "  • Customization tracked via .customized marker files"
echo "  • Re-customizing uses cached original (no re-download needed)"
echo ""
echo -e "${BLUE}Template specifications:${NC}"
echo "  • BIOS: OVMF (UEFI)"
echo "  • Machine: q35"
echo "  • Memory: 2048 MB (override in Terraform when cloning)"
echo "  • CPU: 2 cores (override in Terraform when cloning)"
echo "  • Disk: ~2GB base image (specify size in Terraform when cloning)"
echo "  • Network: virtio on vmbr0"
echo "  • QEMU Guest Agent: Installed and enabled with fstrim"
echo "  • Cloud-init: Enabled"
echo ""
echo -e "${BLUE}Pre-configured user (baked into image):${NC}"
echo "  • Username: ${CLOUD_INIT_USER}"
echo "  • Password: ${CLOUD_INIT_PASSWORD}"
echo "  • Sudo access: NOPASSWD (passwordless sudo)"
echo "  • SSH keys: Injected from ${SSH_KEYS_FILE}"
echo "  • SSH login: Ready to use immediately"
echo ""
echo -e "${BLUE}Cloud-init configuration (can override user settings):${NC}"
echo "  • Username: ${CLOUD_INIT_USER}"
echo "  • Password: ${CLOUD_INIT_PASSWORD}"
echo "  • SSH Keys: Configured from ${SSH_KEYS_FILE}"
echo "  • IP Config: DHCP (can be overridden in Terraform)"
echo ""
echo -e "${GREEN}Ready to use with Terraform!${NC}"
echo ""
