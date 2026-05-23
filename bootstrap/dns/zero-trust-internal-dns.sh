#!/usr/bin/env bash
# DEPRECATED — all internal A records are now managed in Terraform.
#
# Previously this script created/updated A records for the media stack
# (jellyfin, torrent, radarr, sonarr, bazarr) directly via the Cloudflare
# API. Those records now live in:
#
#   terraform/cloudflare-dns.tf
#     resource "cloudflare_dns_record" "internal_a"
#
# To change a record, edit that file and run:
#   cd terraform && terraform plan && terraform apply
#
# This stub exists so old runbook links don't 404; it prints the migration
# pointer and exits non-zero so any stale automation calling it fails loudly.

cat <<'EOF' >&2
zero-trust-internal-dns.sh is DEPRECATED.

Internal DNS records are now managed by Terraform:
  terraform/cloudflare-dns.tf  (resource "cloudflare_dns_record.internal_a")

To change records:
  cd terraform
  # edit cloudflare-dns.tf
  terraform plan
  terraform apply
EOF
exit 2
