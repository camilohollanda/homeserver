#!/bin/bash
set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

# Check for required tools
if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed. Installing..."
  apt-get update && apt-get install -y jq
fi

INGRESS_NGINX_IP="127.0.0.1"
INGRESS_NGINX_PORT="80"
TUNNEL_NAME="${TUNNEL_NAME:-homeserver}"

# Cloudflare API configuration
# You can set these as environment variables or they will be prompted
CF_API_TOKEN="${CF_API_TOKEN:-}"

echo "Configuring cloudflared tunnel with local configuration files..."

# Function to get Zone ID for a domain
# Handles multi-level TLDs like .com.br, .co.uk, etc.
get_zone_id() {
  local domain="$1"
  # Remove wildcard prefix if present
  domain=$(echo "$domain" | sed 's/^\*\.//')

  # Get all zones the token has access to
  local zones=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=50" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  # Find the zone that matches (domain ends with zone name, or equals zone name)
  # Use longest match to handle subdomains correctly
  local best_zone_id=""
  local best_zone_name=""

  while IFS=$'\t' read -r id name; do
    if [[ "$domain" == "$name" ]] || [[ "$domain" == *".$name" ]]; then
      # If this zone name is longer than current best match, use it
      if [ ${#name} -gt ${#best_zone_name} ]; then
        best_zone_id="$id"
        best_zone_name="$name"
      fi
    fi
  done < <(echo "$zones" | jq -r '.result[] | "\(.id)\t\(.name)"')

  echo "$best_zone_id"
}

# Function to check if DNS record exists and get its details
# Only checks for CNAME records (which is what cloudflared tunnel creates)
check_dns_record() {
  local zone_id="$1"
  local hostname="$2"

  local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${hostname}&type=CNAME" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  echo "$response"
}

# Function to create CNAME record directly via Cloudflare API
# This bypasses cloudflared authorization issues with multiple zones
create_cname_via_api() {
  local zone_id="$1"
  local hostname="$2"
  local tunnel_id="$3"
  local target="${tunnel_id}.cfargotunnel.com"

  # For the API, we need the record name relative to the zone
  # e.g., for "*.werify.app" in zone "werify.app", name should be "*"
  # e.g., for "werify.app" in zone "werify.app", name should be "@" or "werify.app"
  local record_name="$hostname"

  local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${record_name}\",\"content\":\"${target}\",\"ttl\":1,\"proxied\":true}")

  local success=$(echo "$response" | jq -r '.success')
  if [ "$success" == "true" ]; then
    echo "  ✓ CNAME record created via API"
    return 0
  else
    local error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    echo "  ✗ API error: ${error}"
    return 1
  fi
}

# Function to update existing CNAME record via Cloudflare API
update_cname_via_api() {
  local zone_id="$1"
  local record_id="$2"
  local hostname="$3"
  local tunnel_id="$4"
  local target="${tunnel_id}.cfargotunnel.com"

  local response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${target}\",\"ttl\":1,\"proxied\":true}")

  local success=$(echo "$response" | jq -r '.success')
  if [ "$success" == "true" ]; then
    echo "  ✓ CNAME record updated via API"
    return 0
  else
    local error=$(echo "$response" | jq -r '.errors[0].message // "Unknown error"')
    echo "  ✗ API error: ${error}"
    return 1
  fi
}

