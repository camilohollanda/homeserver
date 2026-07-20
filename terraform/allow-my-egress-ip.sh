#!/usr/bin/env bash
#
# allow-my-egress-ip.sh — let THIS machine reach the staging apps without WARP.
#
# Fetches your current public egress IP (what Cloudflare sees when your browser
# hits staging.werify.app / iddh-members-staging.prakash.com.br over the tunnel),
# sets TF_VAR_staging_allow_ip_cidrs, and applies just the staging Access gate.
#
# The IP allow is OR-ed alongside the WARP policy (cloudflare-access.tf:107), so
# this does NOT disturb WARP access — it only adds your IP as a second, silent
# (no-login) way in. Turn WARP off, hit staging, you're in by IP.
#
# Requires your usual terraform auth already exported in the env
# (TF_VAR_cloudflare_api_token etc. — same as any `terraform apply` you run here).
#
# Usage:
#   ./allow-my-egress-ip.sh              # targeted plan+apply (prompts to confirm)
#   AUTO_APPROVE=1 ./allow-my-egress-ip.sh
#   FULL_APPLY=1  ./allow-my-egress-ip.sh   # apply the whole config, not just the gate
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"   # -> terraform/

# --- safety: never capture the WARP egress IP -------------------------------
# If WARP is up, curl sees Cloudflare's shared egress IP, not your home IP.
# Allowlisting that is useless AND a hole (other WARP users share it).
if command -v warp-cli >/dev/null 2>&1; then
  if warp-cli status 2>/dev/null | grep -qiw connected; then
    echo "ERROR: WARP is connected — disconnect it first (warp-cli disconnect)." >&2
    echo "       Otherwise this captures Cloudflare's egress IP, not your home IP." >&2
    exit 1
  fi
else
  echo "WARN: warp-cli not found; can't verify WARP is off. Make sure it is." >&2
fi

# --- fetch egress IPs -------------------------------------------------------
fetch_ip() {  # $1 = 4 or 6
  local ip
  for url in https://ifconfig.me https://api.ipify.org https://checkip.amazonaws.com; do
    ip="$(curl -"$1" -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]')" || true
    [ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

V4="$(fetch_ip 4 || true)"
V6="$(fetch_ip 6 || true)"

[ -n "${V4:-}" ] || { echo "ERROR: could not determine an IPv4 egress IP." >&2; exit 1; }
echo "$V4" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
  || { echo "ERROR: '$V4' is not an IPv4 address." >&2; exit 1; }

CIDRS=("$V4/32")

# Cloudflare is dual-stack: a v6-capable browser will often connect over IPv6,
# so allow the /64 too (host bits rotate with privacy extensions; the /64 prefix
# is the stable part).
V6NET=""
if [ -n "${V6:-}" ] && command -v python3 >/dev/null 2>&1; then
  V6NET="$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1]+"/64", strict=False))' "$V6" 2>/dev/null || true)"
  [ -n "$V6NET" ] && CIDRS+=("$V6NET")
fi
if [ -n "${V6:-}" ] && [ -z "$V6NET" ]; then
  echo "WARN: IPv6 detected ($V6) but couldn't compute its /64 — skipping v6." >&2
  echo "      If staging still bounces you over v6, add the /64 to the var by hand." >&2
fi

# --- build the JSON list Terraform expects ----------------------------------
JSON="[$(printf '"%s",' "${CIDRS[@]}" | sed 's/,$//')]"
export TF_VAR_staging_allow_ip_cidrs="$JSON"

echo "==> egress IPv4 : $V4"
[ -n "${V6:-}" ] && echo "==> egress IPv6 : $V6  (allowing ${V6NET:-<skipped>})"
echo "==> TF_VAR_staging_allow_ip_cidrs = $TF_VAR_staging_allow_ip_cidrs"
echo

# --- apply ------------------------------------------------------------------
[ -d .terraform ] || terraform init

ARGS=()
if [ -z "${FULL_APPLY:-}" ]; then
  # Minimal blast radius: only the staging gate + its IP bypass policy, nothing
  # Proxmox. staging_ip_bypass is the no-login IP allowlist (bypass, not allow —
  # an allow policy would still bounce the IP to a login).
  ARGS+=(
    -target=cloudflare_zero_trust_access_policy.staging_ip_bypass
    -target=cloudflare_zero_trust_access_application.staging_gate
  )
fi
[ -n "${AUTO_APPROVE:-}" ] && ARGS+=(-auto-approve)

terraform apply "${ARGS[@]}"

echo
echo "Done — staging apps now also allow $V4 (WARP still works too)."
echo "Test: turn WARP OFF, open https://staging.werify.app — you should get in with no login."
echo
echo "NOTE: this is NOT written to terraform.tfvars. A later plain 'terraform apply'"
echo "      (without this env var) will REMOVE the IP allow and revert to WARP-only."
echo "      To make it permanent, add this line to terraform.tfvars:"
echo "          staging_allow_ip_cidrs = $JSON"
