#!/usr/bin/env bash
# Runs on the services VM (vmid 114) as root.
# Remote: REMOTE_HOST=deployer@192.168.20.22 ./install.sh
#
# Ships every Docker container's stdout on this VM to the in-cluster Loki via
# its NodePort. Outbound only — no inbound listener, no DNS, no TLS, no shared
# nginx vhost.
#
# Optional env vars:
#   PROMTAIL_VERSION   - image tag (default: 3.6.3, matches gitops/loki-stack/promtail.yaml)
#   LOKI_URL           - push endpoint (default: http://192.168.20.11:31100/loki/api/v1/push)
#   PROMTAIL_HOSTNAME  - 'host' label in Loki (default: services)
if [[ -n "${REMOTE_HOST:-}" ]]; then
  { printf 'export %s=%q\n' \
      PROMTAIL_VERSION  "${PROMTAIL_VERSION:-}" \
      LOKI_URL          "${LOKI_URL:-}" \
      PROMTAIL_HOSTNAME "${PROMTAIL_HOSTNAME:-}"
    cat "$0"
  } | ssh "$REMOTE_HOST" "sudo bash -s"
  exit $?
fi
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "Error: run as root, or set REMOTE_HOST= for remote execution"
  exit 1
fi

PROMTAIL_VERSION="${PROMTAIL_VERSION:-3.6.3}"
LOKI_URL="${LOKI_URL:-http://192.168.20.11:31100/loki/api/v1/push}"
PROMTAIL_HOSTNAME="${PROMTAIL_HOSTNAME:-services}"

# ---------------------------------------------------------------------------
# Prereqs
# ---------------------------------------------------------------------------
if ! command -v docker &>/dev/null; then
  echo "Error: docker missing. Run bootstrap/services/install.sh first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Promtail stack files
# ---------------------------------------------------------------------------
echo ""
echo "==> Writing Promtail configuration..."
mkdir -p /opt/promtail/data

cat > /opt/promtail/.env <<ENV
PROMTAIL_VERSION=${PROMTAIL_VERSION}
ENV
chmod 600 /opt/promtail/.env

# Docker SD discovers every running container on this VM and tails its
# JSON-file log. Container name + compose project/service are projected as
# Loki labels so queries like {container="garage"} just work.
cat > /opt/promtail/promtail.yaml <<YAML
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: ${LOKI_URL}

scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__meta_docker_container_name]
        regex: '/(.*)'
        target_label: container
      - source_labels: [__meta_docker_container_label_com_docker_compose_service]
        target_label: compose_service
      - source_labels: [__meta_docker_container_label_com_docker_compose_project]
        target_label: compose_project
      - target_label: host
        replacement: ${PROMTAIL_HOSTNAME}
      - target_label: job
        replacement: docker
    pipeline_stages:
      # Strip the Docker JSON envelope so the message body is what shows up in Grafana.
      - docker: {}
      # Strip ANSI color codes — Garage (and likely other Rust apps) emit them
      # even when stdout is piped. Without this, downstream regex stages can't
      # anchor on real content because the line starts with ESC[...m.
      # NOTE: replace's `expression` must include capture groups — only captured
      # text is replaced, not the entire match. The outer group here makes the
      # whole ANSI sequence the captured text so it gets stripped.
      - replace:
          expression: '(\x1b\[[0-9;]*m)'
          replace: ''
      # Per-container parsers: pull timestamp + level out of the log line so
      # Grafana doesn't render them twice (its own column + the embedded prefix),
      # and so 'level' becomes a real Loki label (filterable + colored chip).
      # Lines that don't match the regex pass through unchanged.
      #
      # Garage (Rust tracing): "2026-05-27T20:31:55.470199Z  INFO module: msg"
      - match:
          selector: '{container="garage"}'
          stages:
            - regex:
                expression: '^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z)\s+(?P<level>[A-Z]+)\s+(?P<message>.*)$'
            - timestamp:
                source: ts
                format: RFC3339Nano
                action_on_failure: skip
            - labels:
                level:
            - output:
                source: message
YAML

cat > /opt/promtail/docker-compose.yml <<'COMPOSE'
services:
  promtail:
    image: grafana/promtail:${PROMTAIL_VERSION}
    container_name: promtail
    restart: unless-stopped
    # Needs to read root-owned docker.sock and /var/lib/docker/containers/*/*-json.log
    user: root
    command: -config.file=/etc/promtail/promtail.yaml
    volumes:
      - /opt/promtail/promtail.yaml:/etc/promtail/promtail.yaml:ro
      - /opt/promtail/data:/var/lib/promtail
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
COMPOSE

cat > /etc/systemd/system/promtail.service <<'SVC'
[Unit]
Description=Promtail — ships docker logs on this VM to Loki
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/promtail
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
SVC

# ---------------------------------------------------------------------------
# Start Promtail
# ---------------------------------------------------------------------------
echo ""
echo "==> Starting Promtail..."
systemctl daemon-reload
systemctl enable promtail

if systemctl is-active --quiet promtail; then
  systemctl restart promtail
else
  systemctl start promtail
fi

echo -n "  Waiting for /ready"
for _ in $(seq 1 30); do
  code="$(docker exec promtail wget -q -O- http://127.0.0.1:9080/ready 2>/dev/null || true)"
  if [[ "$code" == "Ready" ]]; then
    echo " ✓"
    break
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "✓ Promtail is running."
echo "  Pushing to:  ${LOKI_URL}"
echo "  Host label:  ${PROMTAIL_HOSTNAME}"
echo ""
echo "  In Grafana (Explore → Loki):"
echo "    {host=\"${PROMTAIL_HOSTNAME}\"}                       # everything on this VM"
echo "    {host=\"${PROMTAIL_HOSTNAME}\", container=\"garage\"}  # just Garage"
