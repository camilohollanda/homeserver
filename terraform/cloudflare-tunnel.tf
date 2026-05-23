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
  # Match the order from bootstrap/k3s/cloudflared-config.sh — cloudflared
  # evaluates ingress rules top-to-bottom, so the storage hostnames must
  # come before the *.werify.app wildcard.
  ingress_nginx_origin = "http://127.0.0.1:80"      # ingress-nginx on the k3s VM (loopback — cloudflared lives on same host)
  garage_s3_origin     = "http://192.168.20.22:3900" # Garage on the services VM, across the LAN

  tunnel_ingress = [
    { hostname = "storage.werify.app",         service = local.garage_s3_origin },
    { hostname = "storage-staging.werify.app", service = local.garage_s3_origin },
    { hostname = "storage.iddh.com.br",        service = local.garage_s3_origin },
    { hostname = "*.werify.app",               service = local.ingress_nginx_origin },
    { hostname = "werify.app",                 service = local.ingress_nginx_origin },
    { hostname = "*.prakash.com.br",           service = local.ingress_nginx_origin },
    { hostname = "prakash.com.br",             service = local.ingress_nginx_origin },
    { hostname = "membros.iddh.com.br",        service = local.ingress_nginx_origin },
    { service  = "http_status:404" },
  ]
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homeserver" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homeserver.id

  config = {
    ingress = local.tunnel_ingress
  }
}
