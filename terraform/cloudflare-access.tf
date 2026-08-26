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
#   <host>/<public_path>   -> Bypass  (no auth — the MCP connector surface
#                                Claude.ai / ChatGPT call server-to-server;
#                                see `public_paths` in the locals.)
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
  #
  # public_paths are further prefixes that bypass the gate for the same
  # reason: something that is NOT a person's browser must reach them. For
  # werify that is the MCP connector surface — Claude.ai / ChatGPT call these
  # server-to-server from their own backends (no WARP, no fixed egress IP),
  # so gating them makes a staging MCP connection impossible. Each is already
  # public on production and guards itself: `/mcp` demands a bearer token,
  # `/oauth/token` a code + PKCE verifier, `/media` the same bearer or a
  # session; `/register` (RFC 7591 dynamic client registration) and the two
  # `/.well-known` documents are public metadata by design. The browser half
  # of OAuth (`/oauth/authorize`, the consent screen) stays behind the gate —
  # that one IS a person, on WARP.
  staging_gated_hosts = {
    werify_staging = {
      domain       = "staging.werify.app"
      webhook_path = "api/webhooks"
      public_paths = [
        "mcp",
        ".well-known/oauth-protected-resource",
        ".well-known/oauth-authorization-server",
        "register",
        "oauth/token",
        "media",
      ]
    }
    iddh_staging = {
      domain       = "iddh-members-staging.prakash.com.br"
      webhook_path = "webhooks"
      public_paths = []
    }
  }

  # One (host, path) pair per public path, flattened for a for_each. Keys are
  # stable (host key + path) so adding a path never recreates the others.
  staging_public_paths = merge([
    for host_key, host in local.staging_gated_hosts : {
      for path in host.public_paths :
      "${host_key}/${path}" => { domain = host.domain, path = path }
    }
  ]...)

  # Optional alternative ways in, OR-ed alongside WARP as SEPARATE policies.
  #
  #   * static egress IP(s) -> a BYPASS policy (staging_ip_bypass): matching IPs
  #     reach the app with NO Access login. This MUST be `bypass`, not `allow`:
  #     an Allow policy with an IP include still forces the user to authenticate
  #     (the IP only narrows WHO may log in — auth_status stays NONE and the
  #     edge 302s to the login). Only Bypass exempts a request from auth. WARP
  #     stays silent under `allow` because the WARP client supplies an identity
  #     (allow_authenticate_via_warp); a bare IP supplies none.
  #   * an email -> an ALLOW policy (staging_identity): email IS an identity, so
  #     it SHOULD prompt an Access login / OTP.
  #
  # Leave both unset to gate purely on WARP.
  staging_ip_bypass_include = [for cidr in var.staging_allow_ip_cidrs : { ip = { ip = cidr } }]
  staging_identity_include  = var.staging_access_email == "" ? [] : [{ email = { email = var.staging_access_email } }]

  # Every policy attached to the gate app. A request gets in if it matches ANY
  # of them — Cloudflare OR-s policies — so the IP bypass, the WARP device
  # check, and the email identity are true alternatives, not a combined
  # requirement. Bypass is listed first (highest precedence) so a matching IP
  # short-circuits to no-login before the auth-requiring allow policies.
  staging_gate_policy_ids = concat(
    cloudflare_zero_trust_access_policy.staging_ip_bypass[*].id,
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

# Let the self-authenticating paths through with no Access authentication —
# payment webhooks and the MCP connector surface alike (both applications
# below attach this one policy).
resource "cloudflare_zero_trust_access_policy" "staging_webhook_bypass" {
  account_id = var.cloudflare_account_id
  name       = "staging — self-authenticating paths bypass (webhooks, MCP)"
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

# Bypass gate — explicit egress IP(s) reach the app with NO Access login. A
# separate policy = OR-ed alongside the WARP/identity allows. Bypass (not allow)
# is what makes it silent — see the locals note above. No WARP requirement, so
# these get in whether or not they're on WARP. Created only when
# staging_allow_ip_cidrs is set (e.g. via ./allow-my-egress-ip.sh).
resource "cloudflare_zero_trust_access_policy" "staging_ip_bypass" {
  count = length(local.staging_ip_bypass_include) > 0 ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "staging — allowed egress IPs (no login)"
  decision   = "bypass"

  include = local.staging_ip_bypass_include
}

# Allow gate #2 — explicit email identities, OR-ed alongside the WARP policy
# above (a separate policy = OR; the same policy with `require` = AND). Email is
# an identity, so unlike the IP bypass these DO prompt an Access login / OTP.
# Created only when staging_access_email is set.
resource "cloudflare_zero_trust_access_policy" "staging_identity" {
  count = length(local.staging_identity_include) > 0 ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "staging — allowed email identities"
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

# Bypass app: <host>/<public path>  (the MCP connector surface; the same
# "everyone" bypass policy as the webhooks — the app authenticates the path)
resource "cloudflare_zero_trust_access_application" "staging_public_paths" {
  for_each = local.staging_public_paths

  account_id           = var.cloudflare_account_id
  name                 = "${each.value.domain} — /${each.value.path} (bypass)"
  domain               = "${each.value.domain}/${each.value.path}"
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

  # Reuse the WARP enrollment as the Access identity: devices already on our
  # WARP get in silently instead of being bounced to the email-OTP login.
  # Needs the account-level twin switch too (allow_authenticate_via_warp on
  # the Zero Trust organization — dashboard-managed, like the rest of WARP).
  allow_authenticate_via_warp = true

  # Allow if ANY attached policy matches (a WARP device, or a listed identity/
  # IP). Precedence is just the list order — among allow-only policies it has
  # no effect on the outcome.
  policies = [
    for i, pid in local.staging_gate_policy_ids : { id = pid, precedence = i + 1 }
  ]

  lifecycle {
    precondition {
      # Block the foot-gun: WARP off AND no identity/IP would leave the gate
      # with zero policies (Cloudflare also rejects an app with none).
      condition     = length(local.staging_gate_policy_ids) > 0
      error_message = "Staging gate would have no policy. Keep staging_gate_via_warp = true (default), or set staging_allow_ip_cidrs / staging_access_email."
    }
  }
}
