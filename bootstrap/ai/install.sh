#!/usr/bin/env bash
# Runs on the AI/GPU VM as root.
# Remote: REMOTE_HOST=deployer@192.168.20.30 ./install.sh
#
# Required env vars:
#   CF_API_TOKEN      - Cloudflare API token (Zone.DNS Edit)
#   AI_DOMAIN         - FQDN for AI services (e.g. ai.internal.prakash.com.br)
#   LETSENCRYPT_EMAIL - Email for Let's Encrypt
#   GITHUB_OWNER      - GitHub username owning the whisper-api image
#   GHCR_USERNAME     - GitHub username for GHCR auth
#   GHCR_TOKEN        - GitHub personal access token with packages:read
#   OLLAMA_MODEL      - Ollama model to pre-pull (e.g. qwen2.5:3b)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      CF_API_TOKEN      "${CF_API_TOKEN:-}" \
      AI_DOMAIN         "${AI_DOMAIN:-}" \
      LETSENCRYPT_EMAIL "${LETSENCRYPT_EMAIL:-}" \
      GITHUB_OWNER      "${GITHUB_OWNER:-}" \
      GHCR_USERNAME     "${GHCR_USERNAME:-}" \
      GHCR_TOKEN        "${GHCR_TOKEN:-}" \
      OLLAMA_MODEL      "${OLLAMA_MODEL:-qwen2.5:3b}" \
      OLLAMA_VERSION    "${OLLAMA_VERSION:-latest}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"

# Tracks :latest again as of 2026-08-06. This REQUIRES NVIDIA driver 570+.
#
# Ollama 0.30.0 added discover/cuda_compat.go, which refuses compute < 7 GPUs on
# old drivers (570+ for the CUDA 12.8 builds it ships) and falls back to 100% CPU
# *silently* — no error, just ~2x slower generation and ~23x slower prompt eval.
# The Quadro M4000 is compute 5.2, so this VM ran on CPU unnoticed until the
# driver was moved off Debian's 535 to 580.178.04 from NVIDIA's CUDA repo.
# See terraform/create-nvidia-template.sh, which now bakes 580 into the template.
#
# If this VM is ever rebuilt on a 535 image, ollama will go back to CPU without
# complaining. Check with: docker exec ollama ollama ps  (PROCESSOR != 100% CPU)
OLLAMA_VERSION="${OLLAMA_VERSION:-latest}"

echo "==> Installing base dependencies..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg wget htop unzip nginx \
  certbot python3-certbot-dns-cloudflare

# ---------------------------------------------------------------------------
# Docker CE
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing Docker CE..."

if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  # Ensure ai user exists and has docker/gpu access
  id ai &>/dev/null || useradd -m -G sudo,video,render -s /bin/bash ai
  usermod -aG docker ai
  systemctl enable docker
  systemctl start docker
else
  echo "  Docker already installed — skipping."
fi

# ---------------------------------------------------------------------------
# NVIDIA Container Toolkit
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing NVIDIA Container Toolkit..."

if ! command -v nvidia-ctk &>/dev/null; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
else
  echo "  NVIDIA Container Toolkit already installed — skipping."
fi

# ---------------------------------------------------------------------------
# Let's Encrypt certificate
# ---------------------------------------------------------------------------
echo ""
echo "==> Obtaining Let's Encrypt certificate for ${AI_DOMAIN}..."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy

cat > /etc/letsencrypt/cloudflare.ini <<INI
dns_cloudflare_api_token = ${CF_API_TOKEN}
INI
chmod 600 /etc/letsencrypt/cloudflare.ini

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if [ ! -d "/etc/letsencrypt/live/${AI_DOMAIN}" ]; then
  certbot certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    -d "${AI_DOMAIN}" \
    --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}"
else
  echo "  Certificate already exists — skipping."
fi

# ---------------------------------------------------------------------------
# Nginx
# ---------------------------------------------------------------------------
echo ""
echo "==> Configuring nginx..."

