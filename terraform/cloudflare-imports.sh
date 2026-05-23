#!/usr/bin/env bash
# Discovery + import helper for migrating Cloudflare resources into terraform.
#
# Usage:
#   ./terraform/cloudflare-imports.sh discover
#       Prints a terraform.tfvars snippet with cloudflare_account_id,
#       cloudflare_zone_ids, cloudflare_tunnel_id populated from the API.
#
#   ./terraform/cloudflare-imports.sh import
#       Runs the `terraform import` commands needed to bring the existing
#       tunnel + DNS records under management. Idempotent: skips any
#       resource already in state. Run AFTER populating terraform.tfvars
#       with the values from `discover`.
#
# Auth: this script needs the BROAD Terraform-scoped token (DNS + Tunnel + WAF),
# not the narrow DNS-only one used by certbot on the VMs. It reads
# TF_VAR_cloudflare_api_token by default (mise loads it from .env). Pass an
# alternate token with CF_TF_TOKEN=xxx if you need to override.
#
# The script never mutates Cloudflare state — it only reads and runs
# `terraform import`. The first state-changing step is `terraform apply`,
# which you do yourself with the plan in front of you.
#
# Compatible with bash 3.2 (macOS default) — uses parallel arrays, not assoc.

set -euo pipefail

CF_API_TOKEN="${CF_TF_TOKEN:-${TF_VAR_cloudflare_api_token:-}}"
if [[ -z "$CF_API_TOKEN" ]]; then
  echo "Error: no Cloudflare token found." >&2
  echo "  Expected TF_VAR_cloudflare_api_token in env (mise loads it from .env)," >&2
  echo "  or pass CF_TF_TOKEN=xxx explicitly. This script needs Tunnel + WAF scopes," >&2
  echo "  so don't reuse the narrow CF_API_TOKEN that certbot uses on the VMs." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

for cmd in jq curl terraform; do
  command -v "$cmd" >/dev/null || { echo "Error: '$cmd' required."; exit 1; }
done

cf_get() {
  curl -fsS -X GET "$1" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json"
}

# --- zones: parallel arrays (bash 3.2 compatible) -----------------------
# Note: internal.prakash.com.br is NOT a separate zone — those records live
# inside the prakash.com.br zone with multi-segment names.
ZONE_KEYS=(werify_app iddh_com_br prakash_com_br)
ZONE_NAMES=(werify.app iddh.com.br prakash.com.br)

# --- public CNAMEs through the tunnel ------------------------------------
PUB_KEYS=(werify_apex   werify_wildcard prakash_apex   prakash_wildcard membros_iddh        storage_iddh)
PUB_ZONES=(werify_app    werify_app      prakash_com_br prakash_com_br   iddh_com_br         iddh_com_br)
PUB_NAMES=(werify.app    "*.werify.app"  prakash.com.br "*.prakash.com.br" membros.iddh.com.br storage.iddh.com.br)

# --- internal A records (all on prakash.com.br zone) ---------------------
INT_KEYS=(garage mailpit infisical gha_cache pg ai jellyfin torrent radarr sonarr bazarr prowlarr)
INT_NAMES=(
  garage.internal.prakash.com.br
  mailpit.internal.prakash.com.br
  infisical.internal.prakash.com.br
  gha-cache.internal.prakash.com.br
  pg.internal.prakash.com.br
  ai.internal.prakash.com.br
  jellyfin.internal.prakash.com.br
  torrent.internal.prakash.com.br
  radarr.internal.prakash.com.br
  sonarr.internal.prakash.com.br
  bazarr.internal.prakash.com.br
  prowlarr.internal.prakash.com.br
)

discover_zones() {
  local zones_json id i key name acct
  zones_json=$(cf_get "https://api.cloudflare.com/client/v4/zones?per_page=50")

  echo "cloudflare_zone_ids = {"
  for i in "${!ZONE_KEYS[@]}"; do
    key="${ZONE_KEYS[$i]}"
    name="${ZONE_NAMES[$i]}"
    id=$(echo "$zones_json" | jq -r --arg n "$name" '.result[] | select(.name == $n) | .id')
    if [[ -z "$id" ]]; then
      echo "  # WARNING: zone '${name}' not found in account — verify it exists in CF dashboard"
      id="REPLACE_ME"
    fi
    printf '  %-15s = "%s"\n' "$key" "$id"
  done
  echo "}"

  acct=$(echo "$zones_json" | jq -r '.result[0].account.id // empty')
  echo ""
  printf 'cloudflare_account_id = "%s"\n' "$acct"
}

