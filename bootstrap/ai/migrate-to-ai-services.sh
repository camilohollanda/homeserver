#!/bin/bash
# AI Services Migration Script
# Migrates existing Whisper VM to AI Services (Whisper + Ollama)
#
# Usage:
#   ./migrate-to-ai-services.sh [VM_IP] [GITHUB_OWNER] [GHCR_TOKEN] [NEW_DOMAIN]
#
# Example:
#   ./migrate-to-ai-services.sh 192.168.20.30 myusername ghp_xxxx ai.internal.example.com

set -e

VM_IP="${1:-192.168.20.30}"
GITHUB_OWNER="${2:-prem-prakash}"
GHCR_TOKEN="${3:-}"
NEW_DOMAIN="${4:-ai.internal.prakash.com.br}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"
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
    ssh $SSH_OPTS "$SSH_USER@$VM_IP" "$@"
}

echo ""
echo "=============================================="
echo "   AI Services Migration"
echo "   Whisper + Ollama"
echo "=============================================="
echo ""

# Validate inputs
if [ -z "$GITHUB_OWNER" ]; then
    log_error "GITHUB_OWNER is required"
    echo "Usage: $0 <VM_IP> <GITHUB_OWNER> <GHCR_TOKEN> <NEW_DOMAIN>"
    exit 1
fi

if [ -z "$GHCR_TOKEN" ]; then
    log_error "GHCR_TOKEN is required (GitHub PAT with packages:read scope)"
    echo "Usage: $0 <VM_IP> <GITHUB_OWNER> <GHCR_TOKEN> <NEW_DOMAIN>"
    exit 1
fi

log_info "Target VM: $VM_IP"
log_info "GitHub Owner: $GITHUB_OWNER"
log_info "New Domain: $NEW_DOMAIN"
log_info "Ollama Model: $OLLAMA_MODEL"
log_info "SSH User: $SSH_USER"
echo ""

# Check SSH connectivity
log_info "Checking SSH connectivity..."
if ! ssh_cmd "echo 'SSH connection successful'" 2>/dev/null; then
    log_error "Cannot connect to $VM_IP"
    exit 1
fi
log_success "SSH connection established"

# Check if Docker is installed
log_info "Checking Docker installation..."
if ! ssh_cmd "docker --version" 2>/dev/null; then
    log_error "Docker is not installed. Run the initial setup first."
    exit 1
fi
log_success "Docker is installed"

# Check NVIDIA Container Toolkit
log_info "Checking NVIDIA Container Toolkit..."
if ! ssh_cmd "nvidia-ctk --version" 2>/dev/null; then
    log_error "NVIDIA Container Toolkit not installed. Run the initial setup first."
    exit 1
fi
log_success "NVIDIA Container Toolkit is installed"

# Create AI user if not exists
log_info "Setting up 'ai' user..."
ssh_cmd << 'EOF'
if ! id -u ai &>/dev/null; then
    sudo useradd -m -s /bin/bash -G sudo,video,render,docker ai
    echo "ai ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/ai
fi
EOF
log_success "User 'ai' configured"

# Stop existing whisper containers (if any)
log_info "Stopping existing Whisper containers..."
ssh_cmd "cd /opt/whisper 2>/dev/null && sudo docker compose down || true"
log_success "Existing containers stopped"

# Create directory structure
log_info "Creating directory structure..."
ssh_cmd << 'EOF'
sudo mkdir -p /opt/ai
sudo chown -R ai:ai /opt/ai
EOF
log_success "Directories created"

# Setup GHCR authentication
log_info "Configuring GHCR authentication..."
ssh_cmd "sudo mkdir -p /home/ai/.docker"
ssh_cmd "echo '{\"auths\":{\"ghcr.io\":{\"auth\":\"'$(echo -n "${GITHUB_OWNER}:${GHCR_TOKEN}" | base64)'\"}}}'  | sudo tee /home/ai/.docker/config.json > /dev/null"
ssh_cmd "sudo chown -R ai:ai /home/ai/.docker"
ssh_cmd "sudo chmod 600 /home/ai/.docker/config.json"
log_success "GHCR authentication configured"

