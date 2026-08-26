locals {
  # Parse SSH keys from environment variable if provided as comma-separated string
  # Terraform automatically reads TF_VAR_* environment variables
  ssh_keys = length(var.ssh_public_keys) > 0 ? var.ssh_public_keys : []

  k3s_vm = {
    name      = "k3s-apps"
    vmid      = 112
    ip_cidr   = "192.168.20.11/24"
    cores     = 8
    memory_mb = 32768
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

  # PostgreSQL 18 — target of the blue/green upgrade.
  # Runs alongside db_vm (113) for the duration of the migration. This address is
  # permanent and the two VMs keep their own: the cutover moves one app at a time
  # by repointing its DATABASE_URL, so both clusters must stay addressable
  # throughout. (A single DNS flip was considered and dropped — it is atomic and
  # global, which rules out migrating one database at a time and makes rollback
  # wait on TTL expiry.)
  db_vm_18 = {
    name      = "db-postgres-18"
    vmid      = 118
    ip_cidr   = "192.168.20.23/24"
    cores     = 4
    memory_mb = 8192
    disk_size = 20 # OS disk only - data disk (60GB) managed manually in Proxmox
    tags      = "db,postgres,pg18"
  }

  services_vm = {
    name      = "services"
    vmid      = 114
    ip_cidr   = "192.168.20.22/24"
    cores     = 2
    memory_mb = 4096
    # OS disk lives on local-lvm (SSD). 20G was tight: ~5-6 GB is locked
    # behind running Docker images (Garage, garage-ui, Infisical, gha-cache,
    # Redis, nginx) and each version bump leaves the prior image
    # around until the daily prune fires. 40G gives ~10x normal image-bump
    # headroom; the daily docker-prune timer in bootstrap/services/install.sh
    # keeps growth bounded after that.
    disk_size = 40
    # Garage object data lives on this disk (mounted at /var/lib/garage/data).
    # Backed by the 4TB ZFS pool 'tank' (see var.tank_storage).
    garage_data_size = 500
    tags             = "infisical,garage"
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

  gh_runners_vm = {
    name    = "gh-runners"
    vmid    = 117
    ip_cidr = "192.168.20.50/24"
    # 16 of the host's 36 cores. CI is bursty and the other VMs sit near idle
    # (host load ~4 of 36), so oversubscribing the box across all VMs is fine —
    # what isn't fine is 8 cores against a dozen runner slots, where a single
    # `mix test` saturates the VM and every other job crawls.
    cores     = 16
    memory_mb = 16384
    disk_size = 60 # Docker layer cache + Elixir build artifacts + per-instance runner copies
    tags      = "ci,github-actions,runners"
  }

  # Forgejo — warm failover for GitHub Actions: git forge, Actions control
  # plane and OCI registry. The self-hosted runners on 117 never protected
  # against an Actions outage, because the scheduling lives on GitHub's side.
  # Design and runbook: bootstrap/forgejo/README.md
  forgejo_vm = {
    name      = "forgejo"
    vmid      = 119
    ip_cidr   = "192.168.20.24/24"
    cores     = 2
    memory_mb = 4096
    disk_size = 20 # OS disk only — lives on local-lvm (SSD)
    # Repos, SQLite and registry blobs, on tank. Immutable per-commit image
    # tags grow without bound, so [cron.cleanup_packages] retention is not
    # optional — see bootstrap/forgejo/install.sh.
    data_size = 200
    tags      = "ci,forgejo,registry"
  }
}