discover_tunnel() {
  local acct tunnels_json id
  acct=$(cf_get "https://api.cloudflare.com/client/v4/zones?per_page=1" | jq -r '.result[0].account.id')

  tunnels_json=$(cf_get "https://api.cloudflare.com/client/v4/accounts/${acct}/cfd_tunnel?name=homeserver&is_deleted=false")
  id=$(echo "$tunnels_json" | jq -r '.result[0].id // empty')
  if [[ -z "$id" ]]; then
    echo "  # WARNING: tunnel 'homeserver' not found — check name or create it first" >&2
    id="REPLACE_ME"
  fi
  printf 'cloudflare_tunnel_id  = "%s"\n' "$id"
}

cmd_discover() {
  echo "# Snippet for terraform.tfvars — review and paste in."
  echo "# Discovered $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  discover_zones
  discover_tunnel
}

# --- import ---------------------------------------------------------------

tf_zone_id() {
  local key="$1"
  terraform console <<<"var.cloudflare_zone_ids.${key}" 2>/dev/null | tr -d '"' | tail -1
}

tf_already_imported() {
  terraform state show "$1" >/dev/null 2>&1
}

tf_import() {
  local addr="$1" id="$2"
  if tf_already_imported "$addr"; then
    echo "  ✓ $addr — already in state"
    return
  fi
  echo "  → importing $addr (id: $id)"
  terraform import "$addr" "$id"
}

find_dns_record_id() {
  local zone_id="$1" type="$2" name="$3"
  cf_get "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=${type}&name=${name}" \
    | jq -r '.result[0].id // empty'
}

cmd_import() {
  local acct tunnel_id zone_id rec_id i tfkey zone_key name

  tunnel_id=$(terraform console <<<'var.cloudflare_tunnel_id'    2>/dev/null | tr -d '"' | tail -1)
  acct=$(terraform     console <<<'var.cloudflare_account_id'    2>/dev/null | tr -d '"' | tail -1)

  if [[ -z "$tunnel_id" || "$tunnel_id" == "null" ]]; then
    echo "Error: cloudflare_tunnel_id not set in terraform.tfvars. Run 'discover' first." >&2
    exit 1
  fi

  echo "==> Tunnel"
  tf_import "cloudflare_zero_trust_tunnel_cloudflared.homeserver" "${acct}/${tunnel_id}"

  echo ""
  echo "==> Tunnel config"
  tf_import "cloudflare_zero_trust_tunnel_cloudflared_config.homeserver" "${acct}/${tunnel_id}"

  echo ""
  echo "==> Public CNAME records"
  for i in "${!PUB_KEYS[@]}"; do
    tfkey="${PUB_KEYS[$i]}"
    zone_key="${PUB_ZONES[$i]}"
    name="${PUB_NAMES[$i]}"
    zone_id=$(tf_zone_id "$zone_key")
    rec_id=$(find_dns_record_id "$zone_id" "CNAME" "$name")
    if [[ -z "$rec_id" ]]; then
      echo "  ⚠️  $name — no existing record (will be created on apply)"
      continue
    fi
    tf_import "cloudflare_dns_record.public_tunnel[\"${tfkey}\"]" "${zone_id}/${rec_id}"
  done

  echo ""
  echo "==> Internal A records (*.internal.prakash.com.br, all in prakash.com.br zone)"
  zone_id=$(tf_zone_id "prakash_com_br")
  for i in "${!INT_KEYS[@]}"; do
    tfkey="${INT_KEYS[$i]}"
    name="${INT_NAMES[$i]}"
    rec_id=$(find_dns_record_id "$zone_id" "A" "$name")
    if [[ -z "$rec_id" ]]; then
      echo "  ⚠️  $name — no existing record (will be created on apply)"
      continue
    fi
    tf_import "cloudflare_dns_record.internal_a[\"${tfkey}\"]" "${zone_id}/${rec_id}"
  done

  echo ""
  echo "==> WAF / rate-limit rulesets"
  echo "    (Not imported — these are new rules with no pre-existing counterpart."
  echo "     terraform apply will create them.)"

  echo ""
  echo "✓ Imports complete. Run 'terraform plan' to see what apply will do."
  echo "  Expected diff: tunnel config_src local -> cloudflare, plus the new WAF/ratelimit rulesets."
}

case "${1:-}" in
  discover) cmd_discover ;;
  import)   cmd_import   ;;
  *)
    echo "Usage: $0 {discover|import}" >&2
    exit 1
    ;;
esac