cat > /etc/nginx/sites-available/ai <<NGINX
server {
  listen 80;
  server_name ${AI_DOMAIN};
  location / { return 301 https://\$host\$request_uri; }
}

server {
  listen 443 ssl;
  server_name ${AI_DOMAIN};

  ssl_certificate     /etc/letsencrypt/live/${AI_DOMAIN}/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/${AI_DOMAIN}/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  client_max_body_size 100M;

  location = /health {
    proxy_pass http://127.0.0.1:8000/health;
    proxy_set_header Host \$host;
  }

  location /transcribe {
    proxy_pass http://127.0.0.1:8000/transcribe;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout    600s;
    proxy_connect_timeout  60s;
    proxy_send_timeout    600s;
    proxy_buffering off;
    proxy_request_buffering off;
  }

  location /generate {
    proxy_pass http://127.0.0.1:11434/api/generate;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
  }

  location /v1/chat/completions {
    proxy_pass http://127.0.0.1:11434/v1/chat/completions;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
  }

  location /api/ {
    proxy_pass http://127.0.0.1:11434/api/;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
  }

  location /docs        { proxy_pass http://127.0.0.1:8000/docs; proxy_set_header Host \$host; }
  location /openapi.json { proxy_pass http://127.0.0.1:8000/openapi.json; proxy_set_header Host \$host; }
  location /queue       { proxy_pass http://127.0.0.1:8000/queue; proxy_set_header Host \$host; }

  location = / {
    default_type application/json;
    return 200 '{"service":"AI Services","endpoints":{"/transcribe":"Whisper","/generate":"Ollama","/v1/chat/completions":"OpenAI-compat","/health":"healthcheck","/docs":"API docs"}}';
  }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/ai /etc/nginx/sites-enabled/ai
systemctl enable nginx
systemctl reload nginx || systemctl start nginx

# ---------------------------------------------------------------------------
# Docker Compose + GHCR auth
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing AI services configuration..."
mkdir -p /opt/ai
chown -R ai:ai /opt/ai

cat > /opt/ai/docker-compose.yaml <<COMPOSE
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

  ollama:
    image: ollama/ollama:${OLLAMA_VERSION}
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
    command: whisper-api ollama

volumes:
  whisper-cache:
  ollama-data:
COMPOSE
chown ai:ai /opt/ai/docker-compose.yaml

# GHCR authentication
mkdir -p /home/ai/.docker
GHCR_AUTH_B64=$(echo -n "${GHCR_USERNAME}:${GHCR_TOKEN}" | base64 -w0)
cat > /home/ai/.docker/config.json <<JSON
{"auths":{"ghcr.io":{"auth":"${GHCR_AUTH_B64}"}}}
JSON
chown -R ai:ai /home/ai/.docker
chmod 600 /home/ai/.docker/config.json

# ---------------------------------------------------------------------------
# Setup one-shot service (pulls images + pulls ollama model on first boot)
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing ai-setup systemd service..."

cat > /opt/ai/setup.sh <<SETUP
#!/bin/bash
set -euo pipefail
LOG_FILE="/var/log/ai-setup.log"
exec > >(tee -a "\$LOG_FILE") 2>&1

SETUP_COMPLETE="/opt/ai/.setup_complete"
[ -f "\$SETUP_COMPLETE" ] && { echo "Setup already complete."; exit 0; }

echo "=== Checking GPU ==="
if ! nvidia-smi; then
  echo "ERROR: NVIDIA GPU not detected. Check GPU passthrough config."
  exit 1
fi

echo "=== Starting AI containers ==="
cd /opt/ai
sudo -u ai docker compose pull
sudo -u ai docker compose up -d

echo "=== Pulling Ollama model (${OLLAMA_MODEL}) ==="
for i in \$(seq 1 30); do
  curl -s http://localhost:11434/api/tags > /dev/null 2>&1 && break
  echo "Waiting for Ollama... (\$i/30)"
  sleep 5
done
curl -X POST http://localhost:11434/api/pull -d '{"name":"${OLLAMA_MODEL}"}' --no-buffer

echo "=== Waiting for Whisper API ==="
for i in \$(seq 1 60); do
  curl -s http://localhost:8000/health | grep -q "healthy" && break
  echo "Waiting... (\$i/60)"
  sleep 5
done

WHISPER_OK=\$(curl -s http://localhost:8000/health | grep -q "healthy" && echo "yes" || echo "no")
OLLAMA_OK=\$(curl -s http://localhost:11434/api/tags | grep -q "${OLLAMA_MODEL}" && echo "yes" || echo "no")

if [ "\$WHISPER_OK" = "yes" ] && [ "\$OLLAMA_OK" = "yes" ]; then
  touch "\$SETUP_COMPLETE"
  systemctl disable ai-setup.service
  echo "=== Setup complete! Whisper: \$WHISPER_OK, Ollama: \$OLLAMA_OK ==="
else
  echo "ERROR: Services did not start — Whisper: \$WHISPER_OK, Ollama: \$OLLAMA_OK"
  docker compose logs
  exit 1
fi
SETUP
chmod 755 /opt/ai/setup.sh
chown ai:ai /opt/ai/setup.sh

cat > /etc/systemd/system/ai-setup.service <<'SVC'
[Unit]
Description=AI Services First-Boot Setup
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/opt/ai/setup.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Promtail (log shipping to Loki on k3s VM)
# ---------------------------------------------------------------------------
echo ""
echo "==> Installing Promtail..."

if ! command -v promtail &>/dev/null; then
  PROMTAIL_VERSION="3.6.3"
  cd /tmp
  wget -q "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip"
  unzip -o promtail-linux-amd64.zip
  chmod +x promtail-linux-amd64
  mv promtail-linux-amd64 /usr/local/bin/promtail
  rm -f promtail-linux-amd64.zip
fi

mkdir -p /var/lib/promtail /etc/promtail

cat > /etc/promtail/config.yaml <<'PROMTAIL'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://192.168.20.11:31100/loki/api/v1/push

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - target_label: job
        replacement: docker
      - source_labels: ['__meta_docker_container_name']
        regex: '/(.+)'
        target_label: container
      - source_labels: ['__meta_docker_container_name']
        regex: '/(whisper-api|ollama|watchtower)'
        action: keep
    pipeline_stages:
      - json:
          expressions:
            log: log
      - output:
          source: log

  - job_name: system
    journal:
      max_age: 12h
      labels:
        job: system
        host: ai-gpu
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        regex: '(sshd|systemd-.*|nvidia-.*|docker.*)\.service'
        action: keep
PROMTAIL

cat > /etc/systemd/system/promtail.service <<'SVC'
[Unit]
Description=Promtail Log Collector
After=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start all services
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting services..."
systemctl daemon-reload
systemctl enable promtail ai-setup.service
systemctl start promtail
systemctl start ai-setup.service

echo ""
echo "✓ AI services setup initiated."
echo "  Tail setup progress: journalctl -u ai-setup.service -f"
echo "  URL: https://${AI_DOMAIN}"
