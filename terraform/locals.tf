locals {
  # Parse SSH keys from environment variable if provided as comma-separated string
  # Terraform automatically reads TF_VAR_* environment variables
  ssh_keys = length(var.ssh_public_keys) > 0 ? var.ssh_public_keys : []

  k3s_vm = {
    name      = "k3s-apps"
    vmid      = 112
    ip_cidr   = "192.168.20.11/24"
    cores     = 8
    memory_mb = 12288
    disk_size = 80
    tags      = "k3s,apps"
  }

  db_vm = {
    name      = "db-postgres"
    vmid      = 113
    ip_cidr   = "192.168.20.21/24"
    cores     = 4
    memory_mb = 8192
    disk_size = 20 # OS disk only - data disk (60GB) managed manually in Proxmox
    tags      = "db,postgres"
  }

  infisical_vm = {
    name      = "infisical"
    vmid      = 114
    ip_cidr   = "192.168.20.22/24"
    cores     = 2
    memory_mb = 4096
    disk_size = 20
    # Garage object data lives on this disk (mounted at /var/lib/garage/data).
    # Backed by the 4TB ZFS pool 'tank' (see var.tank_storage).
    garage_data_size = 500
    tags             = "secrets,infisical,garage"
  }

  ai_vm = {
    name      = "ai-gpu"
    vmid      = 115
    ip_cidr   = "192.168.20.30/24"
    cores     = 4
    memory_mb = 16384 # 16GB for Whisper + Ollama model loading
    disk_size = 60    # Space for models (Whisper + Qwen)
    tags      = "ml,whisper,ollama,gpu"
    # GPU mapping name (created in Proxmox: Datacenter → Resource Mappings → PCI)
    gpu_mapping = "gpu-quadro-m4000"
  }

  media_vm = {
    name      = "media-server"
    vmid      = 116
    ip_cidr   = "192.168.20.40/24"
    cores     = 6
    memory_mb = 8192
    disk_size = 300
    tags      = "media,jellyfin,qbittorrent,radarr,sonarr"
  }
}