# Function to handle DNS route creation with conflict resolution
create_dns_route() {
  local tunnel_name="$1"
  local hostname="$2"
  local tunnel_id="$3"

  # Expected CNAME target for our tunnel
  local our_tunnel_target="${tunnel_id}.cfargotunnel.com"

  echo ""
  echo "Processing DNS route for: ${hostname}"

  # Get zone ID for this domain
  local zone_id=$(get_zone_id "$hostname")

  if [ -z "$zone_id" ]; then
    echo "  ⚠️  Could not get Zone ID for ${hostname}."
    echo "      Make sure the zone is in your Cloudflare account and the API token has access."
    echo "      Skipping this hostname..."
    return
  fi

  echo "  Zone ID: ${zone_id}"

  # Check if CNAME record exists
  local existing=$(check_dns_record "$zone_id" "$hostname")
  local record_count=$(echo "$existing" | jq -r '.result | length')

  if [ "$record_count" -gt 0 ] && [ "$record_count" != "null" ]; then
    local record_id=$(echo "$existing" | jq -r '.result[0].id')
    local record_content=$(echo "$existing" | jq -r '.result[0].content')

    echo "  ⚠️  CNAME record already exists:"
    echo "      Content: ${record_content}"

    # Check if it's already pointing to OUR specific tunnel
    if [[ "$record_content" == "$our_tunnel_target" ]]; then
      echo "  ✓ Record already points to our tunnel. Skipping..."
      return
    fi

    # Check if it points to a DIFFERENT tunnel
    if [[ "$record_content" == *".cfargotunnel.com" ]]; then
      local other_tunnel_id=$(echo "$record_content" | sed 's/\.cfargotunnel\.com$//')
      echo "  ⚠️  Record points to a DIFFERENT tunnel: ${other_tunnel_id}"
      echo "      Our tunnel ID: ${tunnel_id}"
    else
      echo "  ℹ️  Record points to: ${record_content}"
    fi

    read -p "  Do you want to overwrite with our tunnel? (y/n): " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      echo "  Updating DNS record via API..."
      update_cname_via_api "$zone_id" "$record_id" "$hostname" "$tunnel_id"
    else
      echo "  Skipping ${hostname}..."
    fi
    return
  fi

  # No existing CNAME record, create new one via API
  echo "  Creating DNS route via API..."
  create_cname_via_api "$zone_id" "$hostname" "$tunnel_id"
}

# Check if cloudflared is installed
if ! command -v cloudflared &> /dev/null; then
  echo "Error: cloudflared is not installed. Please run cloudflared-install.sh first."
  exit 1
fi

# Create config directory
mkdir -p /etc/cloudflared

echo ""
echo "Step 1: Checking Cloudflare login..."

# Check if already logged in
if [ -f /root/.cloudflared/cert.pem ]; then
  echo "✓ Already logged in to Cloudflare (cert.pem exists)"
  echo ""
  echo "⚠️  IMPORTANT: The cert.pem authorizes cloudflared for specific zones."
  echo "   If you need to add DNS routes to multiple zones (e.g., werify.app AND prakash.com.br),"
  echo "   you may need to re-login and authorize each zone separately."
  echo ""
  read -p "Do you want to re-login to Cloudflare? (y/n): " relogin
  if [[ "$relogin" =~ ^[Yy]$ ]]; then
    echo "Removing old cert.pem..."
    rm -f /root/.cloudflared/cert.pem
    echo "Opening browser for Cloudflare login..."
    echo ""
    echo "📌 IMPORTANT: When the browser opens, select the zone you want to authorize."
    echo "   You may need to run this login multiple times (once per zone) if you have"
    echo "   domains in different zones."
    echo ""
    cloudflared tunnel login

    if [ ! -f /root/.cloudflared/cert.pem ]; then
      echo "Error: Login failed. Please check the browser authentication."
      exit 1
    fi
    echo "Login successful!"
  fi
else
  echo "Opening browser for Cloudflare login..."
  echo ""
  echo "📌 IMPORTANT: When the browser opens, select the zone you want to authorize."
  echo "   You may need to run this script multiple times (once per zone) if you have"
  echo "   domains in different zones."
  echo ""
  cloudflared tunnel login

  # Check if login was successful
  if [ ! -f /root/.cloudflared/cert.pem ]; then
    echo "Error: Login failed. Please check the browser authentication."
    exit 1
  fi
  echo "Login successful!"
fi

echo ""
echo "Step 2: Setting up tunnel '${TUNNEL_NAME}'..."

# Check if tunnel already exists
TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null | grep -E "^\S+\s+${TUNNEL_NAME}\s+" | awk '{print $1}' || echo "")

if [ -n "$TUNNEL_ID" ]; then
  echo "✓ Tunnel '${TUNNEL_NAME}' already exists (ID: ${TUNNEL_ID})"
else
  echo "Creating new tunnel '${TUNNEL_NAME}'..."
  cloudflared tunnel create "${TUNNEL_NAME}"

  # Get the new tunnel ID
  TUNNEL_ID=$(cloudflared tunnel list | grep -E "^\S+\s+${TUNNEL_NAME}\s+" | awk '{print $1}' || echo "")

  if [ -z "$TUNNEL_ID" ]; then
    echo "Error: Could not find tunnel ID after creation. Please check tunnel name."
    echo "Run: cloudflared tunnel list"
    exit 1
  fi
  echo "✓ Tunnel created with ID: ${TUNNEL_ID}"
