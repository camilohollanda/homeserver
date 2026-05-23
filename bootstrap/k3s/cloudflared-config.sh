#!/usr/bin/env bash
# VM-side bootstrap for the cloudflared tunnel.
#
# After the Terraform migration this script only handles the VM-resident parts:
#   - discover or create the tunnel on the VM (one-time, requires `cloudflared tunnel login`)
#   - write a MINIMAL /etc/cloudflared/config.yml (tunnel id + creds path; no ingress)
#   - install + start the systemd service
#
# Ingress routes and DNS records are now owned by terraform/cloudflare-tunnel.tf
# and terraform/cloudflare-dns.tf. The tunnel runs in remotely-managed mode
# (`config_src = "cloudflare"`), so cloudflared pulls ingress from Cloudflare
# on connect — the local config.yml intentionally contains no `ingress:` block.
#
# Usage:
#   ./cloudflared-config.sh
#   K3S_SSH=user@host ./cloudflared-config.sh
set -euo pipefail

K3S_SSH="${K3S_SSH:-deployer@192.168.20.11}"
TUNNEL_NAME="${TUNNEL_NAME:-homeserver}"

for cmd in ssh; do
  command -v "$cmd" &>/dev/null || { echo "Error: '$cmd' required."; exit 1; }
done

# ---------------------------------------------------------------------------
# Step 1: Discover existing tunnel on the VM
# ---------------------------------------------------------------------------
# We read the tunnel UUID from the running config or the credentials file
# rather than calling `cloudflared tunnel list`, so this script works even if
# /root/.cloudflared/cert.pem (origin cert from `cloudflared tunnel login`) was
# rotated or deleted — the tunnel itself runs from the per-tunnel JSON creds.
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
    echo "Then re-run this script. After it succeeds, set TF var"
    echo "  cloudflare_tunnel_id = \"<the tunnel ID printed above>\""
    echo "and import the tunnel:"
    echo "  cd terraform"
    echo "  terraform import cloudflare_zero_trust_tunnel_cloudflared.homeserver \\"
    echo "    \"\$TF_VAR_cloudflare_account_id/<the tunnel ID>\""
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Write minimal /etc/cloudflared/config.yml on the VM
# ---------------------------------------------------------------------------
# Intentionally NO `ingress:` block — the tunnel is remotely-managed
# (terraform/cloudflare-tunnel.tf sets config_src = "cloudflare"), so
# cloudflared pulls routes from Cloudflare on connect.
echo ""
echo "Step 2: Writing minimal /etc/cloudflared/config.yml..."

ssh "$K3S_SSH" "sudo mkdir -p /etc/cloudflared"
ssh "$K3S_SSH" "sudo tee /etc/cloudflared/config.yml > /dev/null" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /root/.cloudflared/${TUNNEL_ID}.json
EOF
echo "✓ config.yml written (ingress comes from Cloudflare API)."

# ---------------------------------------------------------------------------
# Step 3: Install systemd service if needed
# ---------------------------------------------------------------------------
echo ""
echo "Step 3: Checking cloudflared systemd service on VM..."

if ssh "$K3S_SSH" "test -f /etc/systemd/system/cloudflared.service" 2>/dev/null; then
  echo "✓ Service already installed."
else
  echo "Installing cloudflared service..."
  ssh "$K3S_SSH" "sudo cloudflared service install"
  echo "✓ Service installed."
fi

# ---------------------------------------------------------------------------
# Step 4: Reload + start service
# ---------------------------------------------------------------------------
echo ""
echo "Step 4: Reloading cloudflared on VM..."

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
echo "  Ingress + DNS are managed by terraform/ — run 'terraform apply' to change routes."
