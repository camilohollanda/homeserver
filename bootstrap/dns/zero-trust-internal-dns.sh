#!/bin/bash
set -euo pipefail

# Cloudflare DNS record manager for the existing internal zone.
# Creates/updates A records for local services.

if ! command -v jq &> /dev/null; then
  echo "Error: jq is not installed. Installing..."
  apt-get update && apt-get install -y jq
fi

CF_API_TOKEN="${CF_API_TOKEN:-}"
ZONE_ID="${ZONE_ID:-7867eee9ca3850cf9f01ad11d3ab6236}"
INTERNAL_ZONE="${INTERNAL_ZONE:-internal.prakash.com.br}"
MEDIA_IP="${MEDIA_IP:-192.168.20.40}"

JELLYFIN_DOMAIN="${JELLYFIN_DOMAIN:-jellyfin.${INTERNAL_ZONE}}"
QBITTORRENT_DOMAIN="${QBITTORRENT_DOMAIN:-torrent.${INTERNAL_ZONE}}"
RADARR_DOMAIN="${RADARR_DOMAIN:-radarr.${INTERNAL_ZONE}}"
SONARR_DOMAIN="${SONARR_DOMAIN:-sonarr.${INTERNAL_ZONE}}"
BAZARR_DOMAIN="${BAZARR_DOMAIN:-bazarr.${INTERNAL_ZONE}}"

echo "Configuring Cloudflare DNS records in existing zone..."

if [ -z "$CF_API_TOKEN" ]; then
  read -p "Enter your Cloudflare API token: " CF_API_TOKEN
fi

if [ -z "$ZONE_ID" ]; then
  echo "Error: ZONE_ID is required."
  echo ""
  echo "Find the zone ID in the Cloudflare dashboard for ${INTERNAL_ZONE}."
  echo "Docs:"
  echo "  https://developers.cloudflare.com/fundamentals/account/find-account-and-zone-ids/"
  echo ""
  echo "Then rerun with:"
  echo "  export ZONE_ID='your-zone-id'"
  exit 1
fi

echo "Verifying API token..."
api_check=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")

if [ "$(echo "$api_check" | jq -r '.success')" != "true" ]; then
  echo "Error: API token verification failed."
  echo ""
  echo "Create or update a Cloudflare API token with DNS edit permission:"
  echo "  https://dash.cloudflare.com/profile/api-tokens"
  echo ""
  echo "Suggested scope:"
  echo "  - Zone: DNS Write"
  echo ""
  echo "Then export the new token and rerun this script:"
  echo "  export CF_API_TOKEN='your-new-token'"
  exit 1
fi

ensure_a_record() {
  local zone_id="$1"
  local hostname="$2"
  local ip="$3"
  local existing
  local record_id

  existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${hostname}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json")

  if [ "$(echo "$existing" | jq -r '.success')" != "true" ]; then
    echo "Error: Failed to query DNS records for ${hostname}." >&2
    echo "$existing" | jq -r '.errors[]? | "  - \(.message)"' >&2
    return 1
  fi

  record_id=$(echo "$existing" | jq -r '.result[0].id // empty')
  if [ -n "$record_id" ]; then
    local update_response
    echo "Updating A record: ${hostname} -> ${ip}"
    update_response=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${hostname}\",\"content\":\"${ip}\",\"ttl\":1}")
    if [ "$(echo "$update_response" | jq -r '.success')" != "true" ]; then
      echo "Error: Failed to update A record for ${hostname}." >&2
      echo "$update_response" | jq -r '.errors[]? | "  - \(.message)"' >&2
      return 1
    fi
  else
    local create_response
    echo "Creating A record: ${hostname} -> ${ip}"
    create_response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"${hostname}\",\"content\":\"${ip}\",\"ttl\":1}")
    if [ "$(echo "$create_response" | jq -r '.success')" != "true" ]; then
      echo "Error: Failed to create A record for ${hostname}." >&2
      echo "$create_response" | jq -r '.errors[]? | "  - \(.message)"' >&2
      return 1
    fi
  fi
}

echo "Using zone: ${INTERNAL_ZONE} (${ZONE_ID})"

ensure_a_record "$ZONE_ID" "$JELLYFIN_DOMAIN" "$MEDIA_IP"
ensure_a_record "$ZONE_ID" "$QBITTORRENT_DOMAIN" "$MEDIA_IP"
ensure_a_record "$ZONE_ID" "$RADARR_DOMAIN" "$MEDIA_IP"
ensure_a_record "$ZONE_ID" "$SONARR_DOMAIN" "$MEDIA_IP"
ensure_a_record "$ZONE_ID" "$BAZARR_DOMAIN" "$MEDIA_IP"

echo ""
echo "Done."
echo "Jellyfin:   http://${JELLYFIN_DOMAIN}"
echo "qBittorrent: http://${QBITTORRENT_DOMAIN}"
echo "Radarr:     http://${RADARR_DOMAIN}"
echo "Sonarr:     http://${SONARR_DOMAIN}"
echo "Bazarr:     http://${BAZARR_DOMAIN}"
