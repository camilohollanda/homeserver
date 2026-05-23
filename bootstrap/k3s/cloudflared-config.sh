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

# Garage S3 (lives on the services VM, not in k3s — cloudflared talks directly
# across the LAN to its S3 port. Requests are SigV4-signed so this LAN path is
# auth'd.)
GARAGE_S3_IP="192.168.20.22"
GARAGE_S3_PORT="3900"

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

# Print Cloudflare's reported status once per script invocation when an API
# call has failed in a way that suggests it might not be our problem (5xx, or
# the legacy `{"code":1000,"error":...}` envelope CF returns at the gateway).
CF_STATUS_CHECKED=""
cf_status_check() {
  [ -n "$CF_STATUS_CHECKED" ] && return
  CF_STATUS_CHECKED=1
  local cf_status
  cf_status=$(curl -s --max-time 5 "https://www.cloudflarestatus.com/api/v2/status.json" 2>/dev/null \
    | jq -r '.status.description // empty' 2>/dev/null)
  if [ -z "$cf_status" ]; then
    echo "    (Could not reach https://www.cloudflarestatus.com/ to check CF status)"
  elif [[ "$cf_status" != *"All Systems Operational"* ]]; then
    echo "    ⚠️  Cloudflare status: ${cf_status}"
    echo "       https://www.cloudflarestatus.com/ — retry once resolved."
  else
    echo "    (Cloudflare reports all systems operational — issue may be account/zone-specific)"
  fi
}

