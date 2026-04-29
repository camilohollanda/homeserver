#!/usr/bin/env bash
# Runs locally. Uses SSH for k3s VM operations and the Cloudflare API for DNS.
# Requires: jq, curl, ssh access to K3S_SSH host
#
# Usage:
#   CF_API_TOKEN=xxx ./cloudflared-config.sh
#   K3S_SSH=user@host CF_API_TOKEN=xxx ./cloudflared-config.sh
set -euo pipefail

K3S_SSH="${K3S_SSH:-deployer@192.168.20.11}"
TUNNEL_NAME="${TUNNEL_NAME:-homeserver}"
CF_API_TOKEN="${CF_API_TOKEN:-}"
INGRESS_NGINX_IP="127.0.0.1"
INGRESS_NGINX_PORT="80"

# ---------------------------------------------------------------------------
# Local dependency check
# ---------------------------------------------------------------------------
for cmd in jq curl ssh; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is required but not installed."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Cloudflare API helpers (run locally)
# ---------------------------------------------------------------------------
get_zone_id() {
  local domain="$1"
  domain=$(echo "$domain" | sed 's/^\*\.//')

  local zones
  zones=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  local best_zone_id="" best_zone_name=""
  while IFS=$'\t' read -r id name; do
    if [[ "$domain" == "$name" ]] || [[ "$domain" == *".$name" ]]; then
      if [ ${#name} -gt ${#best_zone_name} ]; then
        best_zone_id="$id"
        best_zone_name="$name"
      fi
    fi
  done < <(echo "$zones" | jq -r '.result[] | "\(.id)\t\(.name)"')

  echo "$best_zone_id"
}

check_dns_record() {
  local zone_id="$1" hostname="$2"
  curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${hostname}&type=CNAME" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json"
}

create_cname_via_api() {
  local zone_id="$1" hostname="$2" tunnel_id="$3"
  local target="${tunnel_id}.cfargotunnel.com"
  local response
  response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"ttl\":1,\"proxied\":true}")
  if [ "$(echo "$response" | jq -r '.success')" == "true" ]; then
    echo "  ✓ CNAME record created"
  else
    echo "  ✗ API error: $(echo "$response" | jq -r '.errors[0].message // "Unknown error"')"
    return 1
  fi
}

update_cname_via_api() {
  local zone_id="$1" record_id="$2" hostname="$3" tunnel_id="$4"
  local target="${tunnel_id}.cfargotunnel.com"
  local response
  response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"ttl\":1,\"proxied\":true}")
  if [ "$(echo "$response" | jq -r '.success')" == "true" ]; then
    echo "  ✓ CNAME record updated"
  else
    echo "  ✗ API error: $(echo "$response" | jq -r '.errors[0].message // "Unknown error"')"
    return 1
  fi
}

create_dns_route() {
  local tunnel_name="$1" hostname="$2" tunnel_id="$3"
  local our_target="${tunnel_id}.cfargotunnel.com"

  echo ""
  echo "Processing DNS route for: ${hostname}"

  local zone_id
  zone_id=$(get_zone_id "$hostname")
  if [ -z "$zone_id" ]; then
    echo "  ⚠️  Could not find Cloudflare zone for ${hostname} — skipping."
    echo "      Make sure the zone exists in your account and the token has Zone.DNS access."
    return
  fi
  echo "  Zone ID: ${zone_id}"

  local existing record_count
  existing=$(check_dns_record "$zone_id" "$hostname")
  record_count=$(echo "$existing" | jq -r '.result | length')

  if [ "$record_count" -gt 0 ] && [ "$record_count" != "null" ]; then
    local record_id record_content
    record_id=$(echo "$existing" | jq -r '.result[0].id')
    record_content=$(echo "$existing" | jq -r '.result[0].content')

    if [[ "$record_content" == "$our_target" ]]; then
      echo "  ✓ Already pointing to our tunnel — skipping."
      return
    fi

    echo "  ⚠️  Existing CNAME points to: ${record_content}"
    read -p "  Overwrite with our tunnel? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      update_cname_via_api "$zone_id" "$record_id" "$hostname" "$tunnel_id"
    else
      echo "  Skipping ${hostname}."
    fi
    return
  fi

  create_cname_via_api "$zone_id" "$hostname" "$tunnel_id"
}

# ---------------------------------------------------------------------------
# Step 1: Verify cloudflared login on the VM
# ---------------------------------------------------------------------------
echo ""
echo "Step 1: Checking cloudflared login on VM (${K3S_SSH})..."

if ssh "$K3S_SSH" "test -f /root/.cloudflared/cert.pem" 2>/dev/null; then
  echo "✓ cert.pem exists on VM."
