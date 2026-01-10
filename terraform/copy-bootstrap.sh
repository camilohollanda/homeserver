#!/bin/bash
set -euo pipefail

# Script to copy bootstrap scripts to VMs after Terraform provisioning
# Usage: ./copy-bootstrap.sh [k3s|postgres|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/../bootstrap" && pwd)"
TARGET="${1:-all}"

# Get VM IPs from Terraform output
echo "Getting VM IPs from Terraform..."
K3S_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw k3s_vm_ip 2>/dev/null || echo "")
DB_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw db_vm_ip 2>/dev/null || echo "")

if [ -z "$K3S_IP" ] || [ -z "$DB_IP" ]; then
  echo "Error: Could not get VM IPs from Terraform output."
  echo "Make sure you've run 'terraform apply' and the VMs are created."
  exit 1
fi

# Get SSH user from Terraform variables (default: deployer)
SSH_USER="${TF_VAR_cloud_init_user:-deployer}"

echo "K3s VM IP: $K3S_IP"
echo "Postgres VM IP: $DB_IP"
echo "SSH User: $SSH_USER"
echo ""

# Function to copy bootstrap scripts to a VM
copy_to_vm() {
  local VM_IP=$1
  local VM_NAME=$2
  local SCRIPTS_TO_COPY=$3

  echo "Copying bootstrap scripts to $VM_NAME ($VM_IP)..."

  # Create bootstrap directory on remote VM
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${VM_IP}" "mkdir -p ~/bootstrap"

  # Copy scripts
  for script in $SCRIPTS_TO_COPY; do
    if [ -f "${BOOTSTRAP_DIR}/${script}" ]; then
      echo "  Copying ${script}..."
      scp -o StrictHostKeyChecking=no "${BOOTSTRAP_DIR}/${script}" "${SSH_USER}@${VM_IP}:~/bootstrap/"
    else
      echo "  Warning: ${script} not found, skipping..."
    fi
  done

  # Make scripts executable
  echo "  Making scripts executable..."
  ssh -o StrictHostKeyChecking=no "${SSH_USER}@${VM_IP}" "chmod +x ~/bootstrap/*.sh"

  echo "  ✓ Bootstrap scripts copied to $VM_NAME"
  echo ""
}

# Copy based on target
case "$TARGET" in
  k3s)
    copy_to_vm "$K3S_IP" "k3s-apps" "k3s-install.sh ingress-nginx-install.sh argocd-install.sh cloudflared-install.sh cloudflared-config.sh bootstrap.sh"
    echo "Next steps for k3s-apps VM:"
    echo "  ssh ${SSH_USER}@${K3S_IP}"
    echo "  sudo ~/bootstrap/bootstrap.sh"
    ;;
  postgres)
    copy_to_vm "$DB_IP" "db-postgres" "postgres-install.sh"
    echo "Next steps for db-postgres VM:"
    echo "  ssh ${SSH_USER}@${DB_IP}"
    echo "  sudo ~/bootstrap/postgres-install.sh"
    echo "  # Or with specific version: POSTGRES_VERSION=15 sudo ~/bootstrap/postgres-install.sh"
    ;;
  all)
    copy_to_vm "$K3S_IP" "k3s-apps" "k3s-install.sh ingress-nginx-install.sh argocd-install.sh cloudflared-install.sh cloudflared-config.sh bootstrap.sh"
    copy_to_vm "$DB_IP" "db-postgres" "postgres-install.sh"
    echo "✓ All bootstrap scripts copied!"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Bootstrap K3s cluster:"
    echo "   ssh ${SSH_USER}@${K3S_IP}"
    echo "   sudo ~/bootstrap/bootstrap.sh"
    echo ""
    echo "2. Setup Postgres database:"
    echo "   ssh ${SSH_USER}@${DB_IP}"
    echo "   sudo ~/bootstrap/postgres-install.sh"
    echo "   # Or with specific version: POSTGRES_VERSION=15 sudo ~/bootstrap/postgres-install.sh"
    ;;
  *)
    echo "Usage: $0 [k3s|postgres|all]"
    echo ""
    echo "  k3s      - Copy scripts to k3s-apps VM only"
    echo "  postgres - Copy scripts to db-postgres VM only"
    echo "  all      - Copy scripts to both VMs (default)"
    exit 1
    ;;
esac
