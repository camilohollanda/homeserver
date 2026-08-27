######################################################################
# Cloudflare Tunnel: homeserver
#
# The tunnel itself was originally created with `cloudflared tunnel create`
# on the k3s VM (locally-managed). We import the existing tunnel here and
# switch it to remotely-managed so its ingress config lives in this file
# instead of /etc/cloudflared/config.yml.
#
# After the flip:
#   - cloudflared on the VM pulls config from Cloudflare on startup and
#     live-reloads on change
#   - the on-disk /etc/cloudflared/config.yml is ignored
#   - `terraform apply` is the only way ingress routes change
######################################################################

resource "cloudflare_zero_trust_tunnel_cloudflared" "homeserver" {
  account_id = var.cloudflare_account_id
  name       = "homeserver"
  config_src = "cloudflare" # remotely-managed; switch from "local" happens on first apply post-import
}

locals {
  ingress_nginx_origin = "http://127.0.0.1:80" # ingress-nginx on the k3s VM (loopback — cloudflared lives on same host)

  tunnel_ingress = [
    { hostname = "*.werify.app", service = local.ingress_nginx_origin },
    { hostname = "werify.app", service = local.ingress_nginx_origin },
    { hostname = "*.prakash.com.br", service = local.ingress_nginx_origin },
    { hostname = "prakash.com.br", service = local.ingress_nginx_origin },
    { hostname = "membros.iddh.com.br", service = local.ingress_nginx_origin },

    # iddh.com.br moves off Hostinger and onto the app (see the members repo,
    # docs/host-topology.md). One Phoenix deployment serves all of these:
    # the apex is the institutional site, membros. the members app, and the
    # wildcard covers the event vanity subdomains (simposio26.iddh.com.br),
    # which have never resolved in production. The explicit membros. entry
    # stays ABOVE the wildcard — cloudflared matches in order.
    { hostname = "iddh.com.br", service = local.ingress_nginx_origin },
    { hostname = "www.iddh.com.br", service = local.ingress_nginx_origin },
    { hostname = "*.iddh.com.br", service = local.ingress_nginx_origin },

    { service = "http_status:404" },
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homeserver" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homeserver.id

  config = {
    ingress = local.tunnel_ingress
  }
}
