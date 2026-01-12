#!/bin/bash
set -euo pipefail

# Script to copy bootstrap scripts to VMs after Terraform provisioning
# Usage: ./copy-bootstrap.sh [k3s|postgres|infisical|whisper|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/../bootstrap" && pwd)"
TARGET="${1:-all}"

# Get VM IPs from Terraform output
echo "Getting VM IPs from Terraform..."
K3S_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw k3s_vm_ip 2>/dev/null || echo "")
DB_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw db_vm_ip 2>/dev/null || echo "")
INFISICAL_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw infisical_vm_ip 2>/dev/null || echo "")
WHISPER_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw whisper_vm_ip 2>/dev/null || echo "")

if [ -z "$K3S_IP" ] || [ -z "$DB_IP" ]; then
  echo "Error: Could not get VM IPs from Terraform output."
  echo "Make sure you've run 'terraform apply' and the VMs are created."
  exit 1
fi

# Get SSH user from Terraform variables (default: deployer)
SSH_USER="${TF_VAR_cloud_init_user:-deployer}"

echo "K3s VM IP: $K3S_IP"
echo "Postgres VM IP: $DB_IP"
echo "Infisical VM IP: $INFISICAL_IP"
echo "Whisper VM IP: $WHISPER_IP"
echo "SSH User: $SSH_USER"
echo ""

# Function to copy a directory of bootstrap scripts to a VM
copy_dir_to_vm() {
  local VM_IP=$1
  local VM_NAME=$2
  local SOURCE_DIR=$3

  echo "Copying bootstrap scripts to $VM_NAME ($VM_IP)..."

  # Create bootstrap directory on remote VM
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${VM_IP}" "sudo mkdir -p /opt/bootstrap && sudo chown ${SSH_USER}:${SSH_USER} /opt/bootstrap"

  # Copy all files from source directory
  echo "  Copying from ${SOURCE_DIR}..."
  scp -o StrictHostKeyChecking=no -r "${SOURCE_DIR}"/* "${SSH_USER}@${VM_IP}:/opt/bootstrap/"

  # Make scripts executable
  echo "  Making scripts executable..."
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${VM_IP}" "chmod +x /opt/bootstrap/*.sh 2>/dev/null || true"

  echo "  ✓ Bootstrap scripts copied to $VM_NAME at /opt/bootstrap/"
  echo ""
}

# Copy based on target
case "$TARGET" in
  k3s)
    copy_dir_to_vm "$K3S_IP" "k3s-apps" "${BOOTSTRAP_DIR}/k3s"
    echo "Next steps for k3s-apps VM:"
    echo "  ssh ${SSH_USER}@${K3S_IP}"
    echo "  sudo /opt/bootstrap/bootstrap.sh"
    ;;
  postgres)
    copy_dir_to_vm "$DB_IP" "db-postgres" "${BOOTSTRAP_DIR}/postgres"
    echo "Next steps for db-postgres VM:"
    echo "  ssh ${SSH_USER}@${DB_IP}"
    echo "  sudo /opt/bootstrap/install.sh"
    ;;
  infisical)
    if [ -z "$INFISICAL_IP" ]; then
      echo "Error: Infisical VM IP not found. Make sure you've applied the Terraform config."
      exit 1
    fi
    copy_dir_to_vm "$INFISICAL_IP" "infisical" "${BOOTSTRAP_DIR}/infisical"
    echo "Infisical VM uses cloud-init for bootstrap (Docker + docker-compose)."
    echo "The db-setup.sh script is for creating the database on the postgres VM."
    echo ""
    echo "To setup Infisical database (run on db-postgres VM):"
    echo "  ssh ${SSH_USER}@${DB_IP}"
    echo "  /opt/bootstrap/db-setup.sh infisical infisical 'your-password'"
    echo ""
    echo "Access Infisical at: https://${INFISICAL_IP}:8443"
    ;;
  whisper)
    if [ -z "$WHISPER_IP" ]; then
      echo "Error: Whisper VM IP not found. Make sure you've applied the Terraform config."
      exit 1
    fi
    copy_dir_to_vm "$WHISPER_IP" "whisper-gpu" "${BOOTSTRAP_DIR}/whisper"
    echo "Next steps for whisper-gpu VM:"
    echo "  ssh ${SSH_USER}@${WHISPER_IP}"
    echo "  sudo /opt/bootstrap/setup.sh"
    echo ""
    echo "After setup, access the API at: http://${WHISPER_IP}:8000"
    ;;
  all)
    copy_dir_to_vm "$K3S_IP" "k3s-apps" "${BOOTSTRAP_DIR}/k3s"
    copy_dir_to_vm "$DB_IP" "db-postgres" "${BOOTSTRAP_DIR}/postgres"
    if [ -n "$INFISICAL_IP" ]; then
      # Copy infisical db-setup to postgres VM as well
      scp -o StrictHostKeyChecking=no "${BOOTSTRAP_DIR}/infisical/db-setup.sh" "${SSH_USER}@${DB_IP}:/opt/bootstrap/"
    fi
    if [ -n "$WHISPER_IP" ]; then
      copy_dir_to_vm "$WHISPER_IP" "whisper-gpu" "${BOOTSTRAP_DIR}/whisper"
    fi
    echo "✓ All bootstrap scripts copied!"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Bootstrap K3s cluster:"
    echo "   ssh ${SSH_USER}@${K3S_IP}"
    echo "   sudo /opt/bootstrap/bootstrap.sh"
    echo ""
    echo "2. Setup Postgres database:"
    echo "   ssh ${SSH_USER}@${DB_IP}"
    echo "   sudo /opt/bootstrap/install.sh"
    echo ""
    echo "3. Setup Infisical database (on db-postgres VM):"
    echo "   /opt/bootstrap/db-setup.sh infisical infisical 'your-password'"
    echo ""
    echo "4. Access Infisical (after VM boots):"
    echo "   https://${INFISICAL_IP:-192.168.20.22}:8443"
    echo ""
    if [ -n "$WHISPER_IP" ]; then
    echo "5. Setup Whisper GPU:"
    echo "   ssh ${SSH_USER}@${WHISPER_IP}"
    echo "   sudo /opt/bootstrap/setup.sh"
    echo ""
    fi
    ;;
  *)
    echo "Usage: $0 [k3s|postgres|infisical|whisper|all]"
    echo ""
    echo "  k3s       - Copy scripts to k3s-apps VM"
    echo "  postgres  - Copy scripts to db-postgres VM"
    echo "  infisical - Copy scripts and show Infisical setup commands"
    echo "  whisper   - Copy scripts to whisper-gpu VM"
    echo "  all       - Copy scripts to all VMs (default)"
    exit 1
    ;;
esac
