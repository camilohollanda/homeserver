#!/bin/bash
set -euo pipefail

# Script to copy bootstrap scripts to VMs after Terraform provisioning
# Usage: ./copy-bootstrap.sh [k3s|postgres|infisical|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_DIR="$(cd "${SCRIPT_DIR}/../bootstrap" && pwd)"
TARGET="${1:-all}"

# Get VM IPs from Terraform output
echo "Getting VM IPs from Terraform..."
K3S_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw k3s_vm_ip 2>/dev/null || echo "")
DB_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw db_vm_ip 2>/dev/null || echo "")
INFISICAL_IP=$(terraform -chdir="${SCRIPT_DIR}" output -raw infisical_vm_ip 2>/dev/null || echo "")

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
    copy_to_vm "$K3S_IP" "k3s-apps" "k3s-install.sh ingress-nginx-install.sh argocd-install.sh argocd-github-setup.sh cloudflared-install.sh cloudflared-config.sh external-secrets-install.sh bootstrap.sh"
    echo "Next steps for k3s-apps VM:"
    echo "  ssh ${SSH_USER}@${K3S_IP}"
    echo "  sudo ~/bootstrap/bootstrap.sh"
    echo ""
    echo "  # To install External Secrets Operator (for Infisical integration):"
    echo "  ~/bootstrap/external-secrets-install.sh"
    ;;
  postgres)
    copy_to_vm "$DB_IP" "db-postgres" "postgres-install.sh infisical-db-setup.sh"
    echo "Next steps for db-postgres VM:"
    echo "  ssh ${SSH_USER}@${DB_IP}"
    echo "  sudo ~/bootstrap/postgres-install.sh"
    echo "  # Or with specific version: POSTGRES_VERSION=15 sudo ~/bootstrap/postgres-install.sh"
    echo ""
    echo "  # If setting up Infisical, also run:"
    echo "  ~/bootstrap/infisical-db-setup.sh infisical infisical 'your-password'"
    ;;
  infisical)
    if [ -z "$INFISICAL_IP" ]; then
      echo "Error: Infisical VM IP not found. Make sure you've applied the Terraform config."
      exit 1
    fi
    echo "Infisical VM uses cloud-init for bootstrap (Docker + docker-compose)."
    echo "No additional scripts need to be copied."
    echo ""
    echo "Access Infisical at: https://${INFISICAL_IP}:8443"
    echo ""
    echo "To check status:"
    echo "  ssh ${SSH_USER}@${INFISICAL_IP}"
    echo "  sudo docker compose -f /opt/infisical/docker-compose.yml ps"
    echo "  sudo docker compose -f /opt/infisical/docker-compose.yml logs -f"
    ;;
  all)
    copy_to_vm "$K3S_IP" "k3s-apps" "k3s-install.sh ingress-nginx-install.sh argocd-install.sh argocd-github-setup.sh cloudflared-install.sh cloudflared-config.sh external-secrets-install.sh bootstrap.sh"
    copy_to_vm "$DB_IP" "db-postgres" "postgres-install.sh infisical-db-setup.sh"
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
    echo ""
    echo "3. Setup Infisical database (on db-postgres VM):"
    echo "   ~/bootstrap/infisical-db-setup.sh infisical infisical 'your-password'"
    echo ""
    echo "4. Access Infisical (after VM boots, ~3-5 min):"
    echo "   https://${INFISICAL_IP:-192.168.20.22}:8443"
    echo ""
    echo "5. Install External Secrets Operator (on k3s VM):"
    echo "   ssh ${SSH_USER}@${K3S_IP}"
    echo "   ~/bootstrap/external-secrets-install.sh"
    ;;
  *)
    echo "Usage: $0 [k3s|postgres|infisical|all]"
    echo ""
    echo "  k3s       - Copy scripts to k3s-apps VM only"
    echo "  postgres  - Copy scripts to db-postgres VM only"
    echo "  infisical - Show Infisical VM status commands"
    echo "  all       - Copy scripts to all VMs (default)"
    exit 1
    ;;
esac
