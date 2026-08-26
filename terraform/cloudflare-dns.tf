######################################################################
# Cloudflare DNS records
#
# Replaces the per-script `ensure_a_record` / `create_dns_route` helpers
# in bootstrap/*/setup.sh and bootstrap/k3s/cloudflared-config.sh.
#
# Three record families:
#   1. Public CNAMEs pointing at the tunnel (proxied via Cloudflare)
#   2. Internal A-records for LAN-only services on internal.prakash.com.br
#      (NOT proxied — they must resolve to RFC1918 IPs reachable from the LAN)
#   3. DNS-AID agent discovery records under _agents.werify.app
######################################################################

locals {
  tunnel_cname_target = "${cloudflare_zero_trust_tunnel_cloudflared.homeserver.id}.cfargotunnel.com"

  services_vm_ip    = "192.168.20.22" # vmid 114
  k3s_vm_ip         = "192.168.20.11" # vmid 112
  postgres_vm_ip    = "192.168.20.21" # vmid 113 (PG 17)
  postgres_18_vm_ip = "192.168.20.23" # vmid 118 (PG 18)
  ai_vm_ip          = "192.168.20.30" # vmid 115
  media_vm_ip       = "192.168.20.40" # vmid 116
  forgejo_vm_ip     = "192.168.20.24" # vmid 119

  # Public CNAMEs that route through the tunnel.
  # Order doesn't matter here (it's a map), but the corresponding tunnel
  # ingress rules in cloudflare-tunnel.tf must be ordered correctly.
  public_tunnel_records = {
    werify_apex      = { zone = "werify_app", name = "werify.app" }
    werify_wildcard  = { zone = "werify_app", name = "*.werify.app" }
    prakash_apex     = { zone = "prakash_com_br", name = "prakash.com.br" }
    prakash_wildcard = { zone = "prakash_com_br", name = "*.prakash.com.br" }
    membros_iddh     = { zone = "iddh_com_br", name = "membros.iddh.com.br" }
  }

  # Internal LAN A-records on internal.prakash.com.br.
  # All not proxied (Cloudflare cannot proxy to RFC1918).
  internal_a_records = {
    # services VM (vmid 114) — multi-tenant docker host behind shared nginx
    garage    = { name = "garage.internal.prakash.com.br", ip = local.services_vm_ip }
    garage_ui = { name = "garage-ui.internal.prakash.com.br", ip = local.services_vm_ip }
    infisical = { name = "infisical.internal.prakash.com.br", ip = local.services_vm_ip }
    gha_cache = { name = "gha-cache.internal.prakash.com.br", ip = local.services_vm_ip }

    # k3s-apps (vmid 112) — HTTP via ingress-nginx, SMTP via K3s ServiceLB
    mailpit = { name = "mailpit.internal.prakash.com.br", ip = local.k3s_vm_ip }

    # dedicated VMs
    #
    # `pg` must NOT be repointed at 118 to perform the upgrade cutover — six of
    # the nine live connection strings resolve through it, so moving it migrates
    # every app at once. Apps move to `pg18` one at a time instead, by
    # repointing their own DATABASE_URL.
    pg   = { name = "pg.internal.prakash.com.br", ip = local.postgres_vm_ip }
    pg18 = { name = "pg18.internal.prakash.com.br", ip = local.postgres_18_vm_ip }
    ai   = { name = "ai.internal.prakash.com.br", ip = local.ai_vm_ip }

    # Forgejo (vmid 119) — LAN only, deliberately. The repo sync polls GitHub
    # outbound, so nothing ever needs to reach this host from the internet and
    # no tunnel route exists for it.
    forgejo = { name = "forgejo.internal.prakash.com.br", ip = local.forgejo_vm_ip }

    # media stack (vmid 116, all share one VM behind a local nginx)
    jellyfin = { name = "jellyfin.internal.prakash.com.br", ip = local.media_vm_ip }
    torrent  = { name = "torrent.internal.prakash.com.br", ip = local.media_vm_ip }
    radarr   = { name = "radarr.internal.prakash.com.br", ip = local.media_vm_ip }
    sonarr   = { name = "sonarr.internal.prakash.com.br", ip = local.media_vm_ip }
    bazarr   = { name = "bazarr.internal.prakash.com.br", ip = local.media_vm_ip }
    prowlarr = { name = "prowlarr.internal.prakash.com.br", ip = local.media_vm_ip }
    home     = { name = "home.internal.prakash.com.br", ip = local.media_vm_ip }
  }

  # DNS-AID agent discovery (draft-mozleywilliams-dnsop-dnsaid), one
  # ServiceMode SVCB per agent-facing protocol werify.app actually serves.
  #
  # The target is the apex for both: the MCP server is a path on it
  # (https://werify.app/mcp), not a host of its own, so the record carries the
  # connection parameters and /.well-known/api-catalog (RFC 9727) carries the
  # rest.
  #
  # There is deliberately no `_a2a` leaf — werify.app does not speak A2A, and
  # a record here is an affirmative answer to "do you?".
  #
  # Publishing anything under `_agents` also makes `_agents.werify.app` an
  # empty non-terminal, which stops the proxied `*.werify.app` wildcard from
  # answering underneath it (RFC 4592). That is half the point: the wildcard
  # makes Cloudflare synthesize a generic edge HTTPS RR at *every* `_*._agents`
  # name — target ".", no `mandatory`, no custom params — and scanners read
  # those as DNS-AID records they are not. `_a2a._agents.werify.app` answering
  # at all today is that artifact, not a decision.
  #
  # TTLs follow draft §5.2.2: longer on the stable entry point, shorter on the
  # leaf that would move first.
  dnsaid_records = {
    index = { name = "_index._agents.werify.app", ttl = 3600 }
    mcp   = { name = "_mcp._agents.werify.app", ttl = 600 }
  }
}

