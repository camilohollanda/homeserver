######################################################################
# Cloudflare Access (Zero Trust) — staging app gating
#
# staging.werify.app and iddh-members-staging.prakash.com.br ride the
# SAME tunnel + ingress-nginx as production (see cloudflare-tunnel.tf:
# the *.werify.app / *.prakash.com.br wildcards), so until now they were
# reachable by anyone on the public internet.
#
# These Access apps gate them at the Cloudflare edge — no tunnel, DNS, or
# ingress changes needed. Per host we register two Access "applications":
#
#   <host>/<webhook_path>  -> Bypass  (no auth — payment webhooks from
#                                Asaas / PagBank. Asaas signs with the
#                                `asaas-access-token` header, PagBank with
#                                `x-payload-signature`; the APP validates
#                                those, so the open path is safe.)
#   <host>                 -> Allow   (catch-all gate: by default requires an
#                                enrolled Cloudflare WARP device — IP-
#                                independent, so a dynamic home IP is fine.
#                                Optionally also allow a static IP / identity.)
#
# Cloudflare evaluates the MOST SPECIFIC path first, so the webhook
# bypass wins over the catch-all gate for webhook POSTs.
#
# OAuth login needs nothing special: the standard Authorization-Code flow
# is browser-driven (the provider redirects the user's browser, it never
# calls in), so anyone already inside the gate logs in normally.
######################################################################

locals {
  # Staging hosts to gate. Production is intentionally left public.
  # webhook_path is the per-app prefix (no slashes at either end) under which
  # payment webhooks are served — everything under it bypasses the gate
  # without Access auth (the app verifies the provider signature/token).
  # The two apps disagree: werify mounts webhooks under /api, iddh doesn't.
  staging_gated_hosts = {
    werify_staging = { domain = "staging.werify.app", webhook_path = "api/webhooks" }
    iddh_staging   = { domain = "iddh-members-staging.prakash.com.br", webhook_path = "webhooks" }
  }

  # Optional alternative ways in, OR-ed alongside WARP via a SEPARATE allow
  # policy (staging_identity below). Each entry is its own "allow from": a
  # static egress IP (silent, no login) or an email (Access login / OTP).
  # Leave both unset to gate purely on WARP.
  staging_identity_include = concat(
    [for cidr in var.staging_allow_ip_cidrs : { ip = { ip = cidr } }],
    var.staging_access_email == "" ? [] : [{ email = { email = var.staging_access_email } }],
  )

  # Every allow policy attached to the gate app. A request gets in if it
  # matches ANY of them — Cloudflare OR-s policies — so the WARP device check
  # and the explicit identities/IPs are true alternatives, not a combined
  # requirement. (Putting both in one policy's `include` + `require` would AND
  # them instead — the bug this two-policy structure avoids.)
  staging_gate_policy_ids = concat(
    cloudflare_zero_trust_access_policy.staging_warp[*].id,
    cloudflare_zero_trust_access_policy.staging_identity[*].id,
  )
}

# --- Device posture ---------------------------------------------------

# "Is this request coming from a device running our enrolled WARP client?"
# type = "warp" takes no input. Created only when WARP gating is enabled.
resource "cloudflare_zero_trust_device_posture_rule" "warp" {
  count = var.staging_gate_via_warp ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "staging gate — require WARP"
  type       = "warp"
}

# --- Reusable policies ------------------------------------------------

# Let payment webhooks through with no authentication.
resource "cloudflare_zero_trust_access_policy" "staging_webhook_bypass" {
  account_id = var.cloudflare_account_id
  name       = "staging — payment webhook bypass"
  decision   = "bypass"

  include = [{
    everyone = {}
  }]
}

# Allow gate #1 — any device running our enrolled WARP client. IP-independent,
# so a dynamic home/ISP IP is a non-issue: include = everyone, then `require`
# the WARP posture (everyone who ALSO passes posture). Created only when WARP
# gating is enabled.
resource "cloudflare_zero_trust_access_policy" "staging_warp" {
  count = var.staging_gate_via_warp ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "staging — require WARP device"
  decision   = "allow"

  include = [{ everyone = {} }]
  require = [{
    device_posture = { integration_uid = cloudflare_zero_trust_device_posture_rule.warp[0].id }
  }]
}

# Allow gate #2 — explicit egress IPs / identities, OR-ed alongside the WARP
# policy above (a separate policy = OR; the same policy with `require` = AND).
# No WARP requirement here, so these get in whether or not they're on WARP.
# Created only when staging_allow_ip_cidrs / staging_access_email are set.
resource "cloudflare_zero_trust_access_policy" "staging_identity" {
  count = length(local.staging_identity_include) > 0 ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "staging — allowed identities / IPs"
  decision   = "allow"

  include = local.staging_identity_include
}

# --- Applications (one bypass + one gate per host) --------------------

# Bypass app: <host>/webhooks  (more specific path → evaluated first)
resource "cloudflare_zero_trust_access_application" "staging_webhooks" {
  for_each = local.staging_gated_hosts

  account_id           = var.cloudflare_account_id
  name                 = "${each.value.domain} — webhooks (bypass)"
  domain               = "${each.value.domain}/${each.value.webhook_path}"
  type                 = "self_hosted"
  session_duration     = "24h"
  app_launcher_visible = false

  policies = [{
    id         = cloudflare_zero_trust_access_policy.staging_webhook_bypass.id
    precedence = 1
  }]
}

# Gate app: <host>  (catch-all)
resource "cloudflare_zero_trust_access_application" "staging_gate" {
  for_each = local.staging_gated_hosts

  account_id                = var.cloudflare_account_id
  name                      = "${each.value.domain} — internal only"
  domain                    = each.value.domain
  type                      = "self_hosted"
  session_duration          = "24h"
  app_launcher_visible      = false
  auto_redirect_to_identity = true

  # Allow if ANY attached policy matches (a WARP device, or a listed identity/
  # IP). Precedence is just the list order — among allow-only policies it has
  # no effect on the outcome.
  policies = [
    for i, pid in local.staging_gate_policy_ids : { id = pid, precedence = i + 1 }
  ]

  lifecycle {
    precondition {
      # Block the foot-gun: WARP off AND no identity/IP would leave the gate
      # with zero allow policies (Cloudflare also rejects an app with none).
      condition     = length(local.staging_gate_policy_ids) > 0
      error_message = "Staging gate would have no allow policy. Keep staging_gate_via_warp = true (default), or set staging_allow_ip_cidrs / staging_access_email."
    }
  }
}
