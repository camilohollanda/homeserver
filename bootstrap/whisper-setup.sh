#!/bin/bash
# Whisper GPU Server Bootstrap Script
#
# This script sets up the whisper-gpu VM with NVIDIA drivers and faster-whisper.
# Run this after the VM is created by Terraform.
#
# Usage:
#   ./whisper-setup.sh [VM_IP]
#
# Example:
#   ./whisper-setup.sh 192.168.20.30

set -e

WHISPER_IP="${1:-192.168.20.30}"
SSH_USER="${SSH_USER:-deployer}"
SSH_KEY="${SSH_KEY:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
if [ -n "$SSH_KEY" ]; then
    SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
fi

ssh_cmd() {
    ssh $SSH_OPTS "$SSH_USER@$WHISPER_IP" "$@"
}

echo ""
echo "=============================================="
echo "   Whisper GPU Server Setup"
echo "=============================================="
echo ""
log_info "Target VM: $WHISPER_IP"
log_info "SSH User: $SSH_USER"
echo ""

# Check SSH connectivity
log_info "Checking SSH connectivity..."
if ! ssh_cmd "echo 'SSH connection successful'" 2>/dev/null; then
    log_error "Cannot connect to $WHISPER_IP"
    log_info "Make sure:"
    log_info "  1. The VM is running (check Proxmox)"
    log_info "  2. Your SSH key is authorized"
    log_info "  3. The IP address is correct"
    exit 1
fi
log_success "SSH connection established"

# Check if already set up and actually responding
if ssh_cmd "curl -s --connect-timeout 2 http://localhost:8000/health" 2>/dev/null | grep -q "healthy"; then
    log_success "Whisper API is already running and healthy!"
    echo ""
    log_info "API endpoint: http://$WHISPER_IP:8000"
    log_info "Health check: curl http://$WHISPER_IP:8000/health"
    exit 0
fi

# Check if NVIDIA driver is installed
log_info "Checking NVIDIA driver status..."
if ssh_cmd "nvidia-smi" 2>/dev/null; then
    log_success "NVIDIA driver is installed"

    # Run post-reboot setup
    log_info "Running post-reboot setup..."
    ssh_cmd "sudo /opt/whisper/post-reboot.sh"
else
    log_warn "NVIDIA driver not installed"

    # Run full setup (will trigger reboot)
    log_info "Starting full setup (will reboot the VM)..."
    echo ""
    log_warn "The VM will reboot after driver installation."
    log_warn "After reboot, run this script again to complete setup."
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi

    ssh_cmd "sudo /opt/whisper/setup.sh" || true

    echo ""
    log_info "VM is rebooting..."
    log_info "Wait 2-3 minutes, then run this script again to complete setup."
    exit 0
fi

# Verify setup
echo ""
log_info "Verifying setup..."
sleep 5

if ssh_cmd "curl -s http://localhost:8000/health" 2>/dev/null | grep -q "healthy"; then
    log_success "Whisper API is running!"
    echo ""
    echo "=============================================="
    echo "   Setup Complete!"
    echo "=============================================="
    echo ""
    log_info "API endpoint: http://$WHISPER_IP:8000"
    echo ""
    log_info "Test commands:"
    echo "  # Health check"
    echo "  curl http://$WHISPER_IP:8000/health"
    echo ""
    echo "  # Transcribe audio file"
    echo "  curl -X POST http://$WHISPER_IP:8000/transcribe \\"
    echo "    -F 'file=@your-audio.mp3'"
    echo ""
    echo "  # Transcribe with options"
    echo "  curl -X POST 'http://$WHISPER_IP:8000/transcribe?language=en&include_segments=true' \\"
    echo "    -F 'file=@your-audio.mp3'"
    echo ""
else
    log_warn "API not responding yet. It may still be loading the model."
    log_info "Check status with: ssh $SSH_USER@$WHISPER_IP 'sudo journalctl -u whisper-api -f'"
fi
