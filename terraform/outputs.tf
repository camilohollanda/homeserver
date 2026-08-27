output "k3s_vm_ip" {
  description = "IP address for the K3s node"
  value       = split("/", local.k3s_vm.ip_cidr)[0]
}

output "db_vm_ip" {
  description = "IP address for the Postgres node (VM 118, PG 18 — the only one since VM 113 was decommissioned)"
  value       = split("/", local.db_vm_18.ip_cidr)[0]
}

output "services_vm_ip" {
  description = "IP address for the Infisical node"
  value       = split("/", local.services_vm.ip_cidr)[0]
}

output "infisical_url" {
  description = "URL to access Infisical UI"
  value       = "https://${split("/", local.services_vm.ip_cidr)[0]}:8443"
}

output "ai_vm_ip" {
  description = "IP address for the Whisper GPU inference server"
  value       = split("/", local.ai_vm.ip_cidr)[0]
}

output "whisper_api_url" {
  description = "URL for Whisper transcription API"
  value       = "http://${split("/", local.ai_vm.ip_cidr)[0]}:8000"
}

output "media_server_ip" {
  description = "IP address for the media server"
  value       = split("/", local.media_vm.ip_cidr)[0]
}

output "media_services" {
  description = "Local URLs for media services"
  value = {
    jellyfin    = "http://${split("/", local.media_vm.ip_cidr)[0]}:8096"
    qbittorrent = "http://${split("/", local.media_vm.ip_cidr)[0]}:8080"
    radarr      = "http://${split("/", local.media_vm.ip_cidr)[0]}:7878"
    sonarr      = "http://${split("/", local.media_vm.ip_cidr)[0]}:8989"
  }
}

output "gh_runners_vm_ip" {
  description = "IP address for the GitHub Actions self-hosted runners VM"
  value       = split("/", local.gh_runners_vm.ip_cidr)[0]
}

output "media_proxy_urls" {
  description = "Local domain URLs via reverse proxy (no ports)"
  value = {
    jellyfin    = "http://${var.media_jellyfin_domain}"
    qbittorrent = "http://${var.media_qbittorrent_domain}"
    radarr      = "http://${var.media_radarr_domain}"
    sonarr      = "http://${var.media_sonarr_domain}"
    prowlarr    = "http://${var.media_prowlarr_domain}"
    bazarr      = "http://${var.media_bazarr_domain}"
  }
}
