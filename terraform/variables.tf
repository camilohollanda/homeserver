variable "pm_api_url" {
  description = "Proxmox API endpoint, e.g. https://proxmox.example.com:8006/api2/json"
  type        = string
  default     = ""
}

variable "pm_api_token_id" {
  description = "Proxmox API token ID (user@realm!token)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pm_api_token_secret" {
  description = "Proxmox API token secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pm_tls_insecure" {
  description = "Allow insecure TLS for Proxmox API"
  type        = bool
  default     = false
}

variable "pm_node" {
  description = "Target Proxmox node name"
  type        = string
  default     = ""
}

variable "template_name" {
  description = "Cloud-init ready template name to clone"
  type        = string
  default     = ""
}

variable "template_vmid" {
  description = "Cloud-init ready template VM ID to clone (Debian 13)"
  type        = number
  default     = 9001
}

variable "template_vmid_debian12" {
  description = "Debian 12 cloud-init template VM ID (for PyTorch/GPU workloads)"
  type        = number
  default     = 9002
}

variable "template_vmid_debian12_nvidia" {
  description = "Debian 12 + NVIDIA drivers template VM ID (for GPU passthrough)"
  type        = number
  default     = 9003
}

variable "storage" {
  description = "Proxmox storage pool for disks (e.g. local-lvm)"
  type        = string
  default     = "local-lvm"
}

variable "tank_storage" {
  description = "Proxmox storage backed by the 4TB ZFS pool 'tank' (bulk data disks)"
  type        = string
  default     = "tank-vm"
}

variable "bridge" {
  description = "Proxmox network bridge (e.g. vmbr0)"
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "Default gateway for VMs (CIDR gateway)"
  type        = string
  default     = ""
}

variable "nameserver" {
  description = "DNS nameserver for cloud-init"
  type        = string
  default     = "1.1.1.1"
}

variable "searchdomain" {
  description = "DNS search domain for cloud-init"
  type        = string
  default     = ""
}

variable "cloud_init_user" {
  description = "Default user provisioned via cloud-init"
  type        = string
  default     = "deployer"
}

variable "ssh_public_keys" {
  description = "SSH public keys injected via cloud-init (can be set via TF_VAR_ssh_public_keys as comma-separated string or JSON array)"
  type        = list(string)
  default     = []
}

# Infisical configuration
variable "infisical_postgres_db" {
  description = "PostgreSQL database name for Infisical"
  type        = string
  default     = "infisical"
}

variable "infisical_postgres_user" {
  description = "PostgreSQL username for Infisical"
  type        = string
  default     = "infisical"
}

variable "infisical_postgres_password" {
  description = "PostgreSQL password for Infisical"
  type        = string
  sensitive   = true
}

variable "infisical_encryption_key" {
  description = "Infisical encryption key (32 hex chars). Generate with: openssl rand -hex 16"
  type        = string
  sensitive   = true
}

variable "infisical_auth_secret" {
  description = "Infisical auth secret for JWT signing. Generate with: openssl rand -base64 32"
  type        = string
  sensitive   = true
}

variable "infisical_domain" {
  description = "Domain for Infisical (e.g., infisical.internal.example.com)"
  type        = string
  default     = "infisical.internal.prakash.com.br"
}

variable "snippets_storage" {
  description = "Proxmox storage for cloud-init snippets (must have 'snippets' content type enabled)"
  type        = string
  default     = "local"
}

variable "pm_ssh_user" {
  description = "SSH username for Proxmox host (for uploading cloud-init snippets)"
  type        = string
  default     = "root"
}

# Let's Encrypt / Cloudflare configuration (shared)
variable "cloudflare_api_token" {
  description = "Cloudflare API token used by Terraform only (NOT distributed to the VMs — those use the separate CF_API_TOKEN env var for certbot DNS-01, see bootstrap/*/install.sh). Needs: Zone.DNS Edit, Zone.Zone Read, Account.Cloudflare Tunnel Edit, Account.Access: Apps and Policies Edit, Account.Zero Trust Edit (last two for cloudflare-access.tf — note the device-posture endpoint wants 'Zero Trust', not 'Access: Device Posture')."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (find under any zone's overview page). Required for the tunnel resource."
  type        = string
}

variable "cloudflare_zone_ids" {
  description = <<-EOT
    Map of zone name -> zone ID. Copy from the CF dashboard (any zone's overview page).
    The keys are referenced from cloudflare-dns.tf, so don't rename them without updating
    that file.

    Note: internal.prakash.com.br is NOT a separate zone — those records live inside
    the prakash.com.br zone as A-records with multi-segment names.
  EOT
  type = object({
    werify_app     = string
    iddh_com_br    = string
    prakash_com_br = string
  })
}

variable "cloudflare_tunnel_id" {
  description = "ID of the existing homeserver tunnel (read from /etc/cloudflared/config.yml on the k3s VM). Populated at import time."
  type        = string
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt certificate notifications"
  type        = string
}

# AI Services configuration (Whisper + Ollama/Qwen)
variable "ai_domain" {
  description = "Domain for AI services API (e.g., ai.internal.example.com)"
  type        = string
  default     = "ai.internal.prakash.com.br"
}

variable "ai_github_owner" {
  description = "GitHub owner/org for whisper-api repository (e.g., 'myusername')"
  type        = string
}

variable "ai_ghcr_token" {
  description = "GitHub PAT with packages:read scope for pulling whisper-api image from GHCR"
  type        = string
  sensitive   = true
}

variable "ai_ollama_model" {
  description = "Ollama model for translation (e.g., qwen2.5:3b)"
  type        = string
  default     = "qwen2.5:3b"
}

# PostgreSQL configuration
#
# These two are declarative documentation only — no Terraform resource reads
# them. The Postgres VM is configured by bootstrap/postgres/install.sh, which
# takes PG_VERSION and ALLOWED_NETWORK as environment variables. Kept in sync
# with the script's defaults so the intended topology is visible here.
variable "postgres_version" {
  description = "PostgreSQL version installed by bootstrap/postgres/install.sh"
  type        = string
  default     = "18"
}

variable "postgres_allowed_network" {
  description = "Network CIDR allowed to connect to PostgreSQL"
  type        = string
  default     = "192.168.20.0/24"
}

# Media stack configuration
variable "media_library_path" {
  description = "Host path used for shared movies/tv files"
  type        = string
  default     = "/srv/media"
}

variable "media_download_path" {
  description = "Host path used for completed and incoming torrent downloads"
  type        = string
  default     = "/srv/downloads"
}

variable "media_timezone" {
  description = "Timezone used in Jellyfin/qBittorrent/Radarr/Sonarr containers"
  type        = string
  default     = "UTC"
}

variable "media_uid" {
  description = "UID used inside container processes for media stack"
  type        = number
  default     = 1000
}

variable "media_gid" {
  description = "GID used inside container processes for media stack"
  type        = number
  default     = 1000
}

variable "media_jellyfin_domain" {
  description = "Local domain for Jellyfin (served via reverse proxy)"
  type        = string
  default     = "jellyfin.internal.prakash.com.br"
}

variable "media_qbittorrent_domain" {
  description = "Local domain for qBittorrent (served via reverse proxy)"
  type        = string
  default     = "torrent.internal.prakash.com.br"
}

variable "media_radarr_domain" {
  description = "Local domain for Radarr (served via reverse proxy)"
  type        = string
  default     = "radarr.internal.prakash.com.br"
}

variable "media_sonarr_domain" {
  description = "Local domain for Sonarr (served via reverse proxy)"
  type        = string
  default     = "sonarr.internal.prakash.com.br"
}

variable "media_prowlarr_domain" {
  description = "Local domain for Prowlarr (served via reverse proxy)"
  type        = string
  default     = "prowlarr.internal.prakash.com.br"
}

variable "media_bazarr_domain" {
  description = "Local domain for Bazarr (served via reverse proxy)"
  type        = string
  default     = "bazarr.internal.prakash.com.br"
}

# Cloudflare Access — staging gating (see cloudflare-access.tf)
variable "staging_gate_via_warp" {
  description = <<-EOT
    Gate the staging apps on Cloudflare WARP enrollment: only devices running
    your enrolled WARP client reach them. IP-independent, so a dynamic home/ISP
    IP is fine. Creates a device-posture rule (type "warp") and requires it on
    the staging allow policy. Set false to gate purely by IP/identity instead
    (then set staging_allow_ip_cidrs and/or staging_access_email).
  EOT
  type        = bool
  default     = true
}

variable "staging_allow_ip_cidrs" {
  description = <<-EOT
    Public egress IP(s), as CIDRs, that reach the staging apps with NO Access
    login (your home/LAN egress, since the apps ride the Cloudflare tunnel so
    Cloudflare sees the public source IP, not the RFC1918 address). Example:
    ["203.0.113.4/32"]. Find yours with `curl -s https://ifconfig.me`.
    Optional: OR-ed alongside the WARP gate via a separate Access policy, so
    these get in whether or not they're on WARP. Leave empty to gate on WARP
    only (the default).
  EOT
  type        = list(string)
  default     = []
}

variable "staging_access_email" {
  description = <<-EOT
    Email allowed to authenticate to the staging apps from anywhere via
    Cloudflare Access (one-time-PIN or your configured IdP). OR-ed alongside
    the WARP gate via a separate Access policy. Silent when the device is
    WARP-enrolled with the same IdP. Set "" to gate on WARP (and/or
    staging_allow_ip_cidrs) only.
  EOT
  type        = string
  default     = ""
}
