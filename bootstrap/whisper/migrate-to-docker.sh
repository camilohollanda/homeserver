#!/bin/bash
# Whisper API Migration Script
# Migrates from systemd-based deployment to Docker-based deployment
#
# Usage:
#   ./migrate-to-docker.sh [VM_IP] [GITHUB_OWNER] [GHCR_TOKEN]
#
# Example:
#   ./migrate-to-docker.sh 192.168.20.30 myusername ghp_xxxx

set -e

WHISPER_IP="${1:-192.168.20.30}"
GITHUB_OWNER="${2:-prem-prakash}"
GHCR_TOKEN="${3:-}"
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
echo "   Whisper API Migration to Docker"
echo "=============================================="
echo ""

# Validate inputs
if [ -z "$GITHUB_OWNER" ]; then
    log_error "GITHUB_OWNER is required"
    echo "Usage: $0 <VM_IP> <GITHUB_OWNER> <GHCR_TOKEN>"
    exit 1
fi

if [ -z "$GHCR_TOKEN" ]; then
    log_error "GHCR_TOKEN is required (GitHub PAT with packages:read scope)"
    echo "Usage: $0 <VM_IP> <GITHUB_OWNER> <GHCR_TOKEN>"
    exit 1
fi

log_info "Target VM: $WHISPER_IP"
log_info "GitHub Owner: $GITHUB_OWNER"
log_info "SSH User: $SSH_USER"
echo ""

# Check SSH connectivity
log_info "Checking SSH connectivity..."
if ! ssh_cmd "echo 'SSH connection successful'" 2>/dev/null; then
    log_error "Cannot connect to $WHISPER_IP"
    exit 1
fi
log_success "SSH connection established"

# Check if Docker is already installed
log_info "Checking Docker installation..."
if ssh_cmd "docker --version" 2>/dev/null; then
    log_success "Docker is already installed"
else
    log_info "Installing Docker from official repository..."
    ssh_cmd << 'EOF'
# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to apt sources
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker whisper
EOF
    log_success "Docker installed"
fi

# Check NVIDIA Container Toolkit
log_info "Checking NVIDIA Container Toolkit..."
if ssh_cmd "nvidia-ctk --version" 2>/dev/null; then
    log_success "NVIDIA Container Toolkit is already installed"
else
    log_info "Installing NVIDIA Container Toolkit..."
    ssh_cmd << 'EOF'
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
EOF
    log_success "NVIDIA Container Toolkit installed"
fi

# Stop old systemd service
log_info "Stopping old whisper-api systemd service..."
ssh_cmd "sudo systemctl stop whisper-api 2>/dev/null || true"
ssh_cmd "sudo systemctl disable whisper-api 2>/dev/null || true"
log_success "Old service stopped"

# Setup Docker credentials for GHCR
log_info "Configuring GHCR authentication..."
ssh_cmd "sudo mkdir -p /home/whisper/.docker"
ssh_cmd "echo '{\"auths\":{\"ghcr.io\":{\"auth\":\"'$(echo -n "${GITHUB_OWNER}:${GHCR_TOKEN}" | base64)'\"}}}'  | sudo tee /home/whisper/.docker/config.json > /dev/null"
ssh_cmd "sudo chown -R whisper:whisper /home/whisper/.docker"
ssh_cmd "sudo chmod 600 /home/whisper/.docker/config.json"
log_success "GHCR authentication configured"

# Create docker-compose.yaml
log_info "Creating docker-compose.yaml..."
ssh_cmd "sudo mkdir -p /opt/whisper"
ssh_cmd "sudo tee /opt/whisper/docker-compose.yaml > /dev/null" << EOF
services:
  whisper-api:
    image: ghcr.io/${GITHUB_OWNER}/whisper-api:latest
    container_name: whisper-api
    restart: unless-stopped
    ports:
      - "127.0.0.1:8000:8000"
    volumes:
      - whisper-cache:/app/.cache
    environment:
      - WHISPER_MODEL=turbo
      - WHISPER_DEVICE=cuda
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  watchtower:
    image: nickfedor/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /home/whisper/.docker/config.json:/config.json:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=300
      - WATCHTOWER_INCLUDE_STOPPED=false
      - DOCKER_CONFIG=/
    command: whisper-api

volumes:
  whisper-cache:
EOF
ssh_cmd "sudo chown -R whisper:whisper /opt/whisper"
log_success "docker-compose.yaml created"

# Pull and start containers
log_info "Pulling Docker images..."
ssh_cmd "cd /opt/whisper && sudo -u whisper docker compose pull"
log_success "Images pulled"

log_info "Starting containers..."
ssh_cmd "cd /opt/whisper && sudo -u whisper docker compose up -d"
log_success "Containers started"

# Wait for API to be ready (first run downloads ~1.5GB model, may take several minutes)
log_info "Waiting for API to be ready (first run downloads model, may take 3-5 minutes)..."
for i in {1..90}; do
    if ssh_cmd "curl -s http://localhost:8000/health" 2>/dev/null | grep -q "healthy"; then
        break
    fi
    sleep 5
done

# Verify
echo ""
if ssh_cmd "curl -s http://localhost:8000/health" 2>/dev/null | grep -q "healthy"; then
    log_success "Migration complete! Whisper API is running in Docker."
    echo ""
    echo "=============================================="
    echo "   Migration Complete!"
    echo "=============================================="
    echo ""
    log_info "API endpoint: http://$WHISPER_IP:8000"
    log_info "Health check: curl http://$WHISPER_IP:8000/health"
    log_info "Queue status: curl http://$WHISPER_IP:8000/queue/status"
    echo ""
    log_info "Useful commands:"
    echo "  # View logs"
    echo "  ssh $SSH_USER@$WHISPER_IP 'cd /opt/whisper && docker compose logs -f whisper-api'"
    echo ""
    echo "  # Restart API"
    echo "  ssh $SSH_USER@$WHISPER_IP 'cd /opt/whisper && docker compose restart whisper-api'"
    echo ""
    echo "  # Manual update"
    echo "  ssh $SSH_USER@$WHISPER_IP 'cd /opt/whisper && docker compose pull && docker compose up -d'"
    echo ""
else
    log_warn "API not responding yet. First run downloads the model (~1.5GB), which may take several minutes."
    log_info "Check download progress with:"
    echo "  ssh $SSH_USER@$WHISPER_IP 'cd /opt/whisper && docker compose logs -f whisper-api'"
fi