resource "cloudflare_dns_record" "public_tunnel" {
  for_each = local.public_tunnel_records

  zone_id = var.cloudflare_zone_ids[each.value.zone]
  name    = each.value.name
  type    = "CNAME"
  content = local.tunnel_cname_target
  ttl     = 1 # 1 = "automatic" (required when proxied=true)
  proxied = true
  comment = "managed by terraform — homeserver tunnel"
}

resource "cloudflare_dns_record" "internal_a" {
  for_each = local.internal_a_records

  # internal.prakash.com.br is NOT its own zone — these are records inside
  # the prakash.com.br zone with multi-segment names.
  zone_id = var.cloudflare_zone_ids["prakash_com_br"]
  name    = each.value.name
  type    = "A"
  content = each.value.ip
  ttl     = 1
  proxied = false # LAN-only, must NOT be proxied
  comment = "managed by terraform — internal LAN service"
}

resource "cloudflare_dns_record" "dnsaid" {
  for_each = local.dnsaid_records

  zone_id = var.cloudflare_zone_ids["werify_app"]
  name    = each.value.name
  type    = "SVCB"
  ttl     = each.value.ttl

  # No `proxied` — SVCB is discovery metadata for agents, not a hostname a
  # browser resolves. There is nothing here for the edge to sit in front of.

  data = {
    priority = 1 # >0 = ServiceMode; 0 would be AliasMode
    target   = "werify.app."

    # `alpn` is the real TLS ALPN token set (RFC 9460 §7.1), not the agent
    # protocol — that is already carried by the `_mcp` label. The draft's §4.2
    # example (`alpn="a2a"`) contradicts its own zonefile in §5.2.3; §5.2.3 is
    # the one RFC 9460 actually permits, so that is what we publish.
    #
    # No experimental keyNNNNN params: the draft's `cap`/`well-known` key
    # numbers are explicitly illustrative and unregistered, so anything we put
    # there would be a number we made up.
    #
    # Every param value is quoted, including `port` and `mandatory`, because
    # that is the form Cloudflare stores and returns. RFC 9460 §2.1 treats
    # `port=443` and `port="443"` as equivalent, but writing the bare form here
    # produced a perpetual diff: Terraform proposed the unquoted string on every
    # plan and Cloudflare normalised it straight back. Match the server's form.
    value = "alpn=\"h2,h3\" port=\"443\" mandatory=\"alpn,port\""
  }

  comment = "managed by terraform — DNS-AID agent discovery"
}
