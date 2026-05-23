######################################################################
# Cloudflare WAF — Garage S3 endpoints
#
# Garage's S3 endpoint is exposed publicly through the tunnel at:
#   - storage.werify.app, storage-staging.werify.app  (werify.app zone)
#   - storage.iddh.com.br                              (iddh.com.br zone)
#
# Garage authenticates every request via SigV4 — wrong signature = 403.
# Brute-forcing a 40+ char secret key is infeasible, so the goal of these
# rules is NOT to prevent credential guessing. It's to drop unauthenticated
# probing traffic at the CF edge before it reaches the VM (cheap, removes
# log noise + CPU cost).
#
# Rate limiting was intentionally NOT added: S3 multipart uploads burst
# 100s of requests in seconds, and the CF free-tier rate-limit window is
# too short to distinguish legitimate burst traffic from abuse. If we ever
# observe scanner abuse worth blocking by rate, add a ruleset with phase =
# "http_ratelimit" and a generous threshold (e.g. 1000+ req / 60s / IP) —
# see git history for an earlier draft.
#
# Each ruleset is zone-scoped, so we declare one per affected zone.
######################################################################

# ===== PAUSED ========================================================
# Both WAF rulesets below are intentionally commented out while we
# validate the Garage public endpoints (storage-staging.werify.app etc.)
# with real client traffic. They block any request that isn't SigV4-signed,
# which is great for production but interferes with health checks, browser
# probes, and any debugging that uses unsigned requests.
#
# To reactivate: uncomment the two resource blocks below, then run
#   terraform apply
# The rulesets recreate idempotently — no state surgery needed.
# =====================================================================

# -----------------------------------------------------------------------
# werify.app — storage.werify.app + storage-staging.werify.app
# -----------------------------------------------------------------------

# resource "cloudflare_ruleset" "garage_waf_werify" {
#   zone_id = var.cloudflare_zone_ids["werify_app"]
#   name    = "garage-storage-protection"
#   kind    = "zone"
#   phase   = "http_request_firewall_custom"
#
#   rules = [{
#     description = "block unsigned requests to S3 endpoints"
#     # Match storage hostnames where the request carries neither a SigV4
#     # Authorization header (regular signed requests) nor an X-Amz-Algorithm
#     # query param (presigned URL requests). Anything else is junk traffic.
#     expression = <<-EOT
#       (http.host in {"storage.werify.app" "storage-staging.werify.app"})
#       and not (any(http.request.headers["authorization"][*] contains "AWS4-HMAC-SHA256"))
#       and not (http.request.uri.query contains "X-Amz-Algorithm")
#     EOT
#     action  = "block"
#     enabled = true
#   }]
# }

# -----------------------------------------------------------------------
# iddh.com.br — storage.iddh.com.br
# -----------------------------------------------------------------------

# resource "cloudflare_ruleset" "garage_waf_iddh" {
#   zone_id = var.cloudflare_zone_ids["iddh_com_br"]
#   name    = "garage-storage-protection"
#   kind    = "zone"
#   phase   = "http_request_firewall_custom"
#
#   rules = [{
#     description = "block unsigned requests to S3 endpoints"
#     expression  = <<-EOT
#       (http.host eq "storage.iddh.com.br")
#       and not (any(http.request.headers["authorization"][*] contains "AWS4-HMAC-SHA256"))
#       and not (http.request.uri.query contains "X-Amz-Algorithm")
#     EOT
#     action  = "block"
#     enabled = true
#   }]
# }