# Create docker-compose.yaml
log_info "Creating docker-compose.yaml..."
ssh_cmd "sudo tee /opt/ai/docker-compose.yaml > /dev/null" << EOF
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
      - XDG_CACHE_HOME=/app/.cache
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

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "127.0.0.1:11434:11434"
    volumes:
      - ollama-data:/root/.ollama
    environment:
      - OLLAMA_KEEP_ALIVE=5m
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
      - /home/ai/.docker/config.json:/config.json:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=300
      - WATCHTOWER_INCLUDE_STOPPED=false
      - DOCKER_CONFIG=/
    command: whisper-api ollama

volumes:
  whisper-cache:
  ollama-data:
EOF
ssh_cmd "sudo chown -R ai:ai /opt/ai"
log_success "docker-compose.yaml created"

# Update nginx configuration
log_info "Updating nginx configuration..."
ssh_cmd "sudo tee /etc/nginx/sites-available/ai > /dev/null" << EOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${NEW_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${NEW_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${NEW_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 100M;

    # Health check endpoint
    location = /health {
        proxy_pass http://127.0.0.1:8000/health;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Whisper transcription endpoints
    location /transcribe {
        proxy_pass http://127.0.0.1:8000/transcribe;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 600s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # Ollama generate endpoint (for custom prompts)
    location /generate {
        proxy_pass http://127.0.0.1:11434/api/generate;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 300s;
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
    }

    # Ollama chat endpoint (OpenAI-compatible)
    location /v1/chat/completions {
        proxy_pass http://127.0.0.1:11434/v1/chat/completions;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    # Ollama API (full access)
    location /api/ {
        proxy_pass http://127.0.0.1:11434/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    # Queue status (whisper)
    location /queue {
        proxy_pass http://127.0.0.1:8000/queue;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # Swagger docs for whisper
    location /docs {
        proxy_pass http://127.0.0.1:8000/docs;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /openapi.json {
        proxy_pass http://127.0.0.1:8000/openapi.json;
        proxy_set_header Host \$host;
    }

    # Root shows service info
    location = / {
        default_type application/json;
        return 200 '{"service":"AI Services","endpoints":{"/transcribe":"Speech-to-text (Whisper)","/generate":"Text generation (Ollama)","/v1/chat/completions":"OpenAI-compatible chat","/api/":"Full Ollama API","/health":"Health check","/docs":"Whisper API docs"}}';
    }
}
EOF
log_success "Nginx configuration updated"

# Get new SSL certificate if needed
log_info "Checking SSL certificate for ${NEW_DOMAIN}..."
if ! ssh_cmd "test -f /etc/letsencrypt/live/${NEW_DOMAIN}/fullchain.pem" 2>/dev/null; then
    log_info "Obtaining new SSL certificate..."
    ssh_cmd << EOF
sudo certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d ${NEW_DOMAIN} \
    --non-interactive \
    --agree-tos \
    --expand
EOF
    log_success "SSL certificate obtained"
else
    log_success "SSL certificate already exists"
fi

# Enable nginx site
log_info "Enabling nginx site..."
ssh_cmd << EOF
sudo rm -f /etc/nginx/sites-enabled/whisper
sudo ln -sf /etc/nginx/sites-available/ai /etc/nginx/sites-enabled/ai
sudo nginx -t && sudo systemctl reload nginx
EOF
log_success "Nginx configured"

log_info "Pulling Docker images..."
ssh_cmd "cd /opt/ai && sudo -u ai docker compose pull"
log_success "Images pulled"

log_info "Starting containers..."
ssh_cmd "cd /opt/ai && sudo -u ai docker compose up -d"
log_success "Containers started"

# Pull Ollama model
log_info "Pulling Ollama model (${OLLAMA_MODEL})..."
log_info "This may take a few minutes for the first download..."
for i in {1..30}; do
    if ssh_cmd "curl -s http://localhost:11434/api/tags > /dev/null 2>&1"; then
        break
    fi
    echo "Waiting for Ollama to be ready... ($i/30)"
    sleep 5
done

ssh_cmd "curl -X POST http://localhost:11434/api/pull -d '{\"name\": \"${OLLAMA_MODEL}\"}' --no-buffer"
log_success "Ollama model pulled"

# Wait for services to be ready
log_info "Waiting for services to be ready..."
for i in {1..60}; do
    WHISPER_OK=$(ssh_cmd "curl -s http://localhost:8000/health" 2>/dev/null | grep -q "healthy" && echo "yes" || echo "no")
    OLLAMA_OK=$(ssh_cmd "curl -s http://localhost:11434/api/tags" 2>/dev/null | grep -q "${OLLAMA_MODEL}" && echo "yes" || echo "no")

    if [ "$WHISPER_OK" = "yes" ] && [ "$OLLAMA_OK" = "yes" ]; then
        break
    fi
    echo "Waiting... ($i/60) - Whisper: $WHISPER_OK, Ollama: $OLLAMA_OK"
    sleep 5
done

# Update promtail config for new container names
log_info "Updating Promtail configuration..."
ssh_cmd << 'EOF'
if [ -f /etc/promtail/config.yaml ]; then
    sudo sed -i "s/'\/\(whisper-api|watchtower\)'/'\/\(whisper-api|ollama|watchtower\)'/g" /etc/promtail/config.yaml
    sudo sed -i 's/host: whisper-gpu/host: ai-gpu/g' /etc/promtail/config.yaml
    sudo systemctl restart promtail || true
fi
EOF
log_success "Promtail updated"

# Verify
echo ""
WHISPER_OK=$(ssh_cmd "curl -s http://localhost:8000/health" 2>/dev/null | grep -q "healthy" && echo "yes" || echo "no")
OLLAMA_OK=$(ssh_cmd "curl -s http://localhost:11434/api/tags" 2>/dev/null | grep -q "${OLLAMA_MODEL}" && echo "yes" || echo "no")

if [ "$WHISPER_OK" = "yes" ] && [ "$OLLAMA_OK" = "yes" ]; then
    echo ""
    echo "=============================================="
    echo "   Migration Complete!"
    echo "=============================================="
    echo ""
    log_success "All services are running!"
    echo ""
    echo "Status:"
    echo "  - Whisper API: $WHISPER_OK"
    echo "  - Ollama:      $OLLAMA_OK"
    echo ""
    echo "Endpoints:"
    echo "  - Base URL:      https://${NEW_DOMAIN}"
    echo "  - Transcription: POST https://${NEW_DOMAIN}/transcribe"
    echo "  - Generate:      POST https://${NEW_DOMAIN}/generate"
    echo "  - Chat:          POST https://${NEW_DOMAIN}/v1/chat/completions"
    echo "  - Ollama API:    https://${NEW_DOMAIN}/api/"
    echo "  - Health:        GET  https://${NEW_DOMAIN}/health"
    echo ""
    echo "Example - Generate text (translation):"
    echo "  curl -X POST https://${NEW_DOMAIN}/generate \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\": \"${OLLAMA_MODEL}\", \"prompt\": \"Translate to Brazilian Portuguese: Hello, how are you?\", \"stream\": false}'"
    echo ""
    echo "Example - OpenAI-compatible chat:"
    echo "  curl -X POST https://${NEW_DOMAIN}/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\": \"${OLLAMA_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Translate to Portuguese: Hello world\"}]}'"
    echo ""
    echo "Example - Transcribe audio:"
    echo "  curl -X POST https://${NEW_DOMAIN}/transcribe -F 'file=@audio.mp3'"
    echo ""
    echo "Useful commands:"
    echo "  # View all logs"
    echo "  ssh $SSH_USER@$VM_IP 'cd /opt/ai && docker compose logs -f'"
    echo ""
    echo "  # Restart services"
    echo "  ssh $SSH_USER@$VM_IP 'cd /opt/ai && docker compose restart'"
    echo ""
else
    log_warn "Some services are not ready yet."
    echo ""
    echo "Status:"
    echo "  - Whisper API: $WHISPER_OK"
    echo "  - Ollama:      $OLLAMA_OK"
    echo ""
    log_info "Check logs with:"
    echo "  ssh $SSH_USER@$VM_IP 'cd /opt/ai && docker compose logs -f'"
fi