else
  echo ""
  echo "ERROR: cloudflared is not logged in on the VM."
  echo "This is a one-time step. SSH into the VM and run:"
  echo ""
  echo "  ssh ${K3S_SSH}"
  echo "  sudo cloudflared tunnel login"
  echo ""
  echo "Then re-run this script."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Get or create the tunnel (runs on VM via SSH)
# ---------------------------------------------------------------------------
echo ""
echo "Step 2: Setting up tunnel '${TUNNEL_NAME}'..."

TUNNEL_ID=$(ssh "$K3S_SSH" \
  "sudo cloudflared tunnel list 2>/dev/null | grep -E '^\S+\s+${TUNNEL_NAME}\s+' | awk '{print \$1}'" \
  || echo "")

if [ -n "$TUNNEL_ID" ]; then
  echo "✓ Tunnel '${TUNNEL_NAME}' already exists (ID: ${TUNNEL_ID})"
else
  echo "Creating new tunnel '${TUNNEL_NAME}'..."
  ssh "$K3S_SSH" "sudo cloudflared tunnel create ${TUNNEL_NAME}"

  TUNNEL_ID=$(ssh "$K3S_SSH" \
    "sudo cloudflared tunnel list | grep -E '^\S+\s+${TUNNEL_NAME}\s+' | awk '{print \$1}'" \
    || echo "")

  if [ -z "$TUNNEL_ID" ]; then
    echo "Error: tunnel created but could not read its ID."
    echo "Run on the VM: sudo cloudflared tunnel list"
    exit 1
  fi
  echo "✓ Tunnel created (ID: ${TUNNEL_ID})"
fi

# ---------------------------------------------------------------------------
# Step 3: Write config.yml on VM via SSH
# ---------------------------------------------------------------------------
echo ""
echo "Step 3: Writing /etc/cloudflared/config.yml on VM..."

ssh "$K3S_SSH" "sudo mkdir -p /etc/cloudflared"

# Heredoc is expanded locally; contents are piped as stdin to tee on the VM.
ssh "$K3S_SSH" "sudo tee /etc/cloudflared/config.yml > /dev/null" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  - hostname: "*.werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "*.prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - service: http_status:404
EOF

echo "✓ config.yml written."

# ---------------------------------------------------------------------------
# Step 4: DNS routes (Cloudflare API, runs locally)
# ---------------------------------------------------------------------------
echo ""
echo "Step 4: Configuring DNS routes..."

if [ -z "$CF_API_TOKEN" ]; then
  echo ""
  read -p "Enter your Cloudflare API token (Zone.DNS Edit): " CF_API_TOKEN
fi

if [ -n "$CF_API_TOKEN" ]; then
  api_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")
  if [ "$(echo "$api_check" | jq -r '.success')" != "true" ]; then
    echo "Error: Cloudflare API token invalid."
    exit 1
  fi
  echo "✓ API token verified."

  create_dns_route "${TUNNEL_NAME}" "werify.app" "${TUNNEL_ID}"
  create_dns_route "${TUNNEL_NAME}" "*.werify.app" "${TUNNEL_ID}"
  create_dns_route "${TUNNEL_NAME}" "prakash.com.br" "${TUNNEL_ID}"
  create_dns_route "${TUNNEL_NAME}" "*.prakash.com.br" "${TUNNEL_ID}"
else
  echo "⚠️  No API token provided — skipping DNS configuration."
  echo "   Re-run with: CF_API_TOKEN=xxx ./cloudflared-config.sh"
fi

# ---------------------------------------------------------------------------
# Step 5: Install service if needed (runs on VM via SSH)
# ---------------------------------------------------------------------------
echo ""
echo "Step 5: Checking cloudflared systemd service on VM..."

if ssh "$K3S_SSH" "test -f /etc/systemd/system/cloudflared.service" 2>/dev/null; then
  echo "✓ Service already installed."
else
  echo "Installing cloudflared service..."
  ssh "$K3S_SSH" "sudo cloudflared service install"
  echo "✓ Service installed."
fi

# ---------------------------------------------------------------------------
# Step 6: Reload and restart service on VM
# ---------------------------------------------------------------------------
echo ""
echo "Step 6: Reloading cloudflared on VM..."

ssh "$K3S_SSH" "sudo systemctl daemon-reload && sudo systemctl enable cloudflared --quiet"

if ssh "$K3S_SSH" "sudo systemctl is-active --quiet cloudflared"; then
  ssh "$K3S_SSH" "sudo systemctl restart cloudflared"
  echo "✓ Service restarted."
else
  ssh "$K3S_SSH" "sudo systemctl start cloudflared"
  echo "✓ Service started."
fi

echo ""
echo "Service status:"
ssh "$K3S_SSH" "sudo systemctl status cloudflared --no-pager -l | head -10" || true

echo ""
echo "✓ Done. Tunnel '${TUNNEL_NAME}' (${TUNNEL_ID}) is running."