fi

# Create config.yml with ingress rules
echo ""
echo "Step 3: Creating configuration file..."
cat > /etc/cloudflared/config.yml <<EOF
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

echo "Configuration file created at /etc/cloudflared/config.yml"

# Configure DNS routes
# Note: The config.yml defines ingress rules, but DNS records need to be created separately
# These commands create CNAME records pointing domains to the tunnel
echo ""
echo "Step 4: Configuring DNS routes..."

# Check if we have API token for smart DNS management
if [ -z "$CF_API_TOKEN" ]; then
  echo ""
  echo "To check and manage existing DNS records, a Cloudflare API token is needed."
  echo "You can create one at: https://dash.cloudflare.com/profile/api-tokens"
  echo "Required permissions: Zone.DNS (Edit) for the zones you're configuring."
  echo ""
  read -p "Enter your Cloudflare API token (or press Enter to skip smart management): " CF_API_TOKEN
fi

if [ -n "$CF_API_TOKEN" ]; then
  echo ""
  echo "Using Cloudflare API for smart DNS management..."

  # Verify API token is valid
  api_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  if [ "$(echo "$api_check" | jq -r '.success')" != "true" ]; then
    echo "Warning: API token verification failed. Falling back to basic mode."
    CF_API_TOKEN=""
  else
    echo "✓ API token verified."
  fi
fi

if [ -n "$CF_API_TOKEN" ]; then
  # Use Cloudflare API directly for DNS management
  # This bypasses cloudflared authorization issues with multiple zones
  create_dns_route "${TUNNEL_NAME}" "werify.app" "${TUNNEL_ID}"
  create_dns_route "${TUNNEL_NAME}" "*.werify.app" "${TUNNEL_ID}"
  create_dns_route "${TUNNEL_NAME}" "prakash.com.br" "${TUNNEL_ID}"
  create_dns_route "${TUNNEL_NAME}" "*.prakash.com.br" "${TUNNEL_ID}"
else
  echo ""
  echo "⚠️  API token is required for DNS management with multiple zones."
  echo ""
  echo "The cloudflared CLI can only create DNS records in zones authorized during 'tunnel login'."
  echo "To manage DNS records in multiple zones (werify.app AND prakash.com.br), you need an API token."
  echo ""
  echo "Please create an API token at: https://dash.cloudflare.com/profile/api-tokens"
  echo "Required permissions: Zone.DNS (Edit) for all zones you want to configure."
  echo ""
  echo "Then run this script again with: CF_API_TOKEN=your_token ./cloudflared-config.sh"
  echo ""
  echo "Skipping DNS configuration for now..."
fi

echo ""
echo "DNS routes configuration completed."

# Install as systemd service
echo ""
echo "Step 5: Installing cloudflared as systemd service..."

if [ -f /etc/systemd/system/cloudflared.service ]; then
  echo "✓ Cloudflared service already installed at /etc/systemd/system/cloudflared.service"

  # Check if we need to update the service (config might have changed)
  echo "  Checking if service config needs update..."

  # The service file should point to our config
  if grep -q "/etc/cloudflared/config.yml" /etc/systemd/system/cloudflared.service 2>/dev/null; then
    echo "  ✓ Service is configured correctly"
  else
    echo "  ⚠️  Service might be using different config. Consider running:"
    echo "     cloudflared service uninstall && cloudflared service install"
  fi
else
  cloudflared service install
  echo "✓ Service installed"
fi

# Enable and start service
echo ""
echo "Step 6: Starting cloudflared service..."
systemctl daemon-reload
systemctl enable cloudflared

# Restart if already running, start if not
if systemctl is-active --quiet cloudflared; then
  echo "Service is running. Restarting to apply any config changes..."
  systemctl restart cloudflared
else
  echo "Starting cloudflared service..."
  systemctl start cloudflared
fi

echo ""
echo "✓ Cloudflared tunnel configured and started!"
echo ""
echo "Configuration files:"
echo "  - /etc/cloudflared/config.yml (tunnel configuration)"
echo "  - /root/.cloudflared/${TUNNEL_ID}.json (tunnel credentials)"
echo "  - /root/.cloudflared/cert.pem (Cloudflare account certificate)"
echo ""
echo "Service status:"
systemctl status cloudflared --no-pager -l | head -10 || true