# Curl POST/PUT JSON and report a useful failure: HTTP status, parsed message
# if present, otherwise the raw body. Triggers a CF status check on 5xx or the
# code:1000 gateway envelope. Echoes the body so callers can keep parsing it.
cf_api_write() {
  local method="$1" url="$2" data="$3" context="$4"
  local raw http_status body
  raw=$(curl -s -w "\n__HTTP_STATUS__:%{http_code}" -X "$method" "$url" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$data")
  http_status="${raw##*__HTTP_STATUS__:}"
  body="${raw%$'\n'__HTTP_STATUS__:*}"

  if echo "$body" | jq -e '.success == true' &>/dev/null; then
    echo "$body"
    return 0
  fi

  local msg
  msg=$(echo "$body" | jq -r '.errors[0].message // empty' 2>/dev/null)
  if [ -n "$msg" ]; then
    echo "  ✗ ${context}: ${msg} (HTTP ${http_status})" >&2
  else
    echo "  ✗ ${context}: HTTP ${http_status}" >&2
    echo "    Raw response:" >&2
    echo "$body" | sed 's/^/      /' >&2
  fi

  # 5xx or the legacy { code: 1000, error: ... } gateway envelope -> likely CF-side
  if [[ "$http_status" =~ ^5 ]] || echo "$body" | jq -e '.code == 1000' &>/dev/null; then
    cf_status_check >&2
  fi

  return 1
}

create_cname_via_api() {
  local zone_id="$1" hostname="$2" tunnel_id="$3"
  local target="${tunnel_id}.cfargotunnel.com"
  if cf_api_write POST \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"ttl\":1,\"proxied\":true}" \
    "Create CNAME failed" >/dev/null; then
    echo "  ✓ CNAME record created"
  else
    return 1
  fi
}

update_cname_via_api() {
  local zone_id="$1" record_id="$2" hostname="$3" tunnel_id="$4"
  local target="${tunnel_id}.cfargotunnel.com"
  if cf_api_write PUT \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
    "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"ttl\":1,\"proxied\":true}" \
    "Update CNAME failed" >/dev/null; then
    echo "  ✓ CNAME record updated"
  else
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
# Step 1: Discover existing tunnel on the VM
# ---------------------------------------------------------------------------
# We read the tunnel UUID from the running config or the credentials file
# rather than calling `cloudflared tunnel list`, so this script works even if
# /root/.cloudflared/cert.pem (origin cert from `cloudflared tunnel login`) was
# rotated or deleted — the tunnel itself runs from the per-tunnel JSON creds.
echo ""
echo "Step 1: Looking for existing tunnel on VM (${K3S_SSH})..."

TUNNEL_ID=$(ssh "$K3S_SSH" \
  "sudo grep -E '^tunnel:' /etc/cloudflared/config.yml 2>/dev/null | awk '{print \$2}'" \
  || echo "")

if [ -z "$TUNNEL_ID" ]; then
  TUNNEL_ID=$(ssh "$K3S_SSH" \
    "sudo ls /root/.cloudflared/ 2>/dev/null | grep -E '^[a-f0-9-]{36}\.json$' | head -1 | sed 's/\.json$//'" \
    || echo "")
fi

if [ -n "$TUNNEL_ID" ]; then
  echo "✓ Found existing tunnel (ID: ${TUNNEL_ID})"
else
  echo "No existing tunnel found on VM."
  if ssh "$K3S_SSH" "test -f /root/.cloudflared/cert.pem" 2>/dev/null; then
    echo "Creating new tunnel '${TUNNEL_NAME}'..."
    ssh "$K3S_SSH" "sudo cloudflared tunnel create ${TUNNEL_NAME}"
    TUNNEL_ID=$(ssh "$K3S_SSH" \
      "sudo ls /root/.cloudflared/ | grep -E '^[a-f0-9-]{36}\.json$' | head -1 | sed 's/\.json$//'" \
      || echo "")
    if [ -z "$TUNNEL_ID" ]; then
      echo "Error: tunnel created but could not read its ID."
      exit 1
    fi
    echo "✓ Tunnel created (ID: ${TUNNEL_ID})"
  else
    echo ""
    echo "ERROR: no tunnel found and cloudflared is not logged in."
    echo "SSH into the VM and run:"
    echo "  ssh ${K3S_SSH}"
    echo "  sudo cloudflared tunnel login"
    echo "  sudo cloudflared tunnel create ${TUNNEL_NAME}"
    echo ""
    echo "Then re-run this script."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Write config.yml on VM via SSH
# ---------------------------------------------------------------------------
echo ""
echo "Step 2: Writing /etc/cloudflared/config.yml on VM..."

ssh "$K3S_SSH" "sudo mkdir -p /etc/cloudflared"

# Heredoc is expanded locally; contents are piped as stdin to tee on the VM.
ssh "$K3S_SSH" "sudo tee /etc/cloudflared/config.yml > /dev/null" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json

ingress:
  # Garage S3 — must come BEFORE the wildcards below; cloudflared matches in order.
  - hostname: "storage.werify.app"
    service: http://${GARAGE_S3_IP}:${GARAGE_S3_PORT}
  - hostname: "storage-staging.werify.app"
    service: http://${GARAGE_S3_IP}:${GARAGE_S3_PORT}
  - hostname: "storage.iddh.com.br"
    service: http://${GARAGE_S3_IP}:${GARAGE_S3_PORT}
  - hostname: "*.werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "werify.app"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "*.prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "prakash.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - hostname: "membros.iddh.com.br"
    service: http://${INGRESS_NGINX_IP}:${INGRESS_NGINX_PORT}
  - service: http_status:404
EOF

echo "✓ config.yml written."

# ---------------------------------------------------------------------------
# Step 3: DNS routes (Cloudflare API, runs locally)
# ---------------------------------------------------------------------------
echo ""
echo "Step 3: Configuring DNS routes..."

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
  create_dns_route "${TUNNEL_NAME}" "membros.iddh.com.br" "${TUNNEL_ID}"
  # storage.werify.app is already covered by the *.werify.app CNAME above —
  # no specific record needed. iddh.com.br has no wildcard, so storage.iddh.com.br
  # still needs its own CNAME.
  create_dns_route "${TUNNEL_NAME}" "storage.iddh.com.br" "${TUNNEL_ID}"
else
  echo "⚠️  No API token provided — skipping DNS configuration."
  echo "   Re-run with: CF_API_TOKEN=xxx ./cloudflared-config.sh"
fi

# ---------------------------------------------------------------------------
# Step 4: Install service if needed (runs on VM via SSH)
# ---------------------------------------------------------------------------
echo ""
echo "Step 4: Checking cloudflared systemd service on VM..."

if ssh "$K3S_SSH" "test -f /etc/systemd/system/cloudflared.service" 2>/dev/null; then
  echo "✓ Service already installed."
else
  echo "Installing cloudflared service..."
  ssh "$K3S_SSH" "sudo cloudflared service install"
  echo "✓ Service installed."
fi

# ---------------------------------------------------------------------------
# Step 5: Reload and restart service on VM
# ---------------------------------------------------------------------------
echo ""
echo "Step 5: Reloading cloudflared on VM..."

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
