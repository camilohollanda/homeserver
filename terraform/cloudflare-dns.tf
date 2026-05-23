######################################################################
# Cloudflare DNS records
#
# Replaces the per-script `ensure_a_record` / `create_dns_route` helpers
# in bootstrap/*/setup.sh and bootstrap/k3s/cloudflared-config.sh.
#
# Two record families:
#   1. Public CNAMEs pointing at the tunnel (proxied via Cloudflare)
#   2. Internal A-records for LAN-only services on internal.prakash.com.br
#      (NOT proxied — they must resolve to RFC1918 IPs reachable from the LAN)
######################################################################

locals {
  tunnel_cname_target = "${cloudflare_zero_trust_tunnel_cloudflared.homeserver.id}.cfargotunnel.com"

  services_vm_ip = "192.168.20.22" # vmid 114
  postgres_vm_ip = "192.168.20.21" # vmid 113
  ai_vm_ip       = "192.168.20.30" # vmid 115
  media_vm_ip    = "192.168.20.40" # vmid 116

  # Public CNAMEs that route through the tunnel.
  # Order doesn't matter here (it's a map), but the corresponding tunnel
  # ingress rules in cloudflare-tunnel.tf must be ordered correctly.
  public_tunnel_records = {
    werify_apex        = { zone = "werify_app",     name = "werify.app" }
    werify_wildcard    = { zone = "werify_app",     name = "*.werify.app" }
    prakash_apex       = { zone = "prakash_com_br", name = "prakash.com.br" }
    prakash_wildcard   = { zone = "prakash_com_br", name = "*.prakash.com.br" }
    membros_iddh       = { zone = "iddh_com_br",    name = "membros.iddh.com.br" }
    storage_iddh       = { zone = "iddh_com_br",    name = "storage.iddh.com.br" }
    # storage.werify.app and storage-staging.werify.app are covered by *.werify.app — no separate record
  }

  # Internal LAN A-records on internal.prakash.com.br.
  # All not proxied (Cloudflare cannot proxy to RFC1918).
  internal_a_records = {
    # services VM (vmid 114) — multi-tenant docker host behind shared nginx
    garage    = { name = "garage.internal.prakash.com.br",    ip = local.services_vm_ip }
    mailpit   = { name = "mailpit.internal.prakash.com.br",   ip = local.services_vm_ip }
    infisical = { name = "infisical.internal.prakash.com.br", ip = local.services_vm_ip }
    gha_cache = { name = "gha-cache.internal.prakash.com.br", ip = local.services_vm_ip }

    # dedicated VMs
    pg = { name = "pg.internal.prakash.com.br", ip = local.postgres_vm_ip }
    ai = { name = "ai.internal.prakash.com.br", ip = local.ai_vm_ip }

    # media stack (vmid 116, all share one VM behind a local nginx)
    jellyfin = { name = "jellyfin.internal.prakash.com.br", ip = local.media_vm_ip }
    torrent  = { name = "torrent.internal.prakash.com.br",  ip = local.media_vm_ip }
    radarr   = { name = "radarr.internal.prakash.com.br",   ip = local.media_vm_ip }
    sonarr   = { name = "sonarr.internal.prakash.com.br",   ip = local.media_vm_ip }
    bazarr   = { name = "bazarr.internal.prakash.com.br",   ip = local.media_vm_ip }
    prowlarr = { name = "prowlarr.internal.prakash.com.br", ip = local.media_vm_ip }
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
